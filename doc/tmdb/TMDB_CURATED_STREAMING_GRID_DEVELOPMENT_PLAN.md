# TMDB 榜单流式卡片开发计划

## 1. 结论与影响范围确认

本次改造仅作用于 TMDB 策展榜单，即首页的“最热”“最新”“高分” Feed 及其“全部/电影/电视剧/动漫/综艺”等 Scope。

默认 VOD 来源页面不应受到影响。当前首页已经存在两条独立的数据和渲染链路：

| 页面 | Controller | 数据来源 | 渲染组件 |
| --- | --- | --- | --- |
| 默认 Feed、VOD 分类 | `PagedVideoController` | 当前 VOD 源的分类/分页接口 | `VideoGrid` + `VideoCard` |
| TMDB 策展榜单 | `CuratedFeedController` | TMDB Catalog + 当前 VOD 源搜索 | 当前暂用 `VideoGrid`，本计划改为 `CuratedVideoGrid` + `CuratedVideoCard` |

`HomePage._body()` 已通过 `VideoFeed.updated` 将两条链路分开：默认 Feed 使用 `_body()` 中的 `PagedVideoController` 分支，其他 Feed 使用 `_curatedBody()`。只要本次实施遵守以下边界，默认 VOD 分类的请求、缓存、分页、卡片点击和展示都不会改变：

1. 不修改 `PagedVideoController` 的分页和一级缓存逻辑。
2. 不修改 `VideoGrid` 的 `List<Video>` 数据契约。
3. 不修改 `VideoCard` 的普通播放卡片语义。
4. 新增策展专用的 `CuratedVideoGrid` 和 `CuratedVideoCard`。
5. 共享搜索池只由 `CuratedFeedController` 使用，默认分类请求不进入该池。
6. `HomePage` 只在 `_curatedBody()` 中切换到新的策展组件。

仍有少量共享交叉点需要回归验证，但不代表默认页面行为要发生变化：

- Feed 顶部导航和滚动控制器由 `HomePage` 共享。
- 切换 VOD 来源时，两个 Controller 都会重建。
- 内容过滤设置变化时，两个页面都需要重新加载符合新策略的数据。
- `VideoRepository` 和 VOD Adapter 是共同底层依赖，但新增搜索池及 Slot 状态不得改变普通分页接口语义。

## 2. 产品目标

榜单页面采用 Catalog-first 模型：TMDB Catalog 决定卡片是否存在、排名和分页；VOD 搜索只决定当前来源是否可播放。

目标行为：

1. TMDB Catalog 返回后立即按排名显示榜单卡片。
2. 共享池缓存命中的卡片立即显示为可播放，不等待其他搜索。
3. 未命中的卡片保留原排名位置，并提供换源搜索入口。
4. 任一 VOD 请求完成后立即更新对应卡片，不等待整批请求。
5. 网络返回顺序不影响榜单顺序和最终去重结果。
6. 分页按 Catalog 条目数量推进，不再为了凑够指定数量的可播放影片持续搜索。

这里的“流式”指每个影片搜索请求完整返回后立即更新 UI。MacCMS、AGE 等单次 HTTP JSON 响应仍需完成下载和解析，本期不实施响应体逐字节解析。

## 3. 卡片状态模型

新增 `CuratedSearchSlot` 作为候选级持久状态，替代当前仅在批次内存在的 `_Evidence`：

```dart
enum CuratedSlotStatus {
  queued,
  searching,
  available,
  unavailable,
  ambiguous,
  duplicate,
  failed,
}

class CuratedSearchSlot {
  final String slotId;
  final int catalogIndex;
  final TmdbCatalogItem catalogItem;

  CuratedSlotStatus status;
  Video? matchedVideo;
  int queryIndex;
  String query;
  int rawResultCount;
  List<String> candidateTitles;
  Object? lastError;
  int attempt;
  int generation;
}
```

状态转换：

```text
queued
  -> searching
       -> available
       -> unavailable
       -> ambiguous
       -> duplicate
       -> failed
```

约束：

- `slotId` 使用 `mediaType + tmdbId`，不能使用随 VOD 来源变化的 `globalId`。
- `catalogIndex` 是唯一排序依据，异步完成顺序不能改变卡片位置。
- 未匹配不是错误；只有网络、解析、超时等异常进入 `failed`。
- 未匹配卡片不消失，也不再重复收集成底部影片列表。
- Slot 必须记录 `generation`，阻止刷新、切 Feed 或切来源后的旧回调更新当前页面。

## 4. 策展卡片与加载表现

TMDB Catalog 已经提供海报、标题、评分、排名和媒体类型，因此 VOD 搜索期间不使用遮住整张卡片的纯骨架。`CuratedVideoCard` 应立即展示 Catalog 信息，只在状态区域使用轻量 shimmer 或进度角标。

| 状态 | 卡片表现 | 点击行为 |
| --- | --- | --- |
| `queued` | 等待搜索 | 提升该 Slot 的调度优先级 |
| `searching` | 正在当前源搜索 | 可主动发起换源搜索 |
| `available` | 显示可播放状态 | 进入正常详情/播放 |
| `unavailable` | 当前源暂无 | 在其他来源搜索 |
| `ambiguous` | 多个候选 | 打开候选选择 |
| `duplicate` | 与更高排名条目命中同一资源 | 在其他来源搜索 |
| `failed` | 搜索失败 | 重试当前 Slot 或换源搜索 |

全页骨架只用于 TMDB Catalog 尚未返回的阶段。Catalog 返回后，即使所有 VOD Slot 都是 `queued`，也应立即显示 `CuratedVideoGrid`。

底部区域改为统计和操作，不再重复展示未匹配片名：

```text
当前 20 部：可播放 12 · 当前源暂无 5 · 多候选 1 · 请求失败 2
```

可提供“重试失败项”“继续加载榜单”和“只看当前源可播放”，但默认仍展示完整榜单。

## 5. 共享搜索池改造

### 5.1 同步读取 ready 缓存

为 `CuratedVodSearchPool` 增加：

```dart
PooledSearchResult? peekReady({
  required String sourceFingerprint,
  required String query,
  bool touch = true,
});
```

规则：

- 只返回未过期的 `ready` 项。
- 命中时更新 LRU 时间，但不创建 lease、不增加订阅数。
- 在途请求继续通过 `acquire()` 加入 SingleFlight。
- 失败、取消和过期结果不能返回。
- 手动刷新模式绕过 `peekReady()`，但允许加入相同的刷新在途请求。
- Slot 开始网络查询前，按 `searchQueries` 优先级检查所有 ready 缓存；任何缓存能够严格匹配即可立即提交。

### 5.2 缓存容量和清理接口

维持当前默认策略：

- 非空结果 TTL：5 分钟。
- 空结果 TTL：90 秒。
- ready 查询最多 64 项。
- 异常和取消结果不缓存。
- 超限按 LRU 淘汰。

补充来源级清理能力：

```dart
void evictSource(String sourceFingerprint, {bool abortInflight = true});
void clearReady();
void clearAll();
```

清理时机：

- 来源被删除或配置改变：清理旧 fingerprint。
- 内容过滤策略改变：保守地清理 Session 和 ready 搜索结果，避免复用旧过滤上下文。
- Home 销毁：关闭池并释放所有请求。
- 内存压力：依次清理非活动未完成 Session、旧来源 ready 缓存、非活动完整 Session。

## 6. 单候选流式提交

当前 `CuratedFeedController` 会等待整批 primary 和 fallback 完成后统一 `_commit()`。本计划改为每个 Slot 独立解析：

```text
检查所有 ready 缓存
  -> 有严格匹配：立即提交 available
  -> 无匹配：进入 primary 搜索
       -> primary 匹配：立即提交 available
       -> primary 未匹配：检查/搜索 fallback
       -> fallback 结束：提交最终状态
```

每次提交前必须验证：

```dart
!session.cancelled &&
slot.generation == session.generation &&
session.sourceFingerprint == expectedSourceFingerprint
```

旧 Session 可以继续接收属于自己的结果并用于切回恢复，但不能通知当前页面。最后一个 lease 被释放后，支持物理取消的 Adapter 应中断 HTTP；不支持取消的 Adapter 继续采用结果丢弃保护。

通知策略：首个状态变化立即通知，后续密集完成事件按一帧合并，避免多个缓存命中造成连续网格重建。

## 7. 排名优先去重

所有 Catalog 卡片始终保留，但同一个 VOD `globalId` 不能同时成为多个卡片的可播放资源。

Session 维护：

```dart
Map<String, String> globalIdOwners; // globalId -> slotId
```

规则：

1. 相同 `globalId` 由 `catalogIndex` 更小的 Slot 拥有。
2. 低排名 Slot 命中已被占用的资源时，继续尝试剩余 fallback。
3. 没有其他候选时标记为 `duplicate`，但卡片留在原排名。
4. 若低排名先返回、高排名后返回，所有权转移给高排名 Slot；低排名重新评估备用候选。
5. 每次匹配后集中执行确定性的 reconciliation，最终结果不能依赖网络完成顺序。
6. 所有权只在当前 `sourceFingerprint + Feed Session` 内生效。

## 8. 分页和调度

分页由 Catalog 条目数驱动：

```dart
catalogPageSize = 20;
maxConcurrentSearches = 3;
visibleSearchPrefetch = 6;
```

调度优先级：

1. 用户主动点击的 Slot。
2. 当前屏幕可见 Slot。
3. 即将进入屏幕的 4～6 个 Slot。
4. 当前 Catalog 页内的其他 Slot。

首批只展示并处理排名 1～20，不因其中命中不足而自动加载 21～40。下一页只能由明确的“继续加载榜单”操作，或经过用户真实下拉/向下滚动门槛触发。程序重建、Slot 状态变化和动画不得触发自动 `loadMore()`。

## 9. Feed、Scope 和 VOD 来源切换

### 9.1 Feed/Scope 会话

Session Key 使用：

```text
sourceFingerprint + feed + scope + catalogRevision
```

切换 Feed 或 Scope：

- 有完整视图缓存：立即恢复所有 Slot 状态。
- 有未完成会话：恢复已完成 Slot，继续剩余 queued Slot。
- 没有会话：立即创建 Catalog Slot，并用 `peekReady()` 同步填充。
- 旧会话停止调度新请求。
- 被新会话复用的在途查询继续执行；无人订阅的查询取消。
- 未完成会话保留 2 分钟；完整视图保留 10 分钟、最多 8 个。

### 9.2 切换 VOD 来源

共享池应上移到 Home 生命周期，使不同来源的 ready 缓存可以短期共存，但缓存 Key 必须包含完整 `sourceFingerprint`，绝不跨来源命中。

切换来源时：

1. 当前 Session detach 并释放旧来源 lease。
2. 无其他订阅者的旧来源 HTTP 请求立即取消。
3. TMDB 卡片和排名可以继续显示，避免页面闪空。
4. 所有卡片的来源状态切换到新 fingerprint；新源 ready 缓存命中立即显示，其余进入 queued/searching。
5. 旧来源 ready 缓存短期保留，切回时可以立即恢复。
6. 最多保留最近 2～3 个来源，并继续受全局 64 项 LRU 限制。
7. 来源 base URL、Adapter 或插件配置变化时 fingerprint 改变，必须取消并清理旧 fingerprint。

卡片状态区域需要显示当前来源名称，避免用户将旧来源的可播放状态误认为属于新来源。

## 10. 默认 VOD 分类的隔离措施

本次实现必须建立以下代码级防线：

### 10.1 组件隔离

- 默认分支继续调用 `VideoGrid(videos: controller.items)`。
- 策展分支改为 `CuratedVideoGrid(slots: curatedController.slots)`。
- `CuratedVideoCard` 可以复用主题 Token、海报加载工具和小型基础组件，但不能通过修改 `VideoCard` 强行兼容无 `Video` 状态。
- 如果确实需要抽取共享 UI，只抽取无业务状态的海报框、徽标等私有基础组件，并为默认卡片补充回归测试。

### 10.2 Controller 隔离

- 不修改 `PagedVideoController.loadInitial/loadMore/refresh`。
- 默认分类的 2 分钟首页缓存不迁移到策展搜索池。
- 默认分类继续按 VOD 页码及 `result.hasMore` 分页。
- 策展页面才按 Catalog cursor 分页。

### 10.3 交互隔离

- 默认卡片继续调用 `_open(Video)`。
- 只有 `available` 策展卡片能够调用 `_open(matchedVideo)`。
- 策展 `unavailable/duplicate/failed/ambiguous` 状态走独立处理函数，不能构造虚假 `Video`。
- 默认分类的滚动触底阈值可以保持不变；策展网格使用独立的分页触发规则。

## 11. 边界情况

- Catalog 请求失败：保留旧完整视图；没有旧视图时显示全页错误和重试。
- Catalog 条目没有搜索关键词：直接标记 `unavailable`，不发请求。
- 海报缺失：优先使用匹配后的 VOD 海报，否则显示默认影片图标。
- ready 缓存刚好过期：不能先闪现旧状态再回退 searching。
- primary 超时而 fallback 已缓存：允许使用 fallback。
- primary/fallback 同时结束：通过 Slot generation 和单一提交入口保证最终状态唯一。
- 连续 3 次来源级错误：暂停当前批次，其余 Slot 保持 queued，并显示来源暂不可用。
- 手动重试单 Slot：只增加该 Slot 的 attempt/generation，不刷新整个榜单。
- 手动刷新 Feed：新 revision 重建 Slot，绕过 ready 缓存一次；刷新失败保留旧页面。
- 快速切换 Feed/Scope/来源：任何旧回调都必须通过 Session、generation 和 fingerprint 三重校验。
- 相同影片跨 Feed 出现：复用原始搜索结果，但按各自 Catalog 条目重新匹配和生成排名/评分。
- 页面销毁：取消通知合并 Timer、释放 lease、关闭 Home 持有的搜索池。
- 当前页面全部未匹配：仍展示完整榜单，不自动扫描后续 Catalog 页。

## 12. 实施阶段

### 阶段 1：共享池能力

- 增加 `peekReady()`。
- 增加来源级清理接口。
- 完成 TTL、LRU、来源隔离和 SingleFlight 测试。

### 阶段 2：Slot 和 Controller

- 新增 `CuratedSearchSlot`。
- `_Evidence` 信息迁移到 Slot。
- Session 改为保存固定排名 Slot。
- 主查询和 fallback 改为单候选完成即提交。
- 增加 generation/fingerprint 防护和通知合并。

### 阶段 3：确定性去重

- 增加 `globalIdOwners`。
- 实现排名优先 reconciliation。
- 覆盖乱序返回、所有权转移和备用候选测试。

### 阶段 4：策展专用 UI

- 新增 `CuratedVideoGrid` 和 `CuratedVideoCard`。
- Catalog 返回后立即显示固定卡片。
- 实现所有状态的视觉和点击行为。
- 底部未匹配列表改为状态统计。

### 阶段 5：分页与来源生命周期

- 分页改为 Catalog 条目数量驱动。
- 增加可见区域搜索优先级。
- 搜索池所有权上移至 Home 生命周期。
- 实现来源切换、切回缓存和旧来源淘汰。

### 阶段 6：回归与文档

- 执行 `dart format lib test`。
- 执行 `flutter analyze`。
- 执行 `flutter test`。
- 更新 `doc/codebase/CODEBASE_MAP.md` 中新增文件说明。

## 13. 测试计划

### 共享池

- `peekReady()` 同步命中且不调用 loader。
- peek 更新 LRU；过期结果不能命中。
- refresh 绕过 ready 缓存。
- 不同来源 fingerprint 严格隔离。
- `evictSource()` 只清理目标来源。
- 最后一个订阅者离开才取消在途请求。

### Curated Controller

- Catalog 返回后立即产生固定 Slot。
- 缓存命中无需等待慢请求。
- 任一请求完成后立即更新对应 Slot。
- 乱序完成不改变排名。
- 未匹配、失败和重复卡片保留原位。
- fallback 缓存/网络路径正确。
- `globalId` 始终由更高排名 Slot 拥有。
- 切 Feed/Scope 后旧回调不覆盖当前页面。
- 切回未完成 Feed 能恢复并继续。
- 切来源不发生跨源缓存污染。
- 连续错误能暂停调度且允许恢复。

### 策展 Widget

- Catalog 完成即显示榜单卡片。
- 所有 Slot 状态渲染正确。
- 状态变化不改变卡片顺序。
- 不可用卡片触发跨源搜索，不进入空播放页。
- 状态变化不会误触发下一页。
- 切来源后旧来源标签和状态不残留。

### 默认 VOD 分类回归

- 默认 Feed 仍由 `PagedVideoController` 请求。
- 一级/二级 VOD 分类切换结果不变。
- 默认首页 2 分钟缓存仍生效。
- 普通 `VideoGrid/VideoCard` 布局、点击和分页不变。
- 默认 Feed 的滚动触底仍按 VOD `hasMore` 加载。
- 从策展 Feed 切回默认 Feed 后恢复正确分类和滚动位置。
- 切换 VOD 来源后默认分类只显示新来源数据。

## 14. 风险评估

| 风险 | 等级 | 控制措施 |
| --- | --- | --- |
| 策展状态机复杂化 | 高 | Slot 单一状态源、集中状态转换、generation 校验 |
| 异步乱序产生错误去重 | 高 | Catalog 排名固定、集中 reconciliation |
| 切来源残留旧可播放状态 | 高 | fingerprint 隔离、旧 lease 释放、回调三重校验 |
| 修改共享卡片导致默认分类回归 | 高 | 新建策展专用 Grid/Card，不修改默认数据契约 |
| Slot 更新频繁导致掉帧 | 中 | 首项立即通知，后续按帧合并 |
| 不可播放卡片比例过高 | 中 | 清晰状态、单卡换源、可播放筛选 |
| 缓存随来源数量增长 | 中 | 全局 LRU、来源数量限制、内存压力清理 |
| 程序重建触发连续分页 | 中 | 策展分页改为显式或真实用户滚动触发 |
| 底层 Repository 改动影响默认分页 | 中 | 不改变现有接口语义，增加默认分类回归测试 |

## 15. 验收标准

- 默认 VOD Feed 和分类页面的请求、缓存、分页、UI 和点击行为保持不变。
- TMDB Catalog 返回后无需等待 VOD 搜索即可看到完整排名卡片。
- 缓存命中立即更新；单个网络请求完成后立即更新对应卡片。
- 未匹配影片保留原排名并支持换源搜索。
- 网络完成顺序不影响榜单排序和最终资源归属。
- 切 Feed、Scope、来源和刷新后不存在旧结果覆盖。
- 策展页面不会因低命中率自动搜索完整个榜单。
- 搜索池、Session 和来源缓存均有明确 TTL、容量及清理路径。

