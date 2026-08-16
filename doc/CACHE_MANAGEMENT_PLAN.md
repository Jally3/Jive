# 边播边下、广告过滤与缓存管理 —— 设计与实施计划

> 目标：在 `video_player`（Android Media3/ExoPlayer、iOS AVPlayer）之上实现「边播边下、看过不重复耗流量、下次快速起播」，并提供严格的缓存配额、淘汰和管理能力。
>
> 本文区分两类内容：已经明确、可直接实施的设计写入主方案；涉及产品范围、平台成本或用户体验取舍的事项集中在第 11 节，实施前由产品/技术负责人审核决定。

---

## 1. 现状与差距

当前播放链路（`lib/features/player_page.dart:74-118`）：

```dart
VideoPlayerController.networkUrl(Uri.parse(episode.url), formatHint: ...)
```

- 播放地址由 `MacCmsV10Adapter` 解析为 `Episode.url`，当前模型只携带 URL，不携带请求头或明确的媒体格式。
- 播放器直接访问远端地址；多数地址预计为 HLS，但现有链路也允许播放器尝试其他格式。
- 已有：续播记忆（`WatchRecord`）、地址失效重试（`_retry`）、seek、倍速、音量、横竖屏切换。
- 缺失：HLS 能力探测、本地 HTTP 代理、磁盘片段缓存、并发预下载、缓存索引、广告过滤、管理 UI。
- `_setup`、`_retry`、`_switchEpisode` 都包含异步初始化流程，缓存接入时必须增加播放 generation，防止快速切集/重试后旧任务反向覆盖新 controller。

| 角色 | 需要新增 | 现状 |
|---|---|---|
| 播放会话协调器 | 新建 | 无 |
| HLS 能力探测与解析 | 新建 | 无 |
| 本地代理服务器（loopback） | 新建 | 无 |
| 前台并发预下载器 | 新建 | 无 |
| 磁盘片段缓存与派生索引 | 新建 | 无 |
| 广告过滤与时间轴映射 | 新建 | 无 |
| 缓存管理 UI | 新建 | 无 |

---

## 2. 总体架构

```text
┌──────────────┐       ┌──────────────────────┐       ┌──────────────┐
│ VideoPlayer  │──────→│ 本地代理 127.0.0.1   │──────→│ 本地完整片段 │
│ 只访问代理地址│       │ 会话路由 + single-flight│      └──────────────┘
└──────────────┘       │                      │       ┌──────────────┐
                       │ 未命中：回源并边转发边落盘 ├──────→│ 远端 CDN     │
                       └──────────────────────┘       └──────────────┘
                                  ↑
                       ┌──────────────────────┐
                       │ 前台预下载调度器       │
                       │ 容量预留 + 附近片段提权 │
                       └──────────────────────┘
```

四个核心角色：

1. **播放会话协调器**：创建 `PlaybackSession`，持有 generation、代理路由、缓存引用和下载任务；统一处理初始化、切集、重试和释放。
2. **播放器**：对可代理的 HLS 只访问 `http://127.0.0.1:<port>/play/<sessionToken>/index.m3u8`，不根据片段是否落盘更换播放地址。
3. **本地代理**：manifest 中所有受支持的媒体 URI 都改写为会话内代理 URI；收到资源请求后，本地命中则读盘，未命中则回源，并将同一份响应同时流给播放器和临时文件。
4. **预下载调度器**：播放页存活期间按优先级预取后续资源；与代理共享 single-flight 表，不能重复下载同一资源。

### 2.1 稳定代理目录

- 同一个源版本和过滤版本对应一份不可变代理 manifest。
- manifest 中的资源地址始终指向代理；资源是否已缓存由代理收到请求时动态判断。
- 下载进度变化不需要重写 manifest，也不需要“每下载一批切换快照”。
- 只有远端 manifest 版本或广告过滤结果改变时，才生成新 manifest 版本和新会话。

### 2.2 安全回退原则

任何能力探测、解析、代理启动或缓存操作失败，都不得阻断原有播放能力：

- 不支持的媒体格式或 HLS 特征：直接使用现有远端播放链路。
- 配额不足、磁盘写入失败：代理继续回源，不落盘。
- 索引损坏：隔离损坏记录并异步重建，不影响直连播放。
- 广告过滤失败或结果不可信：使用未过滤 manifest。
- 完整缓存命中：不依赖远端 manifest 即可离线播放；部分命中仍需要网络。

---

## 3. HLS 解析、能力探测与代理契约

### 3.1 正确识别播放类型

不能只用 URL 后缀或 `#EXT-X-ENDLIST` 判断媒体类型：

1. 请求播放地址，跟随受控重定向，并依据 Content-Type、响应内容和最终 URL 综合识别。
2. 若为 Master Playlist，先解析 `#EXT-X-STREAM-INF` 并选择媒体变体；Master Playlist 没有 `#EXT-X-ENDLIST` 不能据此判定为直播。
3. 仅对最终 Media Playlist 判断 VOD/直播：VOD 通常含 `#EXT-X-ENDLIST`；EVENT/直播默认不缓存并回退直连。
4. MP4、DASH、无法解析或能力范围外的 HLS 均保持现有直连播放。

### 3.2 URI 解析与改写

- 所有相对 URI 必须使用其所在 manifest 的最终响应 URL 作为 base URI 解析。
- 必须保留业务查询参数；不能把父 manifest 的查询参数无条件附加到子资源。
- 除普通媒体片段外，解析器必须识别所有 URI 承载位置，例如 `EXT-X-KEY`、`EXT-X-MAP`、媒体轨和 I-frame playlist；未支持的 URI 标签触发安全回退。
- 保存原始 manifest 和派生代理 manifest，便于诊断、重建和回滚过滤结果。

### 3.3 代理 HTTP 契约

- 缓存 MVP 引入轻量可选的 `PlaybackSource(url, format, headers)` 契约，取代播放链路只传裸 URL 的假设；当前 MacCMS 适配器返回空 headers，用户体验和现有来源行为不变。
- 直连播放器、HLS 能力探测和本地代理必须使用同一个 `PlaybackSource` 请求上下文，避免直连可播但代理回源缺少 Referer/User-Agent 等信息。
- `PlaybackSource.headers` 构造时复制为不可变 Map，调用方不能在对象创建后修改请求上下文。
- `PlaybackSource` 的普通值相等性不能用于网络请求去重或缓存身份；同 URL、不同会话 headers 可能返回不同内容。网络 single-flight 使用独立的请求键，缓存身份使用 `ContentKey`/manifest fingerprint。
- headers 分为两类策略：适配器提供给源站的会话 headers（如 Referer、User-Agent，以及来源明确要求的 Authorization/Cookie）和播放器请求本地代理时允许透传的逐请求 headers（如 Range/If-Range）。两类白名单不得混用。
- Cookie、Authorization 等敏感值即使允许回源使用，也仅驻留当前播放会话内存，不进入 `state.json`、index、contentKey、revisionKey 或日志。
- `Accept-Encoding` 由代理统一控制，避免自动解压后 Content-Length/Range 语义不一致；hop-by-hop headers 一律不转发。
- 仅绑定 `127.0.0.1`/loopback，不监听局域网接口。
- 会话路径使用高熵随机 token；外部请求只能访问已注册会话和资源 ID，不能传入任意远端 URL，避免成为开放代理。
- 至少正确处理 `GET`、`HEAD`、`Range`、`206 Partial Content`、`Content-Type`、`Content-Length` 和客户端取消。
- 仅转发白名单请求头和响应头，禁止记录包含 token、Cookie、Authorization 的完整 URL/headers。
- 远端重定向需限制次数和协议；默认只接受 HTTPS 回源。
- 对 401/403、404/410、超时、5xx 分别分类，不能把远端鉴权/服务错误标记为本地文件损坏。

### 3.4 支持能力表

MVP 采用“实用型”范围：

- 支持 Master Playlist，并从中选择一个视频变体。
- 支持未加密 MPEG-TS/fMP4 VOD Media Playlist，以及 `EXT-X-MAP`、`EXT-X-BYTERANGE`/Range 请求。
- 多音轨、外挂字幕、AES-128、SAMPLE-AES、DRM 和其他未纳入能力矩阵的标签回退现有直连播放，不进入代理缓存和广告过滤。
- 解析器必须先完成能力探测，再决定“代理缓存”或“原链路直连”，禁止带着未知标签部分执行。

---

## 4. 边播边下与播放会话生命周期

### 4.1 `PlaybackSelection` 与稳定身份

缓存和播放器之间传递明确的播放选择，而不是只传一个脱离线路上下文的 `Episode`：

```dart
class PlaybackSelection {
  final String playbackLineIdentity;
  final String episodeIdentity;
  final Episode episode;
  final PlaybackSource playbackSource;
}
```

- `PlaybackLine` 增加来源稳定的 `identity`；现有 `id/name` 继续用于 UI，不能作为缓存身份。
- `Episode` 增加来源稳定的 `identity`；现有顺序型 `id` 保留用于 UI 兼容，不能进入 contentKey。
- `PlaybackSelection.playbackSource` 是该次解析得到的实际请求上下文；稳定 identity 与可能过期的 URL/headers 分离，地址刷新只替换 playbackSource 和 revision，不改变语义 contentKey。
- MacCMS 的 `playbackLineIdentity` 由原始线路下标和规范化 `vod_play_from` 标识生成，不能使用过滤后的 `lines.length`。
- MacCMS 的 `episodeIdentity` 由原始条目下标和 `normalizedName` 生成，不能使用过滤后的 `result.length`。
- 适配器只构建一次 `playbackLines`；`Video.episodes` 是默认线路 episodes 的兼容视图，不能再次独立解析出另一组对象。
- 即使 MVP 暂时没有线路切换 UI，详情页也必须确定默认线路，并将完整 `PlaybackSelection` 传入 `PlayerPage`。
- 播放器内切集只在当前线路内产生新 selection；重试优先按稳定 line/episode identity 匹配，旧数据才退回线路内 name/id 兼容匹配。

### 4.2 `PlaybackSession` 状态

建议状态机：

```text
preparing → ready/playing → closing → closed
    └──────────────→ failed ────────────┘
```

每个会话至少包含：

- `sessionId`：缓存任务归属和作废检查。
- `sessionToken`：仅用于本地代理路由，不写日志。
- `setupGeneration`：页面级递增值，防止旧 `_setup` 结果覆盖新会话。
- `contentKeyHash`、`revisionKeyHash`、manifest fingerprint、filterVersion。
- 活跃读取数、活跃写入数、下载取消令牌。

### 4.3 初始化

1. `_setup` 接收不可变的 `PlaybackSelection target`，捕获当前 generation，创建候选会话；await 之后不能重新读取页面上可变的 `episode`。
2. 探测媒体类型和缓存能力；完整缓存命中时跳过远端刷新。
3. 代理就绪后再创建 `VideoPlayerController`。
4. 每次 await 后检查 `mounted`、generation 和会话身份。
5. 只有仍为当前 generation 的 controller 才能安装到页面并开始播放。
6. 准备代理或 manifest 超时后关闭候选会话并回退直连，不能无限延长现有 20 秒初始化体验。

### 4.4 切集、重试和退出顺序

切集、重试或离开页面时统一执行：

1. generation 递增，使所有旧异步结果失效；`_setup`、`_retry`、`_switchEpisode` 和 `dispose` 都必须使旧 generation 作废。
2. 保存当前播放进度。
3. 取消旧会话预下载任务。
4. 先把当前 controller/session 从页面字段取出并置空，再移除监听和 dispose，避免两个异步流程重复处理同一对象。
5. 等待活动代理读取自然结束或超时取消，再释放缓存引用和代理路由。
6. 创建新会话。

播放器错误后的重试：

- 记录旧播放位置。
- 重新调用 `resolvePlayback` 获取新 URL。
- 在同一 `playbackLineIdentity` 内按 `episodeIdentity` 重新定位；禁止继续使用跨线路的 `name == ... || id == ...` 匹配。
- 使用语义缓存键寻找已有片段，用新 manifest 指纹校验是否仍兼容。
- 兼容则复用片段；不兼容则保留旧目录待淘汰并创建新版本。
- 初始化成功后按正确时间轴恢复位置。

### 4.5 前台预下载调度

- 默认并发上限为 5，但应支持按网络、设备和来源动态降低。
- 当前播放位置附近资源最高优先级，随后按播放顺序预取。
- 重试使用指数退避、抖动和总次数/总时长上限；4xx 不进行无意义重试。
- 使用连接复用；HTTP/2 只能作为经客户端和真机验证后的优化项，不能作为既定保证。
- MVP 仅支持前台预下载：播放页面存活且应用位于前台时调度预取；进入后台后保存进度并暂停普通 Dart 下载任务，重新进入播放会话后续传。
- 当前播放实际请求不受 Wi-Fi 限制；主动预下载默认只在 Wi-Fi 下执行，蜂窝网络不主动预取。
- MVP 不实现 Android/iOS 系统后台下载、后台通知或进程终止后自动继续；若未来需要，作为独立项目设计。

---

## 5. 缓存身份、磁盘布局与一致性

### 5.1 缓存身份

禁止直接采用“任意剥掉 token 后的 URL 哈希”。缓存身份分两层：

1. **语义键 `contentKey`**：`sourceId + sourceVideoId + playbackLineIdentity + episodeIdentity`。所有字段来自完整 `PlaybackSelection`；剧集编号和显示名称只能作为辅助字段。
2. **内容版本 `revisionKey`**：规范化后的 manifest URL + 最终 URL + manifest 结构指纹；可用时同时记录 ETag/Last-Modified。

`contentKey` 只能由唯一的 `ContentKeyBuilder.v1` 生成：

- 使用带版本号的规范字段编码（例如 canonical JSON 或长度前缀编码），再计算 SHA-256；禁止各模块自行用冒号等分隔符拼接。
- `contentKeyHash` 是磁盘目录和 manager 查找键；state/index 同时保存必要的非敏感身份字段用于诊断和重建，但不保存可被误解析的原始拼接 key。
- `playbackLineIdentity` 和 `episodeIdentity` 在阶段 1 schema v1 冻结前加入缓存模型；adapter → detail → player 的实际传递在阶段 2 接通。
- 任何无法取得稳定 selection identity 的播放源不进入缓存，保持直连；不能退回顺序型 `Episode.id` 悄悄生成弱身份。

URL 规范化规则：

- 每个内容源维护“确定为时效参数”的参数名白名单，只删除白名单字段。
- 未知查询参数必须保留，避免不同资源碰撞。
- 若来源没有规则，默认不删除任何参数。
- 索引和日志保存脱敏 URL 或哈希；需要恢复请求的临时签名 URL只保存在当前会话内存中。

manifest 片段数量、时长、URI 结构或关键标签变化时视为新 revision，不得把旧缓存直接标记为完整。磁盘只持久化 `revisionKeyHash`、manifest fingerprint 和脱敏诊断字段；不得保存可能包含签名参数的原始 revisionKey/完整 URL。

### 5.2 建议磁盘布局

```text
<storageRoot>/jive_cache/
  index.json                         # 可重建的全局物化索引
  entries/
    <contentKeyHash>/
      <revisionHash>/
        state.json                   # 本 revision 的权威元数据
        source_manifest.m3u8         # 脱敏后的原始 manifest
        proxy_manifest.m3u8          # 派生代理 manifest
        timeline.json                # 过滤映射；未过滤时可省略
        resources/
          <resourceId>.<actualExt>   # 完整资源
        partial/
          <resourceId>.part          # 未完成资源，不计为命中
```

- 扩展名根据媒体资源类型决定，不能固定为 `.ts`。
- 完整状态由 manifest 依赖图内所有离线播放必需资源均校验成功决定，不等同于“片段文件数量相等”。
- `.part` 文件在进程重启后按恢复策略续传或清理。

### 5.3 权威数据与派生索引

- 各 revision 的 `state.json` 是权威数据。
- `index.json` 只是缓存管理页面和统计使用的物化索引，损坏或丢失时可由 `state.json` 重建。
- 阶段 1 冻结缓存 schema v1；`state.json`、`timeline.json`、`index.json` 各自包含 `schemaVersion`。
- 所有 JSON 通过同目录临时文件写入，完成后原子替换；进程启动时清理或恢复遗留临时文件。
- 全局索引写入由单一协调器串行化，并进行节流；不能在每个并发片段完成时同时覆盖 `index.json`。
- 启动校验异步执行，不阻塞首屏；先加载最近一次有效索引，再逐项修正统计。

`state.json` v1 字段示例：

```json
{
  "schemaVersion": 1,
  "contentKeyVersion": 1,
  "contentKeyHash": "sha256:...",
  "revisionKeyHash": "sha256:...",
  "manifestFingerprint": "sha256:...",
  "filterVersion": 0,
  "timelineVersion": 0,
  "sourceId": "storm",
  "sourceVideoId": "42",
  "title": "影片名",
  "playbackLineIdentity": "macv10:line:0:...",
  "playbackLineName": "线路1",
  "episodeIdentity": "macv10:episode:0:...",
  "episodeId": "1",
  "episodeName": "第1集",
  "status": "partial",
  "expectedResourceCount": 120,
  "committedResourceCount": 40,
  "completeBytes": 104857600,
  "partialBytes": 1048576,
  "offlinePlayable": false,
  "lastAccessMs": 0,
  "createdAtMs": 0,
  "updatedAtMs": 0,
  "errorSummary": null,
  "resources": {
    "sha256:resource-id": {
      "resourceType": "segment",
      "status": "complete",
      "size": 2621440,
      "ext": "m4s",
      "rangeStart": null,
      "rangeEndExclusive": null,
      "totalLength": 2621440,
      "etag": null,
      "lastModified": null,
      "lastAccessMs": 0
    }
  }
}
```

`index.json` v1 字段示例：

```json
{
  "schemaVersion": 1,
  "generatedAtMs": 0,
  "entries": [
    {
      "contentKeyVersion": 1,
      "contentKeyHash": "sha256:...",
      "revisionKeyHash": "sha256:...",
      "manifestFingerprint": "sha256:...",
      "sourceId": "storm",
      "sourceVideoId": "42",
      "title": "影片名",
      "playbackLineIdentity": "macv10:line:0:...",
      "playbackLineName": "线路1",
      "episodeIdentity": "macv10:episode:0:...",
      "episodeId": "1",
      "episodeName": "第1集",
      "status": "partial",
      "expectedResourceCount": 120,
      "committedResourceCount": 40,
      "completeBytes": 104857600,
      "partialBytes": 1048576,
      "offlinePlayable": false,
      "lastAccessMs": 0,
      "createdAtMs": 0,
      "updatedAtMs": 0,
      "errorSummary": null
    }
  ]
}
```

schema 读取规则：

- index 顶层版本不是 1：放弃该 index，并从 state 重建；不能用 v1 默认值静默解析未知版本。
- state 版本不是 1：跳过并隔离该 revision，记录脱敏诊断；不能让未知版本参与统计、命中或淘汰。
- 缺少稳定 identity/hash、数值为负、计数/字节不一致或枚举未知的记录视为无效；单项无效不能拖垮其他有效条目。
- `resourceId` 必须是内部生成的固定格式 hash，`ext` 和 `resourceType` 来自枚举白名单；远端 URL、文件名和任意路径不得直接参与本地路径拼接。
- state/index 不持久化原始 contentKey、revisionKey、签名 URL 或请求 headers。
- 原子替换失败时不能退化为直接覆盖目标文件；保留上一份有效文件并报告失败。启动清理同时覆盖根目录的 `index.json.tmp` 和 entries 内临时文件。

### 5.4 片段完整性

统一流程：

1. 为预计写入大小申请容量预留；大小未知时使用保守预留并设置系统磁盘安全余量。
2. 写入 `partial/<id>.part`，不向播放器报告本地命中。
3. 校验 HTTP 完整性、已知 Content-Length/Range 和非空响应；格式专属校验只用于对应格式。
4. 校验成功后原子移动到 `resources/`，提交实际字节数并释放预留。
5. 失败或取消则释放预留，保留可续传的 part 或按策略清理。

“TS 同步字节”不能作为通用完整性标准，因为 fMP4、加密 HLS、ID3 开头和部分 Range 都不满足该假设。

### 5.5 Range、206 与 partial 合并规则

阶段 2 原型可以评估重叠 Range 合并是否值得实现，但 MVP 正确性基线现在冻结：

- single-flight 使用 `revisionKeyHash + resourceId + normalizedOriginRange`；只有规范化后完全相同的源站 Range 请求可以合并。
- 已完整缓存的 200 整资源可以直接服务任意合法子 Range。
- 不同或仅部分重叠的 206 请求在 MVP 中分别处理，不能因为 URL 相同就共用同一 `.part`。
- 多个 206 只有在区间连续且完整覆盖、总长度一致、ETag/Last-Modified 一致、Content-Range 全部合法时，才允许组合为完整资源。
- `.part` 续写要求源站支持 Range、响应起点等于当前文件长度，并且 validator/totalLength 未变化；任一条件不满足都丢弃旧 part 后重新请求。
- Range 请求收到 200 表示源站忽略 Range：不得追加到原 206 part；可作为新的完整资源处理，并按源站实际响应语义返回播放器。
- HLS 声明的 BYTERANGE 与播放器发给本地代理的下游 Range 必须分别解析，再换算成唯一的源站区间，禁止直接拼接两个 Range header。

---

## 6. 配额、并发、淘汰与清理

### 6.1 容量协调器

- 默认动态目标配额为可管理空间的 15%，目标下限 1GB、目标上限 8GB。
- MVP 只提供“自动配额”，不允许用户手动覆盖，不提供 1GB/2GB/5GB/不限等档位；后续根据真实设备指标重新评审是否开放手动设置。
- 为避免缓存写入本身导致“可用空间下降 → 配额下降 → 立即淘汰”的反馈循环，可管理空间按 `当前可用空间 + Jive 当前缓存占用` 计算。
- 系统安全余量为设备总容量的 5%，最低 2GB、最高 10GB；有效配额不得占用安全余量。空间不足时，有效配额允许低于 1GB，甚至降为 0 并停止落盘，不能为了满足目标下限挤满设备。
- 有效配额计算：`min(clamp(可管理空间 × 15%, 1GB, 8GB), max(0, 可管理空间 − 系统安全余量), 平台缓存上限)`；不支持查询平台缓存上限时忽略最后一项，但仍执行安全余量限制。
- Android 优先参考 `StorageManager.getCacheQuotaBytes()`/可分配空间；iOS 优先参考 volume available capacity for opportunistic usage。配额在启动、回到前台和大文件写入前重算，不在每个片段后频繁波动。
- 容量计算为：已提交完整文件 + 活跃写入预留；`.part` 也必须受临时文件上限约束。
- 配额检查、容量预留、LRU 淘汰和提交在同一协调器内串行执行，避免多个并发任务同时通过检查。
- 除逻辑配额外保留系统磁盘安全余量；系统剩余空间不足时，即使逻辑配额未满也停止落盘。
- 无法淘汰足够空间时，当前资源只回源播放，不写缓存。

### 6.2 single-flight 与引用保护

- 代理和预下载器共享以 `revisionKeyHash + resourceId + normalizedOriginRange` 为键的 single-flight 表；具体 Range 裁决遵循第 5.5 节。
- 同一资源只有一个远端请求和一个磁盘写者，其余消费者订阅同一数据流或等待结果。
- 活跃读取、写入和播放会话都持有引用；引用未归零的 revision 不能被自动淘汰。
- 引用计数仅代表当前进程状态，进程重启后通过清理 `.part` 和重建索引恢复，不把旧引用持久化为有效锁。

### 6.3 LRU 语义

- `lastAccess` 仅在实际播放或代理读取资源时更新。
- 后台预下载、索引扫描、打开缓存管理页不能更新 `lastAccess`。
- 自动淘汰只选择无活跃引用的条目。
- 自动淘汰先选择最久未访问的部分缓存，再选择最久未访问的完整缓存，尽量保留可离线播放的完整内容。
- 磁盘存储、手动删除和自动淘汰的基本单位均为剧集 revision；UI 按影片分组展示，避免一集空间不足时删除整部影片的其他缓存。

### 6.4 手动清理

- 删除前先在容量协调器中把条目标记为 `deleting`，阻止新读取和写入进入。
- 取消该条目下载并等待活动 I/O 结束，再删除目录；删除成功后更新派生索引。
- 文件删除失败时保留可恢复的 deleting 状态，下一次启动继续清理，不能先从索引消失后永久泄漏磁盘文件。
- “清理全部”按同样流程逐项执行，并返回成功、跳过活动项和失败项统计。
- 活动播放项始终受底层引用保护，自动淘汰不得选中。
- 手动删除命中活动项时禁止立即删除，保持播放器和代理会话不变，并提示“播放结束后可删除”。
- 当前导航下用户通常会先退出播放器再进入缓存管理；上述规则主要处理退出收尾竞态、自动淘汰以及未来小窗/画中画等入口。

---

## 7. 广告过滤与时间轴

识别原则：**宁可漏过，不可误伤；过滤失败必须回退原始 manifest。**

| 层 | 利用的规律 | 关键判据 | 防误伤机制 |
|---|---|---|---|
| 明牌规则 | 地址中存在明确广告标记 | 仅匹配经审核的路径/参数规则 | 不使用宽泛子串误删正常域名 |
| 1 帧率节奏 | 正片时长落在相似网格 | 主导网格 ≥90%，异类块短且集中 | 无主导网格时放弃 |
| 2 域名聚类 | 插播资源可能来自异域 | 主导域名 >70%，异域形成短连续块 | 多 CDN 或证据冲突时放弃 |
| 3 序号跳变 | 文件名序号进入另一段 | 可解析率 ≥80%，跳变和短块同时满足 | 单独序号异常不定罪 |
| 4 断点+时长 | 广告可能由 discontinuity 包裹 | 宽松聚类后再以严格阈值确认 | 两道阈值同时通过 |
| 5 短片段聚类 | 插播常为连续短片段 | 连续 ≥5 且均值显著短于基准 | 单个短片段不删除 |
| 6 结构侏儒块 | 小块夹在两个稳定大块之间 | ≤8 段、≤45 秒且两侧稳定 | 首尾块豁免 |
| 7 PTS 校验 | 插播可能使用独立时钟 | 跳变与复位同时满足 | 作为后续独立能力，不阻塞 MVP |

### 7.1 原始资源与派生结果分离

- 保留未过滤的源 manifest；过滤只生成派生 manifest 和 `timeline.json`。
- 片段缓存按原始资源 ID 存储，不因规则调整重复下载。
- `timeline.json` 保存 manifest fingerprint、filterVersion、被移除区间、原始/过滤时间映射和置信度。
- 过滤算法升级后重新生成派生 manifest；不得把旧映射套到新 manifest。
- 任何结构校验失败都使用原始 manifest。

### 7.2 播放进度语义

- 播放器 UI、`VideoPlayerController.position` 和过滤后 manifest 使用过滤时间轴。
- `WatchRecord` v2 持久化原始 source/剧情时间轴位置，并同时保存时间轴类型、filterVersion、manifest fingerprint、映射版本和稳定播放选择身份。
- 保存进度时将过滤时间轴换算成原始剧情时间轴；恢复到过滤 manifest 时再从原始剧情时间轴换算到当前播放时间轴。
- 恢复播放、地址刷新、过滤开关变化和回退直连时，必须通过持久化映射转换位置。
- 完成度判断使用当前播放 manifest 的有效时长，不能把过滤后位置直接除以原始时长。

`WatchRecord` v2 新增/冻结字段：

```json
{
  "schemaVersion": 2,
  "positionMs": 120000,
  "durationMs": 2700000,
  "timelineType": "source",
  "filterVersion": 0,
  "manifestFingerprint": null,
  "timelineVersion": 0,
  "playbackLineIdentity": "macv10:line:0:...",
  "episodeIdentity": "macv10:episode:0:..."
}
```

- `positionMs`、`durationMs` 始终表示原始 source 时间轴；`timelineType` 当前固定为 `source`，保留字段用于迁移校验和未来扩展。
- `filterVersion=0` 表示未过滤；`timelineVersion` 表示时间轴映射格式/算法版本；`manifestFingerprint` 可空。
- `playbackLineIdentity`、`episodeIdentity` 用于地址刷新后准确恢复 selection；显示用 episode id/name 继续保留，但不能替代稳定身份。
- 现有无 `schemaVersion` 的记录视为隐式 v1：按未过滤 source 时间轴解释，`filterVersion/timelineVersion` 默认为 0，fingerprint 和稳定 identity 为空。
- v1 历史记录先按当前兼容逻辑在默认线路内使用 episode name/id 匹配；下一次成功保存时写为 v2。
- SharedPreferences key 可继续使用 `watch_history_v1`，不复制整份历史；未知的未来记录版本应跳过或进入显式迁移，不能静默按 v1 解析。
- 历史列表逐条解析和迁移；单条未知/损坏记录不能导致整个观看历史被清空。
- HistoryRepository 继续按 `video.globalId` 保留每部影片最后一次观看；稳定线路/剧集 identity 用于准确恢复，不改变这一产品语义。

### 7.3 加密流保护

AES-128 的隐式 IV 可能依赖 `EXT-X-MEDIA-SEQUENCE`，删除片段后直接重排会导致解密错误。MVP 对 AES-128、SAMPLE-AES 和 DRM playlist 全部回退直连，不执行片段缓存或广告过滤。

---

## 8. 「我的」页缓存管理

### 8.1 入口

在 `lib/features/profile_page.dart` 的 Card 内、“来源管理”下方新增“缓存管理”：

- subtitle 展示 `已用 X / 配额 Y · N 个缓存剧集`，避免把存储条目误称为 N 部影片。
- 点击进入 `CacheManagementPage`。

### 8.2 页面

`lib/features/cache_management_page.dart`：

- 顶部汇总卡：完整资源占用、临时文件占用、配额、条目数和进度条。
- 配额区域标记为“自动”，MVP 不提供手动档位或“不限”入口。
- 操作：刷新索引、清理全部；清理全部需二次确认。
- 默认按影片分组展示，组内显示剧集/revision、大小、完成度、可离线状态和最近访问时间。
- 单项删除粒度为剧集 revision。
- 删除过程中禁用重复操作并展示结果；部分失败不能显示为全部成功。
- 空态复用 `AppEmptyView`。

### 8.3 状态与文件职责

- `cache_index.dart`：`CacheEntry`、`CacheStats`、schema、原子读写和重建。
- `cache_manager.dart`：配额、容量预留、淘汰、引用计数、增删查。
- `cache_repository.dart`：对 UI 暴露只读统计和管理命令，不承担代理/下载逻辑。
- `cache_controller.dart`：Riverpod `AsyncNotifier<CacheStats>`，订阅 manager 事件并节流刷新。
- `CacheEntry` 使用第 5.3 节 index v1 摘要字段，必须包含稳定 line/episode identity、content/revision hash、展示信息、完整/临时字节数、完成度、lastAccess、offlinePlayable、状态和脱敏错误摘要。

---

## 9. 平台、安全与隐私

### 9.1 本地 HTTP 播放

- Android 真机验证 Media3 对 loopback cleartext 的行为；如需 network security config，只对白名单 loopback 放行，不能全局放开任意 HTTP。
- iOS 真机验证 AVPlayer 对 loopback 和 ATS/local networking 的行为；只添加最小必要配置。
- 代理端口随机分配，应用退出/服务关闭后释放；会话关闭后路由立即失效。

### 9.2 存储与备份

- 使用 `path_provider` 提供的系统 Cache 目录，允许操作系统在空间紧张时自动回收。
- “完整缓存可离线播放”只描述缓存当前仍存在时的能力，不承诺永久保存或下次必定命中。
- 索引必须接受整个目录或部分资源被系统随时清理；启动和访问时发现缺失文件后自动修正完成度、占用统计和可离线状态。
- 文件权限保持应用私有；清除应用数据后缓存不可恢复。

### 9.3 隐私与日志

- 不记录完整签名 URL、Authorization、Cookie、代理 sessionToken。
- 错误和指标使用来源 ID、脱敏主机名、状态码、资源哈希。
- `state.json` 不保存临时密钥或完整敏感请求头。
- DRM/SAMPLE-AES/许可证型内容不尝试离线缓存，直接回退系统播放器。

---

## 10. 模块落地与实施阶段

### 10.1 文件清单

| 模块 | 文件 | 说明 |
|---|---|---|
| 播放源模型 | `lib/domain/playback_source.dart` | URL、格式、可选请求头及安全白名单契约 |
| 播放选择模型 | `lib/domain/playback_selection.dart` | 稳定线路/剧集 identity 与当前 Episode |
| 内容身份 | `lib/data/cache/content_key.dart` | `ContentKeyBuilder.v1` 规范编码与 hash |
| 播放会话 | `lib/data/cache/playback_session.dart` | generation、状态机、资源释放、回退 |
| HLS 解析器 | `lib/data/cache/hls_parser.dart` | 类型探测、master/media 解析、能力检查、URI 改写 |
| 缓存模型/索引 | `lib/data/cache/cache_index.dart` | schema、state/index 原子读写、重建 |
| 缓存管理 | `lib/data/cache/cache_manager.dart` | 容量预留、LRU、引用、删除 |
| 预下载器 | `lib/data/cache/download_manager.dart` | 优先队列、single-flight、重试、续传 |
| 本地代理 | `lib/data/cache/local_proxy.dart` | loopback server、会话路由、Range、回源 tee |
| 广告过滤 | `lib/data/cache/ad_filter.dart` | 静态规则、派生 manifest、时间轴映射 |
| UI repository | `lib/data/cache/cache_repository.dart` | 缓存统计和管理命令 |
| UI controller | `lib/data/cache/cache_controller.dart` | Riverpod 状态与节流刷新 |
| 缓存管理页 | `lib/features/cache_management_page.dart` | 汇总、分组列表、清理 |
| 播放页改造 | `lib/features/player_page.dart` | 接入 PlaybackSession、generation 和回退 |
| 我的入口 | `lib/features/profile_page.dart` | 入口和实时统计 |

阶段 1 的缓存核心通过构造函数注入 `Directory root` 和 `DiskSpaceProvider`，不得 import Flutter、Riverpod、`path_provider` 或其他平台插件；测试使用临时目录和 fake disk provider。`ContentKeyBuilder.v1` 使用 SHA-256，可引入纯 Dart `crypto` 依赖。阶段 3 才在应用组合层使用 `path_provider` 获取系统 Cache 目录，并实现 `PlatformDiskSpaceProvider` 查询总容量、可用空间和平台缓存上限。`path_provider` 本身不提供这些容量数据，需使用原生 API、平台通道或经评估的独立插件。

本地服务使用 `dart:io` `HttpServer`；是否补充专门 HTTP/HLS 依赖应在原型验证后决定，不能假定现有 `http` 客户端支持 HTTP/2。

### 10.2 实施阶段

#### 阶段 0：技术验证与决策冻结

- 复核第 11 节已冻结决策，不在实现过程中隐式扩展范围。
- 用 Android/iOS 真机验证 loopback HLS、Range、应用生命周期和清理行为。
- 收集匿名化的真实 playlist fixture，建立 HLS 能力矩阵。

#### 阶段 1：数据与并发基础

- `content_key.dart`、`cache_index.dart`、`cache_manager.dart`、`single_flight.dart`。
- 冻结 `ContentKeyBuilder.v1`、稳定 line/episode identity 字段以及第 5.3 节 state/index schema v1；尚未接通播放器时也不能用顺序 id 占位。
- 核心层只接收外部注入的根目录和磁盘容量提供器，不依赖 `path_provider`；保证无需插件初始化即可执行文件系统单测。
- 完成 schema 版本拒绝、字段不变量、路径安全、真正原子写、容量预留、single-flight、崩溃恢复和文件系统测试。
- 此阶段先提供测试/调试接口，不承诺面向用户的“真实缓存管理闭环”。

#### 阶段 2：最小代理播放闭环

- `playback_selection.dart`、`hls_parser.dart`、`local_proxy.dart`、`playback_session.dart`。
- 接通 adapter → detail → player → retry/history 的 `PlaybackSelection` 数据链路；MacCMS 不再分别解析 `Video.episodes` 与 `playbackLines`。
- 在 `player_page.dart` 增加 playback generation 和候选 session/controller 作废检查，覆盖 setup、retry、切集和 dispose。
- 落地第 5.5 节 Range 正确性基线；原型只评估是否增加重叠 Range 合并，不得放宽 validator/Content-Range 校验。
- 引入 `WatchRecord` v2 及 v1 向后兼容读取；过滤尚未启用时写入 `timelineType=source`、`filterVersion=0`。
- 仅对能力矩阵内的 VOD HLS 启用代理，其余保持现有直连。
- 完成快速切集、重试、退出和真机首帧测试。

#### 阶段 3：边播边下与缓存管理 UI

- 接入回源 tee、前台预下载、配额淘汰和断点恢复。
- 在应用组合层接入 `path_provider` 和 `PlatformDiskSpaceProvider`，核心缓存模块仍保持平台无关。
- 增加缓存管理页、分组列表、单项/全量清理。
- 完整命中时验证无网络离线播放。

#### 阶段 4：广告过滤

- 先以 feature flag 接入明牌和静态规则。
- 建立误判 fixture、时间轴恢复和规则版本回滚测试。
- PTS 校验作为独立后续项，不阻塞缓存 MVP。

### 10.3 验证要求

- `dart format lib test`、`flutter analyze`、`flutter test` 全部通过。
- 身份链路：多线路同名/同顺序 episode 不碰撞、过滤掉无效线路/剧集后 identity 不漂移、默认线路 selection 可重建、重试不跨线路。
- schema：state/index v1 字段 round-trip、未知版本拒绝、负数/缺字段/未知枚举隔离、原始签名 URL/headers 不落盘、resourceId/ext 路径穿越被拒绝。
- WatchRecord：隐式 v1 默认值、v1→v2 下一次保存迁移、source 时间轴 round-trip、稳定 selection identity 恢复。
- HLS fixture：master/media、相对 URL、重定向、未知标签、Map/Key/Range、直播回退、格式不支持回退。
- 播放源请求上下文：空 headers 兼容现有来源、白名单转发、自定义 Referer/User-Agent、敏感 headers 不落盘/不入日志。
- PlaybackSource：headers 构造后不可变，不使用忽略 headers 的对象相等性作为请求去重键，会话 headers 与下游逐请求 headers 使用不同白名单。
- Range：相同区间 single-flight、不同/重叠区间不误合并、完整 200 服务子 Range、validator 变化丢弃 part、Range 请求返回 200 不追加旧 part。
- 并发：代理和下载器同时请求同一资源、5 路容量预留、写入时删除、清理时读取。
- 恢复：损坏 index/state、遗留 `.part`、文件被系统/用户外部删除、写索引时进程终止。
- 页面：快速连续切集、初始化期间退出、连续重试、地址刷新后 revision 变化。
- 网络：弱网、断网、超时、401/403、404、5xx、Range 中断续传。
- Android/iOS 真机：loopback cleartext/ATS、seek、后台切换、锁屏、完整缓存离线播放。
- 保留官方 demo 视频兜底，缓存或过滤模块失败不能破坏其播放。
- 广告过滤坚持“宁漏勿错”，必须支持一键关闭和回退原始 manifest。

### 10.4 可观测性

只记录脱敏指标：

- 代理准备时间、首帧时间、直连回退原因。
- 内存/磁盘命中率、远端实际下载字节、重复请求合并次数。
- 下载失败/重试、容量不足、淘汰和清理结果。
- manifest 能力拒绝原因、广告过滤候选数和最终删除数。

不得在日志中记录完整媒体 URL、查询 token、Cookie 或本地 sessionToken。

---

## 11. 审核结论

本方案涉及的产品范围和缓存策略已经审核完成，当前无待决策项。

- 动态配额采用可管理空间的 15%，目标下限 1GB、目标上限 8GB，并受系统安全余量和平台缓存上限进一步约束。
- MVP 只提供“自动配额”；先以真实设备指标验证 15%/1GB/8GB 策略，后续再评审手动档位，始终不允许绕过系统安全余量。
- Wi-Fi 下允许前台主动预下载；蜂窝网络只服务当前播放实际请求，不主动预取。
- 磁盘、手动删除和淘汰单位为剧集 revision，UI 按影片分组；先淘汰最久未访问的部分缓存，再淘汰最久未访问的完整缓存。
- 活动播放项禁止立即删除，自动淘汰也必须跳过。
- MVP HLS 范围为实用型方案 B；加密、DRM、多音轨和能力矩阵外内容回退直连。
- `WatchRecord` 保存原始剧情时间轴和映射版本，并对历史记录向后兼容迁移。
- MVP 仅做前台预下载，不实现系统后台下载。
- 使用系统 Cache 目录，允许操作系统自动回收。
- 纳入轻量可选 `PlaybackSource` 契约，当前适配器返回空 headers，敏感 headers 只驻留会话内存。
- 播放链路使用带稳定 line/episode identity 的 `PlaybackSelection`；contentKey 只能由 `ContentKeyBuilder.v1` 生成。
- cache state/index 使用字段级 schema v1 并严格校验版本；WatchRecord 使用 schema v2，旧记录兼容读取并在下次保存迁移。
- 阶段 1 采用目录和磁盘能力注入，不依赖 `path_provider`；阶段 3 才接入系统目录和平台容量实现。
- Range MVP 只合并完全相同的规范源站区间；重叠区间优化留给阶段 2 原型，不能牺牲正确性。
- `player_page.dart` 在阶段 2 增加覆盖 setup/retry/切集/dispose 的 playback generation。

任何对上述范围的扩大都应基于真机兼容性、首帧时间、命中率、远端字节数、淘汰频率和磁盘压力指标重新评审，不能在实现过程中隐式扩展。
