# 播放器进度条「已下载进度」显示 —— 需求与实施计划

> 目标：在播放页进度条上，用灰白色展示当前剧集已缓存/已下载完成的进度，让用户直观看到"后面还有多少不用耗流量/可离线看"。
>
> 状态：**待评审**。确认后按第 6 节实施。

---

## 1. 背景与现状

当前进度条（`lib/shared/playback_scrubber.dart`）为 `Stack + FractionallySizedBox` 三层结构：

- 轨道底色 `Colors.white24`（`playback_scrubber.dart:194`）
- 缓冲层 `Colors.white38`，取自 `VideoPlayerValue.buffered.last.end` 的**单点**语义（`player_page.dart:1165-1167`）
- 已播放层 `AppColors.accent`（`#F2B84B`）

播放链路已全面接入缓存：播放器经本地代理播放（`PlaybackSession`），边播边下与显式下载**共用同一套缓存存储**（`CacheManager` / `state.json` 的 `resources` 表，每资源有 `partial/complete` 状态）。

**关键差距：**

- `CacheManager` 没有变更通知机制，UI 无法得知"又有片段下载完成了"。
- 不存在"已缓存片段 → 播放时间轴区间"的换算函数（原料齐全：session playlist 的分片时长 + resources 表）。
- 现有 buffered 层在代理播放模式下语义弱化（数据来自 loopback，缓冲几乎总是够用），对用户价值低。

## 2. 需求描述

### 2.1 功能需求

- F1：进度条上增加"已下载完成"层，颜色灰白色，位于轨道底色之上、已播放层之下。
- F2：已下载进度 = 当前剧集在缓存中状态为 `complete` 的片段，换算到**当前播放时间轴**（即过滤后时间轴，与播放器所见一致）上的连续进度。
- F3：边播边下、前台预取、显式下载三条路径写入的缓存都计入（它们本就共用存储，天然统一）。
- F4：完整缓存/已下载完成的剧集（含离线播放模式）显示为整集 100%。
- F5：直连回退（不支持缓存的内容、加密流、代理失败）时不显示已下载层，不报错。
- F6：下载进行中进度条随下载推进实时更新；切集、重试后按新剧集重新计算。
- F7：替换现有 buffered 层（不再单独显示播放器缓冲）。理由：代理模式下 buffered 无区分度，已下载层完全覆盖其"能流畅看到哪"的信息价值，避免两条灰白色带互相干扰。

### 2.2 非功能需求

- N1：进度数据更新有节流，不得因分片逐个提交导致进度条高频重绘。
- N2：进度计算失败（索引损坏、会话关闭等）时静默降级为"无已下载层"，不影响播放。
- N3：不改动缓存 schema；已下载进度为**派生数据**，不落盘。

## 3. 方案设计

### 3.1 视觉分层

```text
┌──────────────────────────────────────────────┐
│ 轨道底色  Colors.white24                      │
│ ▓▓▓▓▓▓▓▓▓▓▓ 已下载  Colors.white38（灰白色）   │
│ ▓▓▓▓ 已播放  AppColors.accent                 │
│                    ● thumb                    │
└──────────────────────────────────────────────┘
```

- 已下载层沿用现有缓冲层的绘制模式（`FractionallySizedBox` + `white38`），只是把数据源从 `buffered` 换成"已缓存进度"，视觉上与原缓冲层一致、用户无学习成本。
- scrubber 的 `buffered` prop 语义改为"已下载至"，由调用方传入新数据；widget 内部绘制逻辑不变。

### 3.2 进度语义：单点「连续已下载至」

MVP 采用单点语义：从 0 开始累计**连续** complete 片段的时长，遇到第一个未完成的片段停止，得到"已下载至 T"。

- 与现有 scrubber 单 `Duration` prop 零冲突，改动最小。
- 顺序播放 + 附近优先预取的场景下，缓存天然是从播放位置向后的连续区段，该语义足够准确。
- seek 后，若新位置之后的预取窗口已下载但播放点之前有缺口，单点会从 0 重新累计并在缺口处停止——表现保守但不误导（显示的是"从头可连续看/可离线看到哪"）。
- 多区间精确显示（CustomPainter + 区间列表）作为后续可选项，本期不做（见第 7 节）。

### 3.3 数据流

```text
CacheManager（新增：资源提交变更通知，按 entryKey）
        │
        ▼
PlaybackSession 暴露 cachedUpTo 流
（playlist.segments 时长累计 × resourceCatalog 的 complete 状态，内部节流 ~500ms）
        │
        ▼
player_page：AnimatedBuilder/StreamBuilder 监听
        │
        ▼
PlaybackScrubber.buffered（复用现有 prop，灰白色层）
```

- **变更通知**：`CacheManager` 增加轻量 broadcast 流（事件仅携带 `contentKeyHash|revisionKeyHash`），在资源提交 complete 时发出。这与 `CACHE_MANAGEMENT_PLAN.md` 8.3 节"cache_controller 订阅 manager 事件并节流刷新"的既定设计一致，顺势补齐。
- **换算函数**：新增纯函数，输入 `List<HlsSegment>`（含 EXTINF 时长，顺序=播放轴）+ 资源 complete 集合，输出连续 complete 前缀时长。数据均在内存（session playlist + `CacheManager.resourceCatalog`），纯新增、可单测。
- **离线/完整命中**：`PlaybackMode.cachePlayback` 或 entry `offlinePlayable == true` 时直接返回完整 duration，不逐片段计算。
- **显式下载**：下载写入的是同一套 resources，自动被覆盖，无需对接 `downloadTasksProvider`。
- **直连回退**：session 未建立或无缓存 entry 时返回 null，进度条不渲染该层。

### 3.4 边界情况

| 场景 | 行为 |
|---|---|
| 广告过滤生效 | 按过滤后分片清单累计，与播放器时间轴天然一致，无需 TimelineMapping 换算 |
| 切集/重试/地址刷新 | 监听新 session 的流；旧 session 关闭后其流终止，不会串数据 |
| 播放中退出再进入 | 新 session 重新计算，已缓存部分立即显示 |
| 缓存被手动删除/淘汰 | 收到变更通知后重新计算，灰白层回缩 |
| 索引损坏/查询异常 | 降级为无已下载层（N2） |

## 4. 影响范围

| 文件 | 改动 |
|---|---|
| `lib/data/cache/cache_manager.dart` | 新增资源提交变更通知流（只增不改现有逻辑） |
| `lib/data/cache/playback_session.dart` | 暴露当前 session 的 `cachedUpTo` 流（换算 + 节流） |
| `lib/features/player_page.dart` | 用 session 的已下载进度替换 `value.buffered` 作为 scrubber 输入 |
| `lib/shared/playback_scrubber.dart` | 注释/命名微调（buffered → cachedUpTo 语义），绘制逻辑不变 |
| `test/` 新增 | 换算纯函数测试、通知节流测试、scrubber 分层 widget 测试 |

缓存 schema、代理、下载、过滤模块均不改动。

## 5. 验收标准

- `dart format lib test`、`flutter analyze`、`flutter test` 全部通过。
- 边播边下时灰白进度随预取持续推进（感知延迟 ≤ 1s）。
- 完整下载的剧集整集显示灰白；退出重进仍在。
- seek 到未缓存区域后，新位置预取完成不会错误地把灰白层延伸过缺口。
- 直连回退内容（如 demo 视频兜底、加密流）不显示灰白层，播放不受影响。
- 真机验证：播放中进入缓存管理删除当前集以外的缓存，播放页进度条不受影响。

## 6. 实施步骤

1. `CacheManager` 增加 per-entry 变更通知流 + 单测。
2. 新增"连续 complete 前缀时长"换算纯函数 + 单测（含过滤清单、缺口、全量 complete 用例）。
3. `PlaybackSession` 暴露节流后的 `cachedUpTo` 流；离线模式直接返回全量。
4. `player_page` 接入新数据源，替换 buffered 输入；直连回退传 null。
5. scrubber 语义与注释调整；widget 分层测试。
6. 全量验证（`flutter analyze` / `flutter test`）+ 真机回归。

## 7. 待确认事项

- **Q1 视觉**：灰白色暂定 `Colors.white38`（与原缓冲层相同）。是否需要与已播放层对比更强（如 `white54`）？
- **Q2 buffered 层去留**：本方案默认**替换**现有 buffered 层。若希望两者共存（buffered 更浅色紧贴播放头、已下载灰白色），进度条会有四条色带，复杂度上升，建议不共存。
- **Q3 单点 vs 多区间**：本期单点"连续已下载至"。是否接受，还是需要一步到位做多区间精确显示？
