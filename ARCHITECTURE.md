# Flutter 视频 App 架构设计

## 1. 文档目的

本文档基于 `APP_REQUIREMENTS_V1.md` 与 `VOD_SOURCE_SWITCH_PRD_AND_PLAN.md`，定义第一版视频点播 App 的 Flutter 项目架构、目录结构、状态管理方案和关键技术约束。

目标是支持 Android 和 iOS MVP，并为后续接入自建后端、用户体系、会员能力和多设备同步保留扩展空间。

## 2. 架构总览

采用：

> **Feature-first + 轻量 Clean Architecture + Riverpod**

核心数据流：

```text
页面 Widget
    ↓
Riverpod Provider / Notifier
    ↓
VideoRepository
    ↓
VodSourceRegistry → VodSourceAdapter（按 sourceId 选择）
    ↓
VOD API / 本地存储
```

多源切换数据流：

```text
VodSourceRegistry（内置源列表，来自 config/vod_sources.json）
    ↓ 提供 VodSource + 对应 Adapter
selectedVodSourceProvider（全局浏览源，持久化到 SharedPreferences）
    ↓
HomePage / SearchPage / DetailPage
    ↓
VideoRepository.fetchPage(source, ...) / fetchDetail(source, ref) ...
```

基本原则：

- 页面不直接调用 HTTP 或本地存储。
- Provider 负责状态管理和业务流程编排。
- Repository 屏蔽具体数据来源，方法必须接收 `VodSource` 或 `VideoRef`，不依赖一个可变的全局 `baseUrl`。
- 同一协议源复用 Adapter，仅传入不同配置（`VodSource.baseUri` 等）。
- 详情缓存键使用 `globalId = sourceId:sourceVideoId`，不同源缓存相互隔离。
- 播放器作为独立 Feature 管理资源生命周期。
- 第三方 VOD API 与自建后端通过 Repository/Data Source 解耦。

## 3. 推荐目录结构

```text
lib/
├── main.dart
├── app/
│   ├── app.dart
│   ├── router/
│   │   ├── app_router.dart
│   │   └── route_names.dart
│   ├── theme/
│   │   ├── app_theme.dart
│   │   ├── app_colors.dart
│   │   └── app_text_styles.dart
│   └── config/
│       ├── app_config.dart
│       └── env.dart
│
├── core/
│   ├── network/
│   │   ├── dio_client.dart
│   │   ├── api_exception.dart
│   │   ├── network_interceptor.dart
│   │   └── request_result.dart
│   ├── pagination/
│   │   ├── page_request.dart
│   │   └── pagination_state.dart
│   ├── error/
│   │   ├── app_error.dart
│   │   └── error_mapper.dart
│   ├── constants/
│   ├── extensions/
│   └── widgets/
│       ├── app_error_view.dart
│       ├── app_empty_view.dart
│       ├── app_loading_view.dart
│       └── load_more_footer.dart
│
├── shared/
│   ├── models/
│   ├── providers/
│   │   └── core_providers.dart
│   └── widgets/
│       ├── video_card.dart
│       ├── video_grid.dart
│       └── category_chip.dart
│
├── features/
│   ├── home/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── application/
│   │   │   └── home_providers.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   └── home_page.dart
│   │       └── widgets/
│   ├── category/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── application/
│   │   │   └── category_providers.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   └── category_page.dart
│   │       └── widgets/
│   ├── search/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── application/
│   │   │   └── search_providers.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   └── search_page.dart
│   │       └── widgets/
│   ├── video_detail/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── application/
│   │   │   └── video_detail_providers.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   └── video_detail_page.dart
│   │       └── widgets/
│   ├── player/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── application/
│   │   │   ├── player_controller.dart
│   │   │   └── player_providers.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   └── player_page.dart
│   │       └── widgets/
│   │           ├── video_player_view.dart
│   │           ├── player_controls.dart
│   │           └── player_error_view.dart
│   └── watch_history/
│       ├── data/
│       ├── domain/
│       ├── application/
│       │   └── watch_history_providers.dart
│       └── presentation/
│           ├── pages/
│           │   └── watch_history_page.dart
│           └── widgets/
└── l10n/
    ├── app_zh.arb
    └── app_en.arb
```

### 3.1 多 VOD 源模块（当前实现）

```text
lib/domain/
├── vod_source.dart          # VodSource 模型（id/name/baseUri/adapterType/search/enabled/priority/featuredCategoryIds）
├── video.dart               # Video 含 sourceId/sourceVideoId/globalId；VideoRef；PlaybackLine；VideoPage.total

lib/data/
├── vod_source_config.dart   # 从 assets 读取 config/vod_sources.json
├── vod_source_registry.dart # 内置源列表 + adapter 映射；vodSourceRegistryProvider
├── vod_source_adapter.dart  # VodSourceAdapter 接口
├── adapters/
│   └── mac_cms_v10_adapter.dart  # Mac CMS V10 解析实现
├── vod_source_preferences.dart   # selectedVodSourceProvider（持久化全局源）
└── video_repository.dart    # VideoRepositoryImpl 统一入口，按 source/ref 请求

lib/features/
├── paged_video_controller.dart          # 首页/单源分页（绑定 VodSource）
├── multi_source_search_controller.dart  # 搜索页 1+3 多源探测协调器
├── detail_source_controller.dart        # 详情页局部切源协调器
└── detail_more_sources_sheet.dart       # 详情"更多来源"底部弹窗
```

### 3.2 Provider 结构

```text
vodSourceConfigProvider        FutureProvider<List<VodSource>>      从 assets JSON 加载
vodSourceRegistryProvider      FutureProvider<VodSourceRegistry>    内置源 + adapter 映射
selectedVodSourceProvider      NotifierProvider<AsyncValue<VodSource>>  全局浏览源（持久化）
videoRepositoryProvider        Provider<VideoRepository>            统一访问入口
```

## 4. 分层职责

### 4.1 presentation

负责页面、组件和用户交互，只关心状态展示和事件触发。

页面不应直接出现以下代码：

```dart
Dio().get(...);
SharedPreferences.getInstance();
```

页面主要处理：

- 加载状态
- 成功状态
- 空数据状态
- 错误状态
- 用户点击、刷新、分页和重试

### 4.2 application

负责页面级业务状态和业务流程，例如：

- 首页分页
- 分类切换
- 搜索防抖和分页
- 视频详情加载
- 当前剧集选择
- 播放器状态
- 最近观看列表刷新

### 4.3 domain

放置稳定的业务模型和 Repository 接口，不依赖 Dio、Flutter Widget 或具体存储实现。

示例：

```dart
abstract interface class VideoRepository {
  Future<PagedResult<Video>> fetchLatest({required int page});

  Future<PagedResult<Video>> fetchByCategory({
    required int categoryId,
    required int page,
  });

  Future<PagedResult<Video>> search({
    required String keyword,
    required int page,
  });

  Future<VideoDetail> fetchDetail(String videoId);
}
```

### 4.4 data

负责 API、本地存储和数据转换：

- VOD API 请求
- DTO 解析
- `vod_play_url` 解析
- 字段缺失和异常格式兼容
- 本地观看记录读写
- DTO 到 Domain Model 的转换

Adapter 职责：

- 第三方字段到统一 `Video`/`VideoPage` 的映射。
- 分类层级和源分类 ID 解析。
- 多播放线路（`$$$` 分隔）和剧集分隔符解析。
- 源错误转换为统一 `VideoDataException`。
- 设置解析结果的 `sourceId`/`sourceVideoId`。
- 只过滤 HTTPS 播放地址。

建议至少区分：

```text
VodSource          VOD 源配置（id/name/baseUri/adapterType/...）
VodSourceAdapter   源协议解析实现（Mac CMS V10 等）
Video             App 业务模型
WatchRecord       本地观看记录模型
```

## 5. 状态管理方案

### 5.1 总体选择

使用 **Riverpod** 作为统一的状态管理和依赖注入方案。

推荐职责划分：

| 状态类型 | 处理方式 |
|---|---|
| 输入框文本 | `TextEditingController` |
| 菜单显示、局部动画 | `setState` |
| 首页视频列表 | `AsyncNotifier` |
| 分类和分页 | `AsyncNotifier` |
| 搜索结果 | `AsyncNotifier` |
| 视频详情 | `FutureProvider.family` |
| 当前剧集 | `Notifier` |
| 播放器状态 | 专用 `Notifier` / Controller |
| 最近观看 | Riverpod + Repository |
| 全局配置和主题 | `Provider` |

不建议为每个简单布尔值都创建全局 Provider。

### 5.2 Provider 命名建议

```text
homeControllerProvider
categoryControllerProvider(categoryId)
searchControllerProvider
videoDetailProvider(videoId)
playerControllerProvider(videoId, episodeId)
watchHistoryControllerProvider
```

### 5.3 搜索策略

搜索需要同时具备：

- 约 300～500ms 防抖（当前实现 600ms）
- 取消上一次未完成请求
- 空关键词不发请求
- 新关键词结果覆盖旧关键词（generation 隔离）
- 支持清空、刷新、分页和重试

### 5.4 多源状态管理

全局浏览源与详情页/搜索页局部源是两个独立状态：

- `selectedVodSourceProvider`：全局浏览源，持久化到 SharedPreferences，决定首页、分类和新搜索会话。
- 搜索页：`MultiSourceSearchController` 维护 `SearchSessionState`（keyword + activeSourceId + 每源状态 + generation）。默认 1 个当前源 + 最多 3 个备用源自动探测；每个来源独立保存分页、加载、错误和总数；点击备用来源只切换当前搜索页来源，不修改全局源；相同"关键词+来源+页码"缓存约 7 分钟。
- 详情页：`DetailSourceController` 维护 `activeVideo`、各源检测状态和 switching 标志。正常打开只请求当前源；用户点击"检测其他来源"才并发探测最多 3 个备用源；跨源候选确认后原子切换，失败回滚保留旧详情。

## 6. 数据层设计

### 6.1 Repository 划分

```text
VideoRepository
├── fetchPage(source, {page, categoryId, keyword})
├── fetchCategories(source)
├── fetchDetail(source, ref)
└── resolvePlayback(source, ref)

VodSourceRegistry
├── allSources / enabledSources / searchableSources
├── findById(id)
└── adapterFor(source)

VodSourceAdapter
├── fetchPage / fetchCategories / fetchDetail / resolvePlayback

WatchHistoryRepository
├── getRecent()
├── saveProgress()
├── findRecord()
└── remove()
```

Repository 方法接收 `VodSource` 或 `VideoRef`，不依赖一个可变的全局 `baseUrl`；详情缓存键使用 `globalId`。

### 6.1.1 资源身份与跨源隔离

```text
VideoRef
├── sourceId
├── sourceVideoId
└── globalId = sourceId:sourceVideoId
```

- 所有资源键（缓存、收藏、历史、Widget Key）使用 `globalId`，不同源的相同 `vod_id` 互不覆盖。
- 旧本地数据缺少 `sourceId` 时，`Video.fromJson` 迁移为默认值 `storm`。
- 收藏仍保存具体来源资源；详情页切源不会自动改变收藏。
- 观看历史记录实际播放的来源和资源 ID，继续播放时从该来源刷新地址。

### 6.1.2 内容源与播放线路分离

- `VodSource`：内容源（"暴风资源 / 来源 A / 来源 B"）。
- `PlaybackLine`：同一资源 `vod_play_url` 中以 `$$$` 分隔的线路。解析模型保留全部有效线路，第一期界面只实现内容源切换。

### 6.2 播放地址接口

不要把所有能力集中到一个巨大的 `VodRepository` 中。

```dart
abstract interface class PlayerRepository {
  Future<PlaySource> resolvePlayUrl({
    required String videoId,
    required String episodeId,
    required String source,
  });
}
```

以后从第三方 API 切换到自建后端时，只替换 Data Source 或 Repository 实现，不影响页面和播放器业务层。

### 6.3 网络层

建议使用 Dio，并统一处理：

- HTTPS
- 连接、发送和接收超时
- 网络异常转换
- 请求取消
- 重试
- 日志
- 统一响应解析

建议初始超时配置：

```text
连接超时：10 秒
发送超时：10 秒
接收超时：15 秒
```

列表和搜索请求必须支持取消；播放地址请求支持手动重试。

## 7. 播放器设计

播放器必须作为独立 Feature，不直接耦合到详情页。

播放流程：

```text
详情页
  ↓ 点击剧集
PlayerRoute(videoId, episodeId)
  ↓
请求播放地址
  ↓
初始化播放器
  ↓
播放
  ↓
保存进度
  ↓
页面销毁
  ↓
暂停、保存进度、释放播放器资源
```

播放器状态建议包括：

```text
idle
loadingUrl
initializing
playing
paused
buffering
completed
error
disposed
```

必须处理：

- 播放地址请求失败和重试
- 播放地址过期后的重新获取
- `VideoPlayerController.dispose()`
- 横竖屏切换和页面方向恢复
- App 进入后台和返回前台
- 播放完成状态
- 无效格式或无播放地址

播放地址只在用户点击播放时请求。

## 8. 最近观看设计

### 8.1 数据结构

```text
videoId
videoName
videoPic
episodeId
episodeName
source
positionSeconds
durationSeconds
updatedAt
```

### 8.2 存储建议

先抽象本地数据源：

```dart
abstract interface class WatchHistoryLocalDataSource {
  Future<List<WatchRecord>> getRecords();

  Future<void> upsert(WatchRecord record);

  Future<void> delete(String videoId, String episodeId);
}
```

MVP 可以使用 JSON 形式的本地存储，并限制最近记录数量；如果后续增加筛选、清理、统计或更复杂查询，再切换到 SQLite/Drift 等结构化存储。

播放进度不应每一帧写入本地，建议：

- 每 5～10 秒保存一次
- 暂停时保存
- 退出播放器时保存
- 播放完成时标记完成或清理进度

## 9. 路由设计

建议使用声明式路由，路由只传递业务 ID：

```text
/                         首页
/category/:categoryId     分类页
/search                   搜索页
/video/:videoId           视频详情页
/player/:videoId/:episodeId 播放页
/history                  最近观看页
```

详情页不要依赖上一个页面传入的完整对象，进入详情后根据 `videoId` 加载数据，避免数据过期并方便后续支持深链接。

## 10. 推荐依赖

```yaml
dependencies:
  flutter_riverpod:
  riverpod_annotation:
  dio:
  go_router:
  video_player:
  cached_network_image:
  shared_preferences:
  freezed_annotation:
  json_annotation:

dev_dependencies:
  riverpod_generator:
  build_runner:
  freezed:
  json_serializable:
  flutter_lints:
```

依赖选择原则：

- `flutter_riverpod`：状态管理和依赖注入
- `dio`：网络请求
- `go_router`：路由和参数传递
- `video_player`：基础视频播放能力
- `cached_network_image`：封面缓存
- `freezed` / `json_serializable`：模型和 JSON 解析
- `shared_preferences`：简单本地配置或 MVP 观看记录

不建议同时引入 Riverpod、BLoC、GetX、Provider 等多套状态管理方案。

## 11. 开发顺序

1. 验证真实详情接口和 `vod_play_url` 格式。
2. 验证 Android、iOS 真机播放 `.m3u8` 或其他实际格式。
3. 建立网络层、模型和 `VideoRepository`。
4. 完成详情页到播放器的完整闭环。
5. 实现首页、分类页和搜索分页。
6. 增加最近观看和播放进度。
7. 处理弱网、断网、空数据、接口异常和播放地址过期。
8. 验证横竖屏、后台切换、连续进入/退出播放页和资源释放。

## 12. 首要风险

开发初期必须优先确认：

- 视频源是否拥有明确合法授权。
- `vod_play_url` 的实际格式和分隔规则。
- 播放地址是否需要 Referer、Token 或特殊 Header。
- 播放地址是否存在过期时间。
- Android 和 iOS 是否都能播放实际返回的视频格式。
- 是否必须通过自建后端代理播放地址。

如果第三方 API 或播放地址不稳定，应尽早增加自建后端适配层，避免 Flutter 客户端直接依赖源站细节。
