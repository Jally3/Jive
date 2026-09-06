# Jive 项目技术亮点与面试问答

> 用途：面试前复习、项目介绍、技术原理展开和追问应答。本文以当前仓库代码为准；规划中或归档文档里尚未落地的能力会明确标注，不把设想包装成实现。

## 1. 项目一句话定位

Jive 是一个 Flutter 跨平台视频点播客户端。它不依赖自建业务后端，通过统一 Adapter 接入多种 VOD 协议，并在客户端完成多源搜索、播放地址解析、HLS 本地代理、边播边缓存、广告分片过滤、离线下载和观看进度持久化。

项目真正有技术含量的部分不是页面数量，而是如何把“不稳定、异构、可能失效的上游视频源”转换成“对播放器稳定、可缓存、可恢复的一致播放接口”。

## 2. 面试开场模板

### 2.1 30 秒版本

> 我做的是一个 Flutter 视频点播客户端，采用 Feature-first、轻量 Clean Architecture 和 Riverpod。项目支持 Mac CMS、AGE JSON 和 Syncnext JavaScript 插件等多种数据源，通过 Adapter 和 Repository 统一成相同领域模型。播放侧我实现了一个只监听 loopback 的本地 HTTP 代理：解析并改写 HLS 清单，把播放器请求收敛到代理层，再统一做缓存命中、回源、Range、预取、广告过滤和离线播放。项目里重点处理了异步竞态、缓存一致性、磁盘配额、崩溃恢复和失败降级。

### 2.2 2 分钟版本

> 这个项目最初是一个 Flutter VOD MVP，后来我把它演进成了多源、可缓存的播放架构。整体用 Feature-first 组织页面，用 domain 保存纯业务模型，data 层隔离网络和本地存储，Riverpod 同时承担状态管理和依赖注入。
>
> 第一块亮点是多源架构。不同站点协议和字段差异很大，我定义了 `VodSourceAdapter`，由 `VodSourceRegistry` 按 `adapterType` 选择实现，`VideoRepository` 只暴露列表、分类、详情和播放解析等统一接口。视频身份不是单一 `vod_id`，而是 `sourceId:sourceVideoId`，缓存、收藏、历史都使用这个全局身份，避免不同源的 ID 冲突。
>
> 第二块是搜索和切源的并发控制。搜索先请求当前源，再以最多两个并发探测三个备用源；连续失败源会进入冷却。每个搜索会话有 generation，每个源还有 request sequence，旧请求即使晚返回也不能覆盖新状态。详情页切源则先搜索候选、打分匹配，再验证真实播放地址，成功后原子替换，失败保留旧详情。
>
> 第三块是播放和缓存。我在 App 内启动 `127.0.0.1` 随机端口代理，把 HLS 清单中的分片地址改写成本地 URL。播放器始终只访问代理；代理按“缓存命中则读磁盘，否则 HTTPS 回源并写穿缓存”的方式工作。因此在线播放、边播边下和离线播放复用同一条链路。缓存用内容身份加 manifest revision 做版本隔离，用 SingleFlight 合并同分片的前台请求，用 lease 预留磁盘配额，用引用计数保护正在播放的条目，还在启动时 reconcile 索引与真实文件。
>
> 广告过滤发生在 HLS 清单层，通过显式路径、短分片簇、断点组时长、域名聚类、夹心小块等保守规则识别分片。过滤后会生成源时间轴到播放时间轴的双向映射，历史记录仍存源时间轴，因此开关过滤或版本变化时也能正确续播。不能安全处理的直播、复杂加密或未知标签会直接降级为直连，优先保证能播。

## 3. 架构总览

```text
Widget / Feature
       ↓ 交互与渲染
Riverpod Provider / Controller
       ↓ 状态与流程编排
Repository
       ↓ 统一业务接口
VodSourceRegistry → VodSourceAdapter
       ↓
HTTP / JavaScript 插件 / SharedPreferences / 本地文件

播放支线：
PlaybackSelection → URL Resolver → HLS Parser / AdFilter
                  → LocalProxyServer → ResourceFetcher
                  → CacheManager / SegmentPrefetcher / DownloadTaskManager
                  → video_player
```

### 为什么选择 Feature-first + 轻量 Clean Architecture

- `features/` 按首页、搜索、详情、播放器、缓存、下载拆分，改一个功能时相关页面和控制器更集中。
- `domain/` 只保存稳定业务模型，不依赖 Widget、HTTP 和存储实现。
- `data/` 屏蔽来源协议、网络、缓存、下载和持久化细节。
- Repository 是业务门面，Provider/Controller 负责编排，页面不直接发 HTTP 请求。
- MVP 没有机械地给每个 feature 再套四层目录，控制了抽象成本；当模块复杂度上升时，再局部拆 application/data/presentation。

这不是为了“套 Clean Architecture”，而是为了稳定依赖方向：UI 可以变化，第三方源也可以变化，但领域身份和业务接口尽量稳定。

## 4. 技术亮点一：可扩展的多 VOD 源适配

### 4.1 问题

不同内容源可能使用 Mac CMS JSON、定制 JSON 或 JavaScript 插件，字段、分页、分类和播放地址格式均不相同。如果页面直接判断来源类型，最终会充满 `if (source == ...)`，难以测试和扩展。

### 4.2 当前实现

- `VodSource` 保存配置：`id`、`baseUri`、`adapterType`、优先级和能力开关等。
- `VodSourceAdapter` 定义统一协议：分页、分类、详情、播放解析。
- `VodSourceRegistry` 维护配置与 Adapter 的映射；未知 `adapterType` 会被隔离，不拖垮整个源列表。
- `VideoRepositoryImpl` 根据 source 找 Adapter，并集中处理详情短缓存和内容过滤。
- Feed 属于可选能力：Adapter 实现 `VideoFeedSourceAdapter` 才暴露热门、新片、高分等排序，避免把所有实现强迫成同一能力集合。

这里同时使用了三个常见设计思想：

1. **Strategy**：每个 Adapter 是一种来源访问策略。
2. **Registry/Factory**：根据 `adapterType` 查找并创建策略。
3. **Repository**：对上层隐藏协议与数据转换细节。

### 4.3 JavaScript 插件运行时为什么值得讲

Syncnext 源不是硬编码一个新 Dart Adapter，而是下载 HTTPS 配置和脚本，在 `flutter_js` 运行时中执行，并通过受控的 `$http`/消息桥访问网络：

- 插件资源只接受 HTTPS；
- JS 调用串行化，避免一个 runtime 中多个 pending result 相互覆盖；
- HTTP 请求通过宿主 Dart 层执行，统一 cookie、超时与错误；
- 原 GitHub raw 地址失败时有受限 CDN 候选；
- 配置、脚本加载、执行均有明确错误转换。

本质上这是一个小型 Plugin Host。好处是新增同类站点主要变成配置/脚本扩展，而不是频繁发版；代价是要严肃考虑脚本信任、资源完整性、能力白名单和超时隔离。当前实现具备协议桥和基础安全约束，但若正式开放第三方插件，还应增加签名校验、来源白名单、脚本版本锁定和更严格的权限模型。

### 4.4 身份模型：为什么不能只用 `vod_id`

两个站点都可能存在 `vod_id = 123`，它们却不是同一个资源。因此项目使用：

```text
Video.globalId = sourceId + ":" + sourceVideoId

ContentKey = SHA-256(
  sourceId,
  sourceVideoId,
  playbackLineIdentity,
  episodeIdentity
)
```

`ContentKeyParts` 使用“UTF-8 字节长度前缀 + 内容”编码，而不是简单拼接字段，避免 `ab + c` 与 `a + bc` 之类的边界歧义。SHA-256 用于得到稳定、文件系统友好的 key，而不是用于密码学认证。

### 4.5 面试追问

**问：为什么不用继承页面或在 Repository 中 switch？**  
答：来源差异属于数据访问策略，不属于 UI。Adapter 让差异在边界层收敛，Repository 保持统一；新增源时只注册一个实现，页面和领域模型不变，也可以给每个 Adapter 独立写契约测试。

**问：接口统一后会不会丢失来源特有能力？**  
答：共同能力进入最小接口，非共同能力用 capability interface 表达，例如 `VideoFeedSourceAdapter`。这样既避免把接口做成大而全，也避免用运行时字符串判断能力。

**问：插件方案最大的风险是什么？**  
答：远程代码的供应链与权限风险。当前宿主接管网络并限制 HTTPS，但生产化还需要签名、hash 校验、可信源、版本回滚、请求域名白名单和执行资源限制。

## 5. 技术亮点二：多源搜索的并发治理

### 5.1 搜索策略

搜索不是简单的 `FutureBuilder`：

- 输入防抖 600 ms，空关键词不请求；
- 当前源立即查，备用源延迟 300 ms 探测；当前源失败或为空时提前启动备用探测；
- 默认最多探测 3 个备用源，最多 2 个并发，避免瞬时请求风暴；
- 连续失败至少 2 次的源冷却 10 分钟，只退出自动探测，用户仍可手动请求；
- 相同“source + keyword + page”结果在内存缓存 7 分钟；
- 每个来源独立保存列表、页码、总数、loading 和 error；
- 分页按 `globalId` 去重。

### 5.2 generation + sequence 如何解决竞态

典型竞态：用户先搜 A，又迅速搜 B；A 的网络请求更慢，最后返回。如果直接写状态，页面会显示 A 的结果。

项目用了两层逻辑时钟：

```text
searchGeneration：区分整次搜索会话，A 与 B 不属于同一代
sourceRequestSeq：区分同一来源内的刷新、重试、分页请求
```

响应写回前必须同时满足：

```text
response.generation == currentGeneration
response.sequence == currentSourceSequence
controller has not been disposed
```

它并没有真正取消底层 HTTP，而是让过期结果失去提交状态的资格。这种“逻辑取消”实现成本低，适用于无法可靠取消的 Future；缺点是旧请求仍消耗少量网络资源，因此再配合 debounce、并发上限和 timeout 控制成本。

### 5.3 结果数量为什么有“数字 / N+ / 有结果”三种形式

有些源返回精确 `total`，有些只能通过 `hasMore` 推断还有下一页。项目不会把“第一页条数”伪装成“总数”：

- 有 `total`：显示精确数字；
- 无 `total` 但有下一页：显示 `N+`；
- 无 total 且无法推断：显示“有结果”。

这是数据语义准确性问题，不只是 UI 文案问题。

### 5.4 面试追问

**问：generation 和锁有什么区别？**  
答：锁控制“能否同时执行”，generation 控制“谁有资格提交结果”。搜索请求可以并行，不需要全局互斥；我们只要保证旧会话不能污染新会话，所以逻辑版本号更合适。

**问：为什么不自动搜索所有源？**  
答：延迟、带宽、源站压力和失败噪声都会线性增长。默认 1+3、并发 2 是体验与成本的折中，同时保留“搜索全部来源”的显式入口。

**问：如何进一步优化？**  
答：可将健康度持久化并引入 EWMA 延迟、成功率、结果质量评分；也可做请求取消、stale-while-revalidate 和全局并发调度器。但 MVP 的内存健康度更简单，也避免一次网络故障永久影响后续排序。

## 6. 技术亮点三：详情跨源匹配与原子切换

详情页不会一打开就请求所有源，而是用户主动检测后才并发探测，降低无意义流量。候选匹配先做标题归一化，再综合年份、演员、导演、地区、分类和集数差异评分。

切源不是“搜到同名就换”：系统还会调用 `resolvePlayback` 验证候选是否真的存在可用 HTTPS 播放地址。只有新详情完整加载并验证成功后，才一次性替换 `activeVideo`；失败时保留原详情。这是 UI 中的事务语义：

```text
prepare candidate → validate playback → commit activeVideo
                    ↘ failed → rollback by doing nothing
```

这里称“原子”不是数据库 ACID，而是用户可见状态不会进入半切换状态。

**问：同名影视如何避免误匹配？**  
答：标题只是召回条件，排序还使用年份、主创、地区、分类和集数。最终让用户确认候选，并在提交前验证播放链路。若要继续增强，可引入标准化作品 ID 或服务端实体对齐。

## 7. 技术亮点四：播放地址解析与分级降级

播放地址可能是 HLS、MP4、DASH，也可能先返回 HTML 解析页。`PlaybackUrlResolver` 会：

- 已知格式直接返回；
- 未知格式请求解析页，通过最终 URL、Content-Type、文件头和 HTML 内容识别真实媒体；
- 限制 HTML 最大读取规模，过滤不应透传的 session headers；
- 结果缓存 10 分钟，重试时可清除指定 URL 缓存；
- 只接受受支持且安全的地址。

解析完成后，HLS 再进入 `HlsParser`。以下场景不会强行缓存，而是降级直连：

- manifest 请求失败；
- master playlist 超过最大跳转层级；
- 直播流；
- 不支持的 HLS 标签；
- 不支持的加密方式。

降级原则是：增强能力失败不能阻断核心播放。代理、缓存和过滤是优化层，不是播放器的单点故障。

## 8. 技术亮点五：HLS 本地代理统一播放、缓存与离线

### 8.1 为什么要本地代理

播放器直接请求远端 HLS 时，业务层很难可靠介入每个 segment。项目启动一个绑定到 `127.0.0.1` 随机端口的 HTTP server，将清单改写为：

```text
远端：https://cdn.example.com/001.ts
本地：http://127.0.0.1:<port>/play/<token>/res/<resourceId>
```

播放器只看到标准 HLS URL；代理层决定资源来自磁盘还是网络，并补充上游所需的 Referer/Cookie 等会话头。这是 Proxy、Cache-Aside/Read-through 与 Facade 思想的组合。

### 8.2 一次播放的主链路

```text
1. PlaybackSelection 固化源、影片、线路和剧集身份
2. 优先查找匹配 ContentKey + manifestBaseUrl 的完整离线 revision
3. 未命中则解析远端 HLS，选择 media playlist
4. 可选广告过滤，生成过滤后 manifest 与 TimelineMapping
5. 以 manifest 内容 hash 生成 revisionKey
6. 将 segment/map/key URL 改写成本地代理 URL
7. 播放器请求本地资源
8. 命中完整缓存 → 读文件；未命中 → HTTPS 回源并流式写穿
9. 播放位置驱动后台预取窗口
10. 关闭 session 时停止预取、等待活跃读、注销路由、释放缓存引用
```

### 8.3 session token 和 loopback 的作用

- 只监听 IPv4 loopback，不暴露到局域网；
- 每个播放 session 使用随机 token，路由相互隔离；
- URL 不直接暴露原站地址，而是资源 ID；
- 关闭时先标记 `closing`，最多等待活跃读取 2 秒，再注销路由。

token 主要用于路由隔离和降低误访问，不应被描述成完整的安全认证机制。

### 8.4 Range 请求为什么先写穿完整资源

播放器对 fMP4/BYTERANGE 资源可能发 Range。首次未命中时，项目先拉取完整资源并缓存，再从本地切出所需范围返回 206。它牺牲首次少量带宽，换取后续 Range 稳定命中，避免缓存被切成大量难管理的小块。缓存命中时会正确返回 `Content-Range`、`Content-Length` 和 `Accept-Ranges`；非法范围返回 416。

## 9. 技术亮点六：边播边缓存与时间窗口预取

播放器的刚需请求优先于后台预取：

- 同一分片有多个前台请求时，`SingleFlight` 合并成一个任务；
- 预取发现前台正在拉同一分片时主动让行；
- 前台发现预取正在拉时会独立回源并使用独立临时文件，而不是等待预取。

最后一点看似会造成短时重复下载，但它解决了 Dart 单订阅 Stream 不能被两个消费者安全共享的问题，也避免后台任务拖慢起播。这里选择的是“播放延迟优先于极致节省流量”。

`SegmentPrefetcher` 不按固定分片数预取，而按播放时间开窗：

- Wi-Fi/有线网络领先 300 秒；
- 蜂窝网络领先 120 秒；
- 关闭预取、无网络或网络类型未知时为 0；
- 默认并发 5；
- 失败最多尝试 3 次，指数退避并加入 jitter；
- seek 后按新位置重锚定；进入后台暂停，恢复前台后继续。

按时长而非片数开窗，是因为不同源的分片可能从 0.5 秒到 10 秒不等；固定片数无法表达稳定的“可连续播放时长”。

## 10. 技术亮点七：缓存一致性、磁盘配额与崩溃恢复

### 10.1 两级身份与 revision

```text
ContentKey：哪部影片、哪条线路、哪一集
RevisionKey：本次 media playlist 的 base URI + manifest fingerprint
EntryKey：ContentKeyHash | RevisionKeyHash
```

同一剧集的上游清单可能更新。只按剧集 key 缓存会把旧 segment 和新 manifest 混用，因此增加 revision 维度隔离不同版本。

### 10.2 写入为什么需要 lease

并发下载时，仅在写完后统计空间会造成所有任务都认为“还有容量”。`reserve()` 会把预计写入字节计入 `_pending`，生成 `WriteLease`；实际长度变化时再 `ensureCapacity()`，提交或取消时释放预留。配额计算是：

```text
effectiveUsed = diskCommitted + pendingReserved
```

这样避免并发超卖磁盘空间。

### 10.3 写入完整性

资源写到 `.part`，完成后才提交为 complete。提交前至少检查：

- 有 Content-Length 时，实际字节数必须一致；
- key 文件必须是 16 字节；
- 未加密 TS/fMP4 等检查格式魔数，拦截“HTTP 200 但内容是 HTML 错误页”；
- 缓存条目必须仍可写，避免删除后在途任务重建孤儿目录。

对播放场景，缓存失败通常旁路为网络流，不影响观看；对显式下载，缓存失败必须让任务失败，因为“显示下载完成但不能离线播放”比失败更危险。

### 10.4 LRU、TTL 和保护规则

磁盘不足时先清理过期项，再做空间淘汰。候选顺序是“非完整项优先，再按 lastAccess 从旧到新”，但以下条目不能自动淘汰：

- 正在被 session 引用的条目；
- 标记为 `downloadOrigin` 的显式离线下载；
- 正在 deleting 的条目；
- 当前正准备写入的目标条目。

TTL 支持不清理、退出即清理、1 小时、5 小时、1/3/7 天；显式下载始终豁免。`onExit` 还有 1 天兜底 TTL，用于进程被系统杀掉、没有执行正常退出清理的场景。

### 10.5 启动 reconcile

App 崩溃可能发生在“文件已写、索引未写”或“索引已写、文件丢失”的窗口。初始化时 `CacheManager` 会：

- 从 index 和各 entry 的 `state.json` 重建状态；
- 删除临时文件；
- 正向核对记录对应的真实文件、大小和完整状态；
- 反向清扫无状态孤儿目录和 `.part`；
- 对已完整落盘但记录缺失的文件补建记录；
- 遇到未来 schema 版本时隔离保留，而不是贸然删除；
- 对 deleting 状态重试删除。

这体现了“磁盘是事实来源，索引是可重建加速结构”的思想。

### 10.6 面试追问

**问：为什么同时有全局 index 和每条 state.json？**  
答：全局 index 适合快速列表和统计，entry state 让单条资源目录具备自描述和恢复能力。崩溃后两者可以与实际文件三方 reconcile，降低单文件损坏导致全库不可用的风险。

**问：这是不是数据库事务？**  
答：不是完整 ACID，但用 `.part → 校验 → commit`、状态机、deleting tombstone、串行 mutex 和启动 reconcile 构建了面向文件系统的最终一致性协议。

## 11. 技术亮点八：HLS 广告过滤与双时间轴

### 11.1 当前真正实现的规则

当前 `adfilter-v3` 在 manifest/segment 元数据层组合 7 类规则：

| 规则 | 主要证据 | 保守约束示例 |
| --- | --- | --- |
| explicit | 路径中存在 `/ad/`、`/ads/`、`/adjump/` 等明确标记 | 只匹配明确模式 |
| shortCluster | 连续短分片形成簇 | 至少 5 段，均值低于基准一半 |
| discontinuityDuration | discontinuity 分组的平均时长明显异常 | 需要多段、总长受限 |
| hostCluster | 少数分片来自非主导域名 | 主导域占比需超过 70%，异常块较短 |
| dwarf | 被两个大内容组夹住的极小断点组 | 只看中间组，限制段数和总长 |
| midRollSandwich | 12–90 秒组夹在两个至少 120 秒内容组之间 | 不处理首尾组 |
| cadenceDwarf | 大多数断点组大小形成固定节奏，其中连续小组异常 | 主导组尺寸占比至少 70%，保留过短尾部 stub |

算法先收集候选块，再合并相邻/重叠块，并输出命中规则、删除段数、删除时长和最低 confidence。整体策略是宁可漏过，也不要误删正片。

注意：归档科普文档曾讨论帧率网格、文件序号和运行时 PTS 检测，但当前 `lib/` 并未实现这些能力。面试时可以把它们作为演进思路，不能说成已完成。

### 11.2 为什么过滤后进度会错

假设源清单前 10 分钟中有 30 秒广告。播放器看到的过滤时间 5:00，实际对应源时间 5:30。如果直接保存播放器时间，关闭过滤或 manifest 更新后会续播到错误位置。

项目保存被删除的源时间范围，构建 `TimelineMapping`：

```text
sourceToFiltered(t) = t - t 之前已删除的累计时长
filteredToSource(t) = t + t 之前已删除的累计时长
```

历史统一保存 source timeline，同时记录 `filterVersion`、`timelineVersion` 和 `manifestFingerprint`。播放时再映射到当前清单时间轴。这样缓存播放、直连播放和过滤版本变化之间有统一语义。

### 11.3 HLS 清单重写的关键不变量

- 删除广告 segment 的同时删除其 `EXTINF`/`BYTERANGE`；
- 保留或补回必要的 `EXT-X-DISCONTINUITY`，避免拼接后 PTS 不连续；
- 过滤后移除不再可靠的 PROGRAM-DATE-TIME；
- segment、map 和 key 都改成本地资源 URL；
- 隐式 IV 的 AES-128 不做过滤，因为删除分片会改变 media sequence 语义；
- 复杂加密、直播或未知标签直接回退。

**问：启发式过滤如何避免误伤？**  
答：使用多类结构证据、较高触发阈值和整层放弃机制；对首尾、混合 CDN、直播、复杂加密等高风险情况保守处理。同时保留规则报告和版本号，便于定位与迁移。正式商业场景还应支持按源灰度、远程开关和误报反馈。

## 12. 技术亮点九：下载任务状态机与在线/离线复用

下载状态包括 queued、downloading、paused、completed、failed、cancelled。核心设计点：

- 下载前重新解析播放地址，避免持久化 URL 过期；
- 只支持可安全落盘的 HLS VOD，直播和不支持的加密流拒绝下载；
- 下载和在线播放共用 HLS 解析、广告过滤、ContentKey、CacheManager 与 ResourceFetcher；
- 多 worker 并发下载，同时通过全局 permit pool 限制资源并发；
- 暂停会等待当前分片完整落盘后停下，不留下伪完整资源；
- 进程重启后 downloading 恢复为 queued，并用缓存事实校准任务状态；
- 全部分片提交且 manifest/timeline 齐全后，必须显式 `finalizeEntry` 才能标记 offline playable；
- 完成状态若与磁盘不一致，会降级为 paused/failed，而不是继续显示完成。

这避免了在线缓存和离线下载各维护一套文件格式。两者共享数据平面，但策略不同：在线缓存允许配额失败后旁路；显式下载要求完整性，并被 TTL/LRU 保护。

## 13. 技术亮点十：播放器生命周期和交互一致性

播放器页面同时面对初始化、重试、换集、前后台切换、横竖屏、拖动进度、亮度/音量手势和页面销毁。项目使用多个局部 generation 与严格的资源交接顺序：

- `setupGeneration` 让旧 controller/session 的异步初始化结果失效；
- 新 controller 完成初始化、seek、倍速和播放状态恢复后才安装到 UI；
- 被替换的 controller 与 session 分离后再异步释放，避免 UI 引用已销毁对象；
- seek 使用 pause → seek → 读取落点 → 必要时重试 → 恢复播放的管线，并用 `seekGeneration` 防止手势竞态；
- seek 成功后立即重锚预取窗口，并保存源时间轴历史；
- App 进入后台暂停预取、保存进度、处理 wakelock；回前台按期望播放状态恢复；
- session 关闭等待活跃代理读取并释放 CacheRef，防止播放中条目被淘汰。

一个重要经验是：Flutter 的 `mounted` 只能说明 State 是否还存在，不能说明这次异步任务仍是“最新意图”。因此要同时校验 mounted、generation 和 controller identity。

## 14. 技术亮点十一：本地持久化的并发与容错

收藏和历史目前使用 SharedPreferences，适合小规模 MVP 数据，但项目没有忽略读改写竞态：

- 所有写操作挂到 `_writeQueue` 串行执行；
- 读取历史前等待已排队写完成，避免播放器退出后页面立即读到旧快照；
- 单条损坏或未知 schema 的历史记录跳过，不拖垮整份数据；
- 列表设置上限，历史最多保留 50 条；
- 收藏采用 optimistic update，持久化失败时回滚 UI；
- 模型携带 schema version，并对旧数据提供明确迁移默认值。

**问：为什么不用 SQLite？**  
答：当前只是几十条收藏、历史和简单设置，SharedPreferences 足够且开发成本低。缓存索引已经使用文件系统状态文件。若后续需要复杂查询、多用户、大量历史或事务更新，应迁移到 SQLite/Drift，并保持 Repository 接口不变。

## 15. 测试策略怎么介绍

测试目录镜像 `lib/`，当前代码中约有 450 个 `test`/`testWidgets` 用例声明，覆盖 domain、Adapter、搜索/详情控制器、HLS 解析与过滤、本地代理、缓存索引/IO/Manager、下载状态机和关键 Widget。

面试时重点讲“测试什么不变量”，比只报数量更有价值：

- 同源/跨源 ID 不冲突，序列化迁移不破坏旧数据；
- 旧搜索响应不能覆盖新关键词，快速双击不重复请求；
- HLS master/media、相对 URL、Range、加密和不支持标签的分支；
- 广告规则能删目标块，也要有反例证明不误删正常片段；
- 同分片并发、缓存旁路、字节截断、错误 HTML、key 长度等完整性；
- TTL/LRU 不删除活跃引用和显式下载；
- 崩溃残留经过 reconcile 后回到一致状态；
- 下载暂停、恢复、重启、配额失败和最终离线可播条件。

适合使用 fake HTTP client、临时目录、可注入 clock/timeout/disk provider，而不是依赖真实站点，保证测试可重复。

## 16. 高频综合问题与参考回答

### Q1：你认为项目最难的部分是什么？

> 最难的不是播放一个 URL，而是维持跨模块的一致身份和时间语义。一个视频会跨来源、线路、剧集、manifest revision、过滤前后时间轴、缓存和历史存在。如果 key 设计不完整，就会串缓存；如果时间轴不统一，续播会漂移；如果异步会话没有版本号，换集或重试时旧结果会覆盖新结果。我最终用全局资源身份、ContentKey + RevisionKey、source timeline 和 generation 分别解决这几类问题。

### Q2：为什么本地代理比直接下载后切 URL 更好？

> 代理让播放器始终消费同一种标准 HLS 接口，缓存命中、回源、请求头、Range 和离线都在代理后完成。直接切 URL 会迫使播放器感知在线/离线两套地址，并在切换时处理重新初始化、seek 和缓冲，状态机更复杂。代理的代价是要维护一个本地 HTTP server、路由生命周期和流式 IO。

### Q3：如何保证缓存不会拖垮播放？

> 在线场景把播放当主链路、缓存当 best effort：配额不足、落盘失败或条目被删都可以旁路回源；预取必须给前台让行；不支持的 HLS 直接降级；关闭 session 时等待活跃读。只有显式下载才采用 fail closed，因为下载的承诺就是完整离线可用。

### Q4：如何处理并发重复请求？

> 控制面用 mutex 串行修改缓存元数据；同一前台分片用 SingleFlight 合并；磁盘容量用 lease 预留；播放和预取冲突时播放优先，必要时使用独立临时文件；UI 请求用 generation/sequence 做逻辑取消。不同并发问题使用不同工具，而不是用一把全局锁解决所有问题。

### Q5：为什么不直接用现成缓存库？

> 图片使用了成熟缓存库，但视频缓存涉及 HLS manifest 改写、segment/map/key、Range、加密、广告过滤时间轴、显式下载保护和离线可播判定，通用 HTTP cache 很难表达这些领域语义。底层播放器仍用成熟 `video_player`，自研的是业务特定的数据平面。

### Q6：Riverpod 在项目里具体解决了什么？

> 一是依赖注入，例如 Repository、Registry、CacheManager、DownloadManager 都可以由 Provider 组装和释放；二是异步状态建模；三是跨页面共享源选择、主题、缓存策略和历史。页面内高频且短生命周期的手势状态仍使用 State/ValueNotifier，没有把所有布尔值全局化。

### Q7：如果源站挂了怎么办？

> 列表和搜索有独立错误状态与重试，搜索会探测健康备用源；详情允许用户切源；播放 URL 会在失败后强制刷新；代理准备失败会直连；仓库还保留官方 demo 视频兜底。不同层级都有降级点，避免一个增强模块形成全局单点故障。

### Q8：如何验证离线下载真的可播？

> 不能只看下载 Future 是否结束。必须满足 expected resource 数量已全部 commit、source/proxy manifest 存在、过滤时 timeline 文件存在、每个资源通过长度/格式校验，最后 `finalizeEntry` 成功并重新读取到 `offlinePlayable=true`。重启后还会用磁盘状态反向校准 task 状态。

### Q9：有哪些技术债？

> 第一，远程 JS 插件需要更强的供应链安全；第二，SharedPreferences 适合 MVP，数据量扩大后要迁数据库；第三，多源实体匹配仍是启发式，最好引入统一作品 ID；第四，广告过滤是保守启发式，需按源灰度和遥测；第五，目前主要是 Android/iOS/部分 TV 适配，仍需要更系统的弱网、真机和长时间播放测试。

### Q10：如果用户量扩大，下一步怎么演进？

> 客户端 Adapter 可以保留，但源配置、健康度、标准化作品 ID 和搜索聚合应逐步上移到后端；客户端继续负责播放解析、代理和离线。缓存索引可迁 SQLite，下载进入平台后台任务；观测侧增加首帧时间、卡顿率、解析成功率、源成功率、缓存命中率和过滤误报率，并用远程配置做策略灰度。

## 17. 可用 STAR 讲述的三个案例

### 案例 A：解决搜索结果串台

- **S**：快速输入或切源时，多请求并行，慢请求可能最后返回。
- **T**：保证 UI 只展示用户最新意图，同时保留多源并发。
- **A**：搜索会话增加 generation，每源增加 sequence；提交前校验两者；再加 debounce、timeout、并发上限和 loading 重入守卫。
- **R**：旧请求不能覆盖新状态，同一来源快速双击不会重复发请求，多源探测仍能并行。

### 案例 B：解决边播边下与起播竞争

- **S**：播放器和预取器可能同时请求同一 segment；直接共享单订阅 Stream 会失败，互相等待又影响首帧。
- **T**：优先保证播放，同时尽量减少重复回源。
- **A**：前台之间 SingleFlight；预取遇前台主动让行；前台遇预取时独立回源并写独立 part；完成后由缓存状态收敛。
- **R**：避免起播被后台任务阻塞，也避免临时文件交错写坏；代价是极端竞态下允许一次重复下载。

### 案例 C：解决崩溃后的“假下载完成”

- **S**：App 可能在写文件、更新 state、更新全局 index 的任意一步被杀。
- **T**：重启后不能出现索引显示完成但文件缺失，也不能无脑删除已经完整写入的数据。
- **A**：采用 part/complete 状态、每 entry state、全局 index、deleting tombstone 和启动 reconcile；以真实文件为准校准计数，并补记或清理孤儿。
- **R**：下载任务能在重启后恢复到可信状态，离线可播标志由完整条件推导，不依赖单个布尔值。

## 18. 面试时不要说过头

- 不要说“实现了 DRM”：当前仅处理部分 AES-128 HLS，复杂加密直接回退或拒绝下载。
- 不要说“广告过滤 100%”：它是 manifest 级启发式，硬编码进正片的广告无法去除，也存在需要持续控制的误报风险。
- 不要说“实现了 HTTP 缓存协议全部语义”：项目支持播放需要的请求头过滤、响应头白名单、单 Range 和本地 206，不是通用代理服务器。
- 不要说“真正取消了旧 HTTP”：搜索主要采用 generation/sequence 让旧结果失效，属于逻辑取消。
- 不要说“插件完全沙箱化”：目前是受控桥接和基础校验，生产开放生态仍需更强的签名与权限隔离。
- 不要把归档方案中的 PTS、帧率、文件序号检测说成现有实现。
- 不要说“完全 Clean Architecture”：当前是适合 MVP 的轻量分层，部分 Repository 接口仍位于 data 层，这是务实取舍，也是可演进点。

## 19. 代码导览：被追问时从哪里展开

| 主题 | 关键文件 |
| --- | --- |
| 总体架构 | `ARCHITECTURE.md` |
| 多源门面与分发 | `lib/data/video_repository.dart` |
| Adapter/Registry | `lib/data/vod_source/vod_source_adapter.dart`、`vod_source_registry.dart` |
| JS 插件宿主 | `lib/data/vod_source/adapters/syncnext_plugin_runtime.dart` |
| 多源搜索竞态 | `lib/features/search/multi_source_search_controller.dart` |
| 详情候选与原子切换 | `lib/features/detail/detail_source_controller.dart` |
| 播放 session | `lib/data/playback/playback_session.dart` |
| 本地代理 | `lib/data/playback/local_proxy.dart` |
| HLS 解析与清单改写 | `lib/data/playback/hls_parser.dart` |
| 广告规则与时间轴 | `lib/data/playback/ad_filter.dart` |
| 缓存读写和 SingleFlight | `lib/data/cache/cache_io.dart`、`single_flight.dart` |
| 缓存配额/一致性 | `lib/data/cache/cache_manager.dart`、`cache_index.dart` |
| 预取 | `lib/data/download/download_manager.dart`、`lib/data/playback/prefetch_policy.dart` |
| 离线下载状态机 | `lib/data/download/download_task_manager.dart` |
| 历史与收藏 | `lib/data/history_repository.dart`、`library_repository.dart` |
| 播放器生命周期 | `lib/features/player/player_page.dart` |

## 20. 最后复习清单

面试前确保自己能不看文档解释清楚以下问题：

1. Adapter、Registry、Repository 各自解决什么问题？
2. `globalId`、ContentKey、RevisionKey 为什么是三种不同身份？
3. generation/sequence 为什么比一个 `isLoading` 更可靠？
4. 本地代理如何让在线、缓存、过滤和离线复用同一播放链路？
5. 为什么前台遇到预取在途时宁可重复下载也不 join？
6. lease 如何避免并发任务超卖磁盘配额？
7. `.part`、完整性校验、finalize、reconcile 各防哪类故障？
8. 广告过滤后为什么必须做双时间轴映射？
9. 哪些情况必须降级直连，哪些情况下载必须失败？
10. 当前方案的边界、技术债和下一步演进是什么？

