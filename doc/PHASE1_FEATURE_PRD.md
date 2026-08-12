# 阶段一功能 PRD：收藏、播放列表与播放器进度拖动

## 1. 文档信息

- 产品：Jive 家庭视频 App
- 阶段：阶段一（本地能力与播放体验优化）
- 目标用户：本人及家庭成员
- 平台：Android、iOS
- 数据策略：暂不增加帐号登录和后端；收藏、播放列表和观看状态保存在本机

## 2. 背景与目标

当前 App 已支持视频浏览、搜索、详情、播放和最近观看。阶段一新增两个本地内容组织能力，并修复播放器进度条交互问题：

1. 用户可以收藏喜欢的视频，之后快速找到并播放。
2. 用户可以创建和维护播放列表，按自己的顺序集中播放视频。
3. 用户可以拖动播放器进度条；拖动过程中只预览目标位置，松手后才真正跳转，避免拖动过程频繁 seek 导致卡顿。

本阶段不实现登录、云同步、推荐、下载、投屏和 DRM。

## 3. 当前代码基础

- 视频实体：`lib/domain/video.dart` 的 `Video`
- 本地存储：`lib/data/history_repository.dart` + `SharedPreferences`
- 依赖注入：`videoRepositoryProvider`、`historyRepositoryProvider`
- 播放器：`lib/features/player_page.dart` + `video_player`
- 最近观看：`WatchRecord` 已保存视频、剧集和播放进度

新增功能应继续通过 Repository 隔离存储细节，页面不直接操作 `SharedPreferences`。

## 4. 功能范围

### 4.1 收藏功能

#### 用户故事

- 用户在视频卡片或详情页点击收藏按钮，可以收藏/取消收藏视频。
- 用户进入“我的收藏”页面，可以查看全部收藏。
- 收藏的视频仍可进入详情和播放。
- App 重启后收藏状态保持不变。

#### 入口与展示

- 详情页：在标题信息区域或播放按钮附近显示收藏按钮。
- 视频卡片：可选显示紧凑收藏图标；若影响网格布局，第一版只在详情页提供入口。
- 底部导航：新增“收藏”栏目，或在“最近观看”页面中增加收藏入口。产品实现时二选一；推荐独立栏目，便于家庭用户使用。

#### 行为规则

- 未收藏时显示空心图标，点击后立即变为实心图标。
- 已收藏时再次点击取消收藏，并显示轻量 SnackBar 反馈。
- 收藏以 `video.id` 去重；同一视频只能存在一条收藏记录。
- 收藏记录保存视频基础信息，不保存长期有效的播放 URL。
- 视频详情刷新后，应使用最新标题、封面、分类等信息更新收藏记录。
- 加载失败时不能清除已有收藏；存储失败时保留当前页面状态并提示用户。

#### 空状态

收藏列表为空时显示：

```text
还没有收藏
去首页或搜索页收藏喜欢的视频
```

### 4.2 播放列表

#### 用户故事

- 用户可以创建一个播放列表。
- 用户可以把视频加入一个或多个播放列表。
- 用户可以从播放列表移除视频。
- 用户可以查看播放列表中的视频并进入详情或播放。
- 用户可以删除播放列表。

#### 第一版范围

- 支持播放列表名称。
- 支持多个播放列表。
- 一个视频可加入多个播放列表。
- 同一播放列表中按加入顺序排列。
- 列表中的视频按 `video.id` 去重。
- 支持删除列表；删除列表前需要确认。
- 支持从列表中移除单个视频。

#### 第一版暂不实现

- 拖拽排序
- 自动连续播放
- 播放列表云同步
- 列表分享
- 列表协作
- 智能规则列表

#### 交互建议

- 详情页播放按钮附近增加“加入播放列表”。
- 点击后弹出已有列表，并提供“新建播放列表”。
- 播放列表页展示名称、视频数量、第一张封面和最近更新时间。
- 播放列表详情页使用与首页一致的视频网格。

#### 数据规则

- 播放列表名称不能为空，长度建议 1～40 个字符。
- 同名列表允许创建，但建议在创建时提示用户确认。
- 删除视频本身不会自动删除播放列表中的条目；播放时若视频已失效，显示错误并允许移除。
- 列表只保存视频元数据快照，不保存播放地址。

### 4.3 播放器进度拖动优化

#### 当前问题

当前播放器使用 `VideoProgressIndicator(allowScrubbing: true)`。实际体验表现为更接近点击跳转，缺少明确的拖动预览、时间反馈和松手提交控制。

#### 目标交互

播放器底部显示自定义进度区域，包括：

- 已播放进度
- 缓冲进度（如果播放器可提供）
- 可拖动滑块
- 当前时间
- 总时长

用户按下并拖动时：

1. 进入“拖动中”状态。
2. 根据手指位置计算预览时间，并实时更新滑块和时间文本。
3. 视频画面保持当前播放位置，不在每个手指移动事件中调用 `seekTo`。
4. 暂停自动隐藏控制层；拖动期间控制层保持显示。

用户松手时：

1. 将最终预览时间限制在 `0～总时长`。
2. 仅调用一次 `controller.seekTo(finalPosition)`。
3. 更新当前播放时间。
4. 如果拖动前正在播放，保持播放；如果拖动前已暂停，继续保持暂停。
5. 恢复控制层自动隐藏计时器。

用户取消拖动或手势中断时：

- 不执行跳转，恢复拖动前的位置和播放状态。

#### 时间显示

- 格式：`m:ss`；超过 1 小时使用 `h:mm:ss`。
- 拖动时显示：`预览时间 / 总时间`，例如 `12:34 / 45:00`。
- 没有有效时长时，禁用拖动并显示 `0:00 / 0:00`。
- 进度不可超出视频时长，也不可小于 0。

#### 播放状态边界

- 初始化完成前不允许拖动。
- 播放发生错误时隐藏或禁用进度拖动，并显示重试入口。
- HLS 时长为未知或动态时，应以 `video_player` 当前可用 duration 为准；若 duration 无效则降级为不可拖动。
- 进度拖动期间不触发观看记录写入；松手后可按现有定时保存策略保存一次。
- 页面退出时仍需释放 `VideoPlayerController`。

## 5. 信息架构

推荐的底部导航调整：

```text
首页 | 分类 | 搜索 | 收藏 | 最近观看
```

如果屏幕空间或产品设计不希望增加第五个栏目，可将“收藏”和“最近观看”合并为“我的”页面，第一版仍需保证两个功能可独立访问。

## 6. 数据模型建议

### 6.1 收藏记录

```dart
class FavoriteRecord {
  final Video video;
  final DateTime createdAt;
  final DateTime updatedAt;
}
```

存储键建议：

```text
favorite_videos_v1
```

### 6.2 播放列表

```dart
class VideoPlaylist {
  final String id;
  final String name;
  final List<Video> videos;
  final DateTime createdAt;
  final DateTime updatedAt;
}
```

存储键建议：

```text
video_playlists_v1
```

建议使用稳定的本地 UUID 或时间戳组合生成 `id`，不要使用列表名称作为 ID。

### 6.3 Repository

建议新增：

```dart
abstract interface class LibraryRepository {
  Future<List<FavoriteRecord>> loadFavorites();
  Future<void> saveFavorite(FavoriteRecord record);
  Future<void> removeFavorite(String videoId);

  Future<List<VideoPlaylist>> loadPlaylists();
  Future<VideoPlaylist> createPlaylist(String name);
  Future<void> deletePlaylist(String playlistId);
  Future<void> addToPlaylist(String playlistId, Video video);
  Future<void> removeFromPlaylist(String playlistId, String videoId);
}
```

实现可以复用 `HistoryRepository` 的串行写入队列，避免连续点击收藏或加入列表时发生覆盖。

## 7. 状态管理建议

本阶段继续使用 Riverpod 管理 Repository 依赖，并逐步把收藏/播放列表状态提升为可观察状态：

```text
libraryRepositoryProvider
favoriteControllerProvider
playlistControllerProvider
```

推荐使用 `AsyncNotifier` 或 `Notifier`：

- 收藏列表：`AsyncNotifier<List<FavoriteRecord>>`
- 播放列表：`AsyncNotifier<List<VideoPlaylist>>`
- 当前播放列表详情：`family` 参数传入 playlistId

详情页只通过 controller 的方法执行收藏和加入列表，不直接访问存储。

播放器拖动状态是播放页局部高频 UI 状态，不必放进全局 Riverpod。可在 `_PlayerPageState` 中维护：

```dart
bool isSeeking = false;
Duration? previewPosition;
Duration? positionBeforeSeek;
bool wasPlayingBeforeSeek = false;
```

真正的媒体位置仍由 `VideoPlayerController` 管理。

## 8. 非功能需求

- 所有新增本地数据都必须兼容空数据、损坏 JSON 和字段缺失。
- App 重启后收藏和播放列表必须保留。
- 重复点击收藏、加入列表不能生成重复记录。
- 写入失败不能导致 App 崩溃。
- 播放器拖动过程中不能出现明显卡顿或大量网络请求。
- `seekTo` 在一次完整拖动手势中最多调用一次。
- 播放器退出后无 Timer、监听器或控制器泄漏。
- 本阶段不新增帐号，也不要求网络可用才能查看已保存的收藏和播放列表。

## 9. 验收标准

### 收藏

- [ ] 详情页可以收藏和取消收藏。
- [ ] 收藏列表能显示已收藏视频。
- [ ] App 重启后收藏仍存在。
- [ ] 同一视频重复收藏不会出现两条。
- [ ] 收藏视频可以进入详情和播放。
- [ ] 空状态和存储错误状态明确可见。

### 播放列表

- [ ] 可以创建、查看和删除播放列表。
- [ ] 可以将视频加入指定列表。
- [ ] 同一视频重复加入不会重复显示。
- [ ] 可以从列表移除视频。
- [ ] App 重启后列表和视频顺序仍存在。
- [ ] 删除列表有二次确认。
- [ ] 播放列表中的视频可以进入详情或播放。

### 播放器

- [ ] 进度条可以按住并连续拖动。
- [ ] 拖动时滑块和预览时间实时更新。
- [ ] 拖动时视频不会随着每个手指事件频繁跳转。
- [ ] 松手后只执行一次跳转。
- [ ] 松手后播放/暂停状态符合拖动前状态。
- [ ] 时间显示为当前预览时间/总时间。
- [ ] 进度不会超过视频总时长。
- [ ] 无有效时长、初始化失败和播放错误时，拖动行为正确降级。
- [ ] 播放器退出、后台切换和重试流程无资源泄漏。

## 10. 测试要求

### 单元测试

- FavoriteRecord JSON 序列化与反序列化
- 播放列表新增、移除、去重和顺序保持
- 空名称、超长名称和损坏存储数据处理
- 播放器预览时间 clamp 到合法范围
- `m:ss` 与 `h:mm:ss` 时间格式化

### Widget 测试

- 收藏按钮切换状态
- 收藏列表空状态和内容展示
- 创建列表、加入视频、移除视频
- 拖动进度条时显示预览时间
- 松手后触发一次 seek

### 真机验证

- Android HLS 和 MP4 拖动体验
- iOS HLS 和 MP4 拖动体验
- 长视频、短视频和无法获取 duration 的视频
- 播放中进入后台、返回前台及横竖屏切换

## 11. 开发顺序

1. 新增收藏和播放列表 Domain Model。
2. 新增本地 `LibraryRepository` 和 Riverpod Provider。
3. 实现收藏 controller 与详情页入口。
4. 实现收藏列表页面。
5. 实现播放列表创建、详情、加入和移除。
6. 把播放器原生进度指示器替换为可预览的自定义拖动控件。
7. 补充单元测试和 Widget 测试。
8. Android/iOS 真机验证播放器拖动和本地数据持久化。

## 12. 成功指标

- 家庭用户无需登录即可收藏、整理和继续观看内容。
- 常用视频可以在两次点击内从收藏或播放列表进入播放。
- 播放进度拖动具有“拖动预览、松手跳转”的稳定体验。
- 新增功能不破坏现有首页、搜索、详情、最近观看和播放重试流程。
