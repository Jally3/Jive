# 代码文件地图

本文档是 `lib/` 下每个 Dart 文件的逐文件索引，回答「这个文件是什么、管什么」，用于快速定位代码。分层原则、依赖方向与子系统设计的权威说明见根目录 `ARCHITECTURE.md`，本文档不重复架构论述，只做文件级导览。生成于 2026-08，以当时磁盘上的真实结构为准。**新增、移动、删除文件时请同步更新本文档。**

## 入口与应用壳

```text
lib/
├── main.dart                          # 应用入口：设置状态栏样式，启动 ProviderScope/JiveApp
└── app/
    ├── app.dart                       # 根组件 JiveApp 与 AppShell：主题、三页底部导航壳、源加载闸门、下载生命周期联动
    └── theme.dart                     # 「夜幕影院」深色主题：AppColors 色板与 buildTheme()
```

## 共享组件（`lib/shared/`）

```text
lib/shared/
├── app_states.dart                    # 通用状态视图：AppLoadingView / AppEmptyView / AppErrorView
├── app_toast.dart                     # 全局居中 toast：挂 root Overlay，2 秒自消，同时只显示一条
├── is_tv.dart                         # isTvProvider：经 jive/device 通道判断是否 Android TV（iOS/失败恒 false）
├── playback_scrubber.dart             # 播放进度滑杆：缓冲区间合并绘制、可拖动预览 seek
├── source_selector.dart               # 全局选源底部弹层 SourceSelectorSheet（资源站/高清站两个 tab）
├── video_card.dart                    # 视频海报卡片 VideoCard：封面、标题、meta、观看进度条、TV 焦点描边
└── video_grid.dart                    # 自适应视频网格 VideoGrid：两列/四列 sliver 布局、动态卡片比例
```

## 领域模型（`lib/domain/`）

纯数据模型，不含 UI 与 IO，被 data/ 与 features/ 双向依赖。

```text
lib/domain/
├── video.dart                         # 核心模型：Video / VideoRef / Episode / PlaybackLine / VideoCategory / VideoPage
├── vod_source.dart                    # VOD 源模型 VodSource：JSON 解析、HTTPS 与启用状态校验
├── library.dart                       # 收藏记录 FavoriteRecord（含 JSON 反序列化容错）
├── watch_record.dart                  # 观看历史 WatchRecord：进度、完播标记、时间线/manifest 版本指纹
├── playback_progress.dart             # 播放进度值对象 PlaybackProgress：归一化、完播阈值、续播位置
├── playback_selection.dart            # 一次播放的完整定位 PlaybackSelection：源/视频/线路/剧集身份 + 播放地址
├── playback_source.dart               # 播放地址 PlaybackSource 与格式枚举 PlaybackFormat（HLS/MP4/DASH）
└── playback_status.dart               # 播放模式 PlaybackMode、降级原因 PlaybackFallbackReason、PlaybackStatus
```

## 数据层根（`lib/data/`）

```text
lib/data/
├── video_repository.dart              # 内容访问门面 VideoRepository(Impl)：按 adapterType 分发请求、详情 2 分钟短缓存、敏感内容过滤
├── library_repository.dart            # 收藏持久化：SharedPreferences 存储，写操作串行队列防并发损坏
└── history_repository.dart            # 观看历史持久化 HistoryRepository：串行写入、按更新时间排序读取
```

## VOD 源接入（`lib/data/vod_source/`）

配置 → 注册表 → 偏好选择的单向装配；`adapters/` 实现 `vod_source_adapter.dart` 定义的接口，被 `video_repository.dart` 调用。

```text
lib/data/vod_source/
├── vod_source_config.dart             # 源列表加载：远端优先 → 远端缓存 → 内置资产，仅放行启用的 HTTPS 源
├── vod_source_registry.dart           # 源注册表 VodSourceRegistry 与内置 Adapter 表、vodSourceRegistryProvider
├── vod_source_adapter.dart            # Adapter 接口 VodSourceAdapter，及可选的剧集播放解析扩展 EpisodePlaybackResolver
├── vod_source_preferences.dart        # 全局当前源 selectedVodSourceProvider：持久化选择、白名单与 HTTPS 校验
└── adapters/
    ├── mac_cms_v10_adapter.dart       # MacCMS v10 JSON API 通用适配器（默认 adapterType）
    ├── age_adapter.dart               # AGE 动漫站适配器（age_v2）：自研协议、线路优选与 m3u8 解析器
    ├── olevod_adapter.dart            # Olevod 高清站适配器（olevod_v1）：HTML 抓取、带签名的详情/搜索请求
    ├── syncnext_plugin_adapter.dart   # Syncnext 插件源适配器：按源缓存 JS 会话，实现 EpisodePlaybackResolver
    ├── syncnext_plugin_models.dart    # 插件配置模型：SyncnextPluginConfig / 页面 / 端点的 JSON 解析
    └── syncnext_plugin_runtime.dart   # 通用 JS 插件运行时：JsPluginSession 经 flutter_js 执行插件脚本，桥接 HTTP 与 Cookie
```

## 内容策略（`lib/data/content/`）

```text
lib/data/content/
├── category_nav.dart                  # 首页两级分类树构建：featured 过滤、空分类裁剪、可查询叶子 id 计算
├── category_blocklist.dart            # 敏感分类关键词黑名单与命中判断（按分类名子串匹配）
├── my_channels_store.dart             # 首页「我的频道」（tab 行根分类集合与顺序）按源持久化存取
└── content_filter_policy.dart         # 内容过滤总开关 contentFilterEnabledProvider：默认开启、选择持久化
```

## 播放链路（`lib/data/playback/`）

`playback_session` 是装配核心：依赖 cache/ 完成边下边播，代理与解析器只服务它；`prefetch_policy` 独立提供设置项。

```text
lib/data/playback/
├── playback_session.dart              # 播放会话 PlaybackSession：解析 manifest、注册代理路由、挂缓存写穿与分片预取、产出降级状态
├── local_proxy.dart                   # 本地回环代理 LocalProxyServer：按 token 路由转发 manifest 与分片资源
├── playback_url_resolver.dart         # 未知格式播放地址解析 PlaybackUrlResolver：HTML/重定向解析，结果带 10 分钟缓存
├── hls_parser.dart                    # HLS manifest 解析与代理改写：HlsParser / HlsProxyPlan / HlsDecision 可缓存性判定
├── ad_filter.dart                     # 广告分片识别与剔除 AdFilter（adfilter-v3：夹心中插 + 节奏侏儒 + AdFilterReport）；TimelineMapping 负责源时间轴 ↔ 过滤后时间轴换算
├── content_type_sniffer.dart          # 播放格式嗅探：HEAD content-type 优先、魔数回退，带 TTL 缓存
└── prefetch_policy.dart               # 预取策略：Wi-Fi/蜂窝预取窗口时长，prefetchModeProvider 开关持久化
```

## 缓存（`lib/data/cache/`）

`cache_manager` 是核心，`cache_index`/`cache_io`/`content_key`/`url_normalizer` 为其服务；`cache_controller`/`cache_repository`/`cache_providers` 面向 UI 与 Riverpod 装配。playback 与 download 都经由它读写分片。

```text
lib/data/cache/
├── cache_manager.dart                 # 缓存核心 CacheManager：磁盘配额计算、LRU/TTL 淘汰、引用计数 CacheRef 与写租约 WriteLease
├── cache_index.dart                   # 磁盘索引格式与 CacheIndexStore：条目/资源记录、state.json 探测、目录常量
├── cache_io.dart                      # 资源抓取器 ResourceFetcher：读穿/写穿缓存、SingleFlight 合并、响应头白名单与完整性校验
├── content_key.dart                   # ContentKey 构建：源+视频+线路+剧集身份编码后的 sha256 寻址
├── url_normalizer.dart                # URL 归一化：剔除时效签名参数，保证缓存寻址稳定
├── single_flight.dart                 # 并发原语：AsyncMutex 串行锁与 SingleFlight 在飞请求去重
├── cache_ttl_policy.dart              # 缓存 TTL 选项 cacheTtlProvider：退出清理 / 1 小时 / 5 小时 / 1 天
├── cache_providers.dart               # 缓存装配：持久目录（含旧临时目录迁移）、diskSpaceProvider、cacheManagerProvider
├── cache_repository.dart              # CacheManager 的薄封装 CacheRepository，供 UI 层依赖
└── cache_controller.dart              # 缓存页状态 cacheControllerProvider：统计刷新、单条删除、清空全部
```

## 下载（`lib/data/download/`）

下载复用 playback 的解析能力与 cache 的存储配额，任务产物即缓存条目。

```text
lib/data/download/
├── download_manager.dart              # 边下边播分片预取器 SegmentPrefetcher：并发抓取、指数退避、窗口随播放位置重锚定
├── download_task_manager.dart         # 显式下载引擎 DownloadTaskManager：任务持久化、并发许可池、暂停/恢复/断点续下、速度采样
├── download_providers.dart            # 下载装配 downloadManagerProvider：注入缓存与剧集选择回解析，联动 App 生命周期
└── platform_disk_space.dart           # 磁盘空间通道 PlatformDiskSpaceProvider：MethodChannel(jive/cache) 读容量/可用空间
```

## 功能页（`lib/features/`）

每页一个子目录；页面只经 Riverpod provider 或控制器访问 data/，不直接碰 IO。

```text
lib/features/
├── home/
│   ├── home_page.dart                 # 首页：两级分类导航、视频网格、选源入口、返回顶部
│   ├── category_channels_page.dart    # 「全部频道」全屏页：我的频道自适应网格（手机 4 列、平板 5–8 列）、编辑模式增删与拖拽排序、全部分类分组
│   └── paged_video_controller.dart    # 首页分页控制器：加载更多、错误态、首页结果 2 分钟快照缓存
├── search/
│   ├── search_page.dart               # 搜索页：输入防抖、跟随全局切源、多源结果聚合展示
│   └── multi_source_search_controller.dart  # 多源搜索控制器：并行探测各可搜索源、逐源分页与状态聚合
├── detail/
│   ├── detail_page.dart               # 详情页 VideoDetailPage：详情加载、线路/选集分组、收藏、下载与切源入口
│   ├── detail_source_controller.dart  # 详情页跨源探测 DetailSourceController：备用源搜索匹配与状态机
│   └── detail_more_sources_sheet.dart # 「全部来源」底栏：备用源状态列表与一键探测
├── player/
│   ├── player_page.dart               # 播放器主页 PlayerPage：会话建立与降级、手势亮度/音量、进度记忆、TTL 退出清理
│   └── widgets/
│       ├── player_controls_bar.dart       # 底部控制条：进度、播放/暂停、上下集、下载、倍速、选集、全屏
│       ├── player_top_bar.dart            # 沉浸式顶栏：返回按钮与标题
│       ├── player_gesture_layer.dart      # 手势层：单击/双击/横滑 seek/长按倍速/纵滑亮度音量的事件分发
│       ├── player_overlays.dart           # 悬浮层：暂停态中央大播放按钮等
│       ├── player_indicators.dart         # 指示器：缓冲菊花等播放中状态
│       ├── player_error_view.dart         # 播放失败视图：错误文案与「重新获取并重试」
│       ├── playback_status_indicator.dart # 播放链路状态圆点：颜色区分边下边播/缓存/代理/直连，长按看详情
│       └── player_info_panel.dart         # 竖屏播放器下方信息面板：简介与分组选集
├── profile/
│   └── profile_page.dart              # 「我的」页：收藏/历史双 tab 网格，设置/下载/源管理入口
├── cache/
│   └── cache_management_page.dart     # 缓存管理页：用量统计、配额展示、单条删除与清空确认
├── download/
│   └── download_management_page.dart  # 下载管理页：任务筛选、批量暂停/删除、离线播放入口
└── settings/
    ├── source_management_page.dart    # 源管理页：源列表、健康检查（延迟/可用性）与结果持久化展示
    └── more_settings_page.dart        # 更多设置：缓存 TTL 选择、预加载开关、缓存管理入口
```

## 测试（`test/`）

`test/` 镜像 `lib/` 结构，不逐文件列出：

```text
test/
├── widget_test.dart                   # 应用启动冒烟测试
├── domain/                            # 领域模型单测（进度、选集、状态、源模型）
├── data/                              # 数据层单测，按子域分目录：
│   ├── vod_source/                    #   源配置/注册表/各 Adapter（含 Syncnext 插件运行时）
│   ├── content/                       #   分类导航、黑名单、过滤开关
│   ├── playback/                      #   会话、代理、HLS 解析、广告过滤、嗅探、预取
│   ├── cache/                         #   缓存管理器/索引/IO/TTL/ContentKey 等
│   ├── download/                      #   预取器、任务管理器、磁盘空间
│   └── *.dart                         #   三个仓储的测试在 data/ 根部
├── features/                          # 页面与控制器测试，目录与 features/ 同名对应
└── shared/                            # 共享组件测试（toast、进度滑杆、选源弹层）
```
