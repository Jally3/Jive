# 点击播放到首帧：链路复核与优化方案

日期：2026-10-01；实现更新：2026-10-02。状态：A 项详情复用已实施，其余方案待实施。

性能基线包含上一轮未提交的 8 秒无进展降级、缓存预检查、Range 流式响应与细分计时改动。A 项已实现单模型详情复用并通过请求次数、容量和重试回归测试；其余建议未实现，尚未新增起播性能或实际堆内存实测。历史数据来自 `logs/playback_startup_optimization/summary.json`：同一 iPhone 17 Pro / iOS 26.3 模拟器、debug、10 次在线 HLS 播放。

## 1. 应当优化的终点

用户目标是点击后尽快看到所选剧集、正确起点的画面，并继续流畅播放。

目前 `PlayerSessionLifecycle._installController` 在 `initialize → seek（如有）→ 设置倍速/音量 → play()` 返回后提交控制器，调用 `setState(initializing=false)`，随即结束追踪。`VideoPlayer` 在随后 rebuild 才挂载。现有 **5.317 秒是点击到播放命令完成，不是点击到可见首帧**。

本地实际依赖中，iOS 初始化完成对应 `AVPlayerItemStatusReadyToPlay`，Android 对应 `STATE_READY`；两者均不等价于渲染首帧。位置递增、`isPlaying`、widget 出现也不能单独证明已经显示画面。

建议保留现有指标，并增加：

- 点击到原生 ready、播放命令、视频 widget 挂载、原生首帧的独立时间点。
- iOS 纹理路径记录首个有效视频像素缓冲与 Flutter 帧，区分“可供显示”和“已合成”；用真机录屏校准可见首帧口径。
- Android 接入 `onRenderedFirstFrame`，按一次播放 generation 去重，避免 seek/换 surface 被计为首次启动。
- 起播后 30 秒卡顿时长、失败率、起播下载字节数；续播首帧必须对应目标位置。
- 切集、重试在用户点击时起表，包含旧资源释放和地址刷新。当前两条路径在 `_setup` 前已经等待，现有统计漏掉这部分。

参考：[Android 首帧事件](https://developer.android.com/reference/androidx/media3/exoplayer/analytics/AnalyticsListener)、[Apple HLS 性能测量与优化](https://devstreaming-cdn.apple.com/videos/wwdc/2018/502plwzfxg5p7w4na/502/502_measuring_and_optimizing_hls_performance.pdf)。

## 2. 优化前基线链路与耗时

```text
用户点击播放 / 选集
  → 查询该集完整下载（命中时可跳过详情刷新）
  → resolvePlayback：再次取得详情和播放列表（优化前；当前 MacCMS 优先复用有效详情缓存）
  → 收藏快照刷新
  → 创建播放器页面
  → 读取片头/片尾策略
  → 解析播放源（已知 HLS 几乎立即返回；unknown/插件有网络请求）
  → 本地完整缓存检查
      命中：本地代理清单与本地分片
      未命中：master GET → 选版本 → media GET
              → 解析/广告过滤 → 代理计划与缓存元数据
  → 原生控制器 initialize
      GET 本地清单 → 请求分片/初始化段/密钥
      → 代理查缓存、回源、流式交付 → 原生探测/解封装/解码准备
  → 续播或跳片头 seek（如有）
  → 倍速/音量 → play() 返回
  → 提交控制器、结束现有统计
  → 后续 Flutter 帧挂载视频；原生继续缓冲/解码/渲染
  → 所选起点首帧可见、播放时间推进
```

不支持代理的格式/清单会直连；代理初始化失败也可能重新建立直连控制器。未知地址解析前另有完整缓存预检查。以上分支不能全部累加为每次播放的耗时。

| 正常在线 HLS 阶段 | 本轮平均 | 判断 |
| --- | ---: | --- |
| 下载选择查询 | 3.107ms | 首个样本约 29ms，其余约 0.2ms；大缓存冷启动未覆盖 |
| 详情/播放列表刷新 | 254.651ms | 可复用进入详情时取得的有效响应 |
| 收藏快照刷新 | 0.135ms | 本轮没有优化优先级 |
| 跳过策略读取 | 42.897ms | 当前串行，可与播放源/HLS 网络准备重叠 |
| 播放源解析 | 0.193ms | 这 10 条都是已知 HLS，不能代表 unknown/插件 |
| HLS 准备 | 1288.340ms | 含下列清单请求、解析、缓存子阶段 |
| └ master / media 网络 | 745.222 / 522.486ms | 首次未知 media 地址时存在必要依赖 |
| └ 清单解析 | 6.600ms | 含广告过滤，非主要瓶颈 |
| 原生 initialize（代理） | 3713.508ms | 包含首段网络与原生准备，不可再加首段耗时 |
| 控制器配置 | 1.762ms | 含倍速、音量；本轮无续播 seek |
| play 命令 | 1.491ms | 不是等待首帧的耗时 |
| 点击到当前统计终点 | 5316.523ms | 10 次均完成当前启动流程；尚未验证真实首帧 |

HLS 准备约占已统计时间 24%，原生初始化约占 70%。首个 TS 全部未命中缓存，平均约 1.166MiB；首字节约 548ms，整个下载约 2.932s。所有第二段请求都出现在第一段下游响应结束后，间隔平均约 2.9ms，说明存在顺序取段关口；日志不足以确定其由原生探测、缓冲策略还是 HTTP 响应形式造成。

《WTO姐妹会》是明确例子：初始化 10.306s，首段下载 7.779s，随后第二段下载 2.479s。这里大部分时间正在传输数据，缩短“无进展超时”不能使正常传输更快。

需要修正此前判断：`downstreamFirstByte` 在 Dart `StreamTransformer` 回调中、`response.addStream` 消费路径上记录，尚未确认 socket 发出/原生接收。上游首字节与它相差约 0.42ms，只说明 Dart 层转交快，不能证明代理对原生启动没有额外影响。

## 3. 优先实施的应用层优化

### A. 复用详情响应，并保留稳定身份

优化前证据：`MacCmsV10Adapter.fetchDetail` 与 `resolvePlayback` 请求相同的 `ac=detail&ids=...`。前者已经解析线路，却对返回 `Video` 清除播放 URL 和 `playbackLines`。详情页点击时再次发请求。

实施状态（2026-10-02）：采用单模型方案。MacCMS `fetchDetail` 保留原有展示 `episodes`（URL 仍为空）及已解析的完整 `playbackLines`；仓库只缓存这一份 `Video`，播放时轻量投影共享线路、剧集与字符串，不长期保留原始 JSON 或第二份完整播放快照。列表和搜索模型不保留播放线路，其他适配器继续各自播放解析。

缓存按源 ID、API 地址、协议、插件配置及视频身份隔离，TTL 两分钟、LRU 最多 32 条、估算容量 8 MiB，定时清理过期数据，超大条目不缓存。估算预算并非进程内存硬上限；当前页面引用与刷新中新旧数据共存仍影响峰值。同一资源并发请求合并，显式重试强制刷新，较早请求晚返回不能覆盖刷新结果，刷新失败不返回旧缓存。MacCMS 起播时解析页或 HLS 清单的结构化 HTTP 401/403/404/410 最多触发一次自动刷新；原生失败没有结构化 HTTP 状态时使用手动重试。线路与剧集按稳定身份、名称匹配，不用页面索引或过滤后重编号的 ID 播放另一集。无需预先选定某一集，不新增媒体请求。

离线入口同时修复：Mac 初始详情保留完整线路身份，详情页先从首选线路匹配当前集，再严格匹配已完成任务的线路与剧集身份。最终仍由下载管理器校验离线文件；没有放宽跨线路匹配。

收益边界：有效快照命中时可移除本轮平均 255ms 的请求（本轮范围 188–448ms）。这是待验证的可消除阶段，不是已经测得的净收益。完整下载场景还可减少网络依赖。

2026-10-02 功能验证：`fvm flutter analyze` 无问题；诊断开启的仓库/详情缓存/剧集匹配/HLS/会话/解析器/播放器/详情切源专项共 129 项通过，详情页实际点击复用回归通过。整体回归 662 项通过、3 项跳过，仍有此前已记录的两项失败（首页透明导航标签宽度、从播放器返回后展开第 120 集分组）；排除此前已确认挂起的 Wi-Fi 单次蜂窝恢复测试。日志分别保存于 `logs/detail_playback_reuse/focused.log`、`regression.log`。请求计数验证详情到任意剧集播放由两次详情请求减少为一次，尚未做设备首帧与堆内存实测。

### B. 跳过策略与网络准备并行

`_setup` 首先 await `_loadSkipPolicy`，其后才解析地址和清单。跳过策略只需要在确定起点、seek/首段定位前就绪。

先启动策略读取，再启动独立的源解析/HLS 准备，在使用目标起点前汇合；每条异步路径保留 generation 校验。命中 provider 已有数据时直接使用快照。

收益边界：本轮串行等待平均约 43ms，可被网络阶段覆盖。若同时推进原生初始位置方案，汇合点必须提前至设置该位置之前。

A+B 对本轮正常路径可消除/覆盖的时间量级约 0.30s，约为当前 5.32s 的 6%。两者不足以解释或实现从五秒降到一秒。

### C. 首帧前让前台请求优先，避免预取抢带宽

当前预取在现有追踪完成之后启动，默认并发 5；它不是本轮 initialize 3.71s 的起因，但可能在实际首帧出现前就开始。`pause()` 只阻止下一批，不中断在途批次。显式下载还持有独立的并发池。

前台 `singleFlight` 在返回包含流的 `CacheFetchResult` 时就完成，未覆盖整个 body。后台预取可能把原生仍在下载的第二/第三段再次下载；把单订阅 body 直接共享给两个消费者也不可行。

方案：

- 原生首帧与安全缓冲条件满足后启动后台预取，先小并发，再按实际缓冲/吞吐渐增。
- 前台资源在途标记覆盖响应头到 body 完成/取消，后台遇到该资源让行。
- 首帧等待、seek、再缓冲期间暂停新后台工作，对可取消的在途后台请求让出网络；前台结束后恢复。
- 显式下载与播放预取使用共同的前台优先调度规则，避免两套各 5 并发同时竞争。

收益目前未量化。验收必须包含 play 到首帧及起播后卡顿，而非只看现有 trace 总时长。

## 4. 针对主要网络耗时的实验

### D. 对照代理 HTTP 响应语义

`ResourceFetcher._fetchAndCache` 删除 `Content-Length`；上游 body 结束后，等待文件关闭、完整性检查和缓存提交才关闭下游流。当前缓存提交均值约 5.23ms，不能据此声称能省秒；但原生对已知长度与流结束的处理是否不同，值得验证。

用内容、广告过滤结果、码率、缓存状态完全一致的资源，一次只改变一个因素：

1. 当前代理作为基准。
2. 测试可信 `Content-Length` 保留；存在内容编码/转换时禁止照搬错误长度。
3. 独立测试下游媒体交付完成与缓存提交解耦，缓存引用持有到提交完成，失败不发布完整缓存记录。
4. 同媒体字节的代理缓存旁路与原生直连，仅作为诊断对照。

记录原生请求第二段时点、ready、首帧和卡顿。当前代码已经边收边转，不能把它描述为“全段落盘后才开始返回”。切断代理会影响广告过滤、离线与请求头能力，不能直接作为默认提速方案。

### E. 减少首段体积，选择可承受的码率/线路

当前 `_firstVariantUri` 固定选第一条变体，代理向原生提供单个 media playlist。先记录版本数量、所选带宽/分辨率、分片时长、字节量、吞吐和失败率，再决定是否引入按用户画质偏好/网络吞吐选版本。

多码率时降低起播资源体积有较大潜力；单码率时无此收益。当前单 media 代理不能靠设置原生码率上限自动获得其他版本；若要起播后自适应升清晰度，需要扩展 master/变体代理，并确保时间轴、广告过滤和缓存 revision 一致。

同画质多线路可用历史成功率/吞吐选择更快线路，避免点击时对所有线路先测速。分片切短、关键帧布局和 CDN 改善需要源站能力，第三方源不能靠 Flutter 参数实现。

不优先做“清单完成后提前拉首段”：当前 HLS 准备结束到首资源请求平均仅约 32ms，单纯重叠这段的空间很小。首两段并行是另一种实验，但可能争抢固定带宽或重复请求，需先完成请求所有权与在途去重，不能直接把现有 5 并发预取提前。

### F. 原生缓冲参数只在首帧数据齐备后调整

先把初始化拆出平台创建、清单/首资源请求、ready、等待原因、首帧。iOS 的播放等待参数不能直接保证缩短 ready 之前的下载。Android 的起播缓冲参数也应依据本项目锁定的 Media3 版本和真实设备验证。

设置更低缓冲会增加再缓冲风险；`preferredForwardBufferDuration=0` 在 iOS 表示系统自行决定，不表示零缓冲。以首帧 P50/P90、30 秒卡顿和失败率共同验收。[Apple 缓冲说明](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration?language=objc)、[Android LoadControl](https://developer.android.com/reference/androidx/media3/exoplayer/DefaultLoadControl.Builder)。

## 5. 条件场景与异常路径

| 场景 | 现状 | 建议 | 收益边界 |
| --- | --- | --- | --- |
| unknown/HTML/插件源 | 格式识别 GET 得到 HLS 后丢弃正文；部分候选 HEAD→Range→正式 GET | 解析结果携带完整清单及最终地址；HLS 用正式 GET 同时验证和解析；媒体探测限量读取并取消剩余流 | 本轮正常 HLS 解析仅 0.193ms，因此不计入正常路径收益 |
| 相同剧集重复播放 | 每次解析 master/media | 有效期内复用点播清单与解析结果，按请求头、源身份、过滤版本隔离，过期/资源失败刷新 | 热启动可能省部分清单网络时间；首次新集仍需请求，不能省掉必要依赖 |
| 续播/跳片头 | 初始化开头后再 seek | 目标位置尽早传入原生准备，或实验兼容的 HLS 起点提示；正确映射过滤时间轴并保留回退 | 有望减少无用开头下载；本轮无 resumeSeek，未量化 |
| 切集/重试 | 等旧会话 activeReads 排空最多 2s，再 flush，然后开始新 setup；重试还先刷新详情 | 停旧音频、隔离旧路由后，把旧 IO 清理与新集地址/清单准备重叠；缓存引用最后释放 | 条件下可覆盖 0–2s 排空及部分 flush；不影响首次冷播放 |
| 异常源 | URL、清单、代理、直连各有局部超时；Future.timeout未必取消底层请求 | 按一次点击共享剩余时间预算；超时/换集真正取消所属请求；按过期、HTTP错误、不支持格式、无进展选择恢复方式 | 缩短长尾、避免废弃请求继续抢网，正常成功样本不直接提速 |
| 大量缓存/冷初始化 | 下载选择依赖完整 manager 初始化，包含目录对账、清理、配额等 | 分离可查询索引与后台维护，或在通用初始化阶段准备；查询仍保持离线正确性 | 本轮平均3ms，需大缓存冷启动专项证据，暂不当热点 |

会话内 resolver、parser、proxy 已复用 `_sessionClient`，所以“所有请求都新建连接”不是事实。跨页面连接复用或 HTTP 栈替换需先测 DNS/TLS/连接复用率及同主机关系，再决定；不把换网络库当确定收益。

## 6. 实施与验收顺序

1. **补首帧与完整点击计时，固定样本。** 追踪网络/原生/页面事件关联到同一播放 generation；新增分片大小、时长、码率、后台并发与取消事件，避免记录带签名的完整 URL。
2. **做 A+B，并修正离线身份匹配。** 最小改动、已有明确等待；用请求计数及相同环境下的点击到首帧验证。
3. **做 C，并进行 D 的单因素实验。** 覆盖当前追踪遗漏的首帧前竞争，验证原生是否受代理响应语义影响。
4. **按数据选择 E/F；逐项推进 unknown、热启动、续播、切集和异常路径。** 不把仅在条件场景有效的收益汇总成统一提速比例。

自动化应固定 source/video/line/episode/画质/起点，保存当次清单与分片特征摘要；交替运行基准与改动版本，分开冷缓存和热缓存。先每种代表场景做多轮试验，样本足够后再评估长尾，10 个不同影片不能支撑可靠 P95。

场景至少覆盖：普通 HLS、unknown、完整离线、续播/跳片头、切集、弱网无进展、同时后台下载。性能验收在 iOS/Android 真机 profile/release 执行，debug 模拟器用于功能诊断。

输出请求数、关键路径耗时、首帧 P50/P90、失败率、起播字节与起播后30秒卡顿；出现播放器失败或首帧超时必须使回归任务失败。现有 `playback_trace_top10_test.dart` 只断言访问了10个卡片，适合采样，尚不适合作为提速门禁。

## 7. 代码定位

- `lib/features/detail/detail_page.dart`：`_play`、`_cachedSelectionForCurrentEpisode`。
- `lib/data/vod_source/adapters/mac_cms_v10_adapter.dart`：`fetchDetail`、`resolvePlayback`、`_videoFromJson`。
- `lib/data/video_repository.dart`、`lib/data/vod_source/video_detail_cache.dart`：详情复用、强制刷新、并发合并、配置隔离与容量/TTL 淘汰。
- `lib/features/player/parts/player_session_lifecycle.dart`：`_setup`、`_installController`、`_disposeDetachedPlayback`、`_retry`。
- `lib/features/player/parts/player_episodes.dart`：`_switchEpisode`、`_resolvePlaybackSource`。
- `lib/data/playback/playback_url_resolver.dart`、`hls_parser.dart`、`playback_session.dart`：地址、清单与会话准备。
- `lib/data/cache/cache_io.dart`、`single_flight.dart`：资源传输、缓存提交和在途请求。
- `lib/data/playback/local_proxy.dart`：HTTP响应与资源计时。
- `lib/data/download/download_manager.dart`、`download_task_manager.dart`：后台预取与下载并发。

原始数据与上一轮验证记录见 `logs/playback_startup_optimization/analysis.md`。A 项之外的建议尚未实施；A 项功能回归记录在 `logs/detail_playback_reuse/`，尚未测得新方案的净提速或实际堆内存变化。
