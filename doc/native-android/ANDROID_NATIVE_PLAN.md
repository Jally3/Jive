# 安卓原生版 Jive 工作规划

状态：规划稿（待评审，2026-09-19）
基线：Flutter 版 v1.1.0+5；现状盘点以 [doc/flows/](../flows/README.md) 五份文档（2026-09 静态盘点）为唯一事实来源
相关文档：[flows/NAVIGATION_MAP.md](../flows/NAVIGATION_MAP.md)、[flows/USER_FLOWS.md](../flows/USER_FLOWS.md)、[flows/PLAYBACK_PIPELINE.md](../flows/PLAYBACK_PIPELINE.md)、[flows/CACHE_DOWNLOAD_FLOWS.md](../flows/CACHE_DOWNLOAD_FLOWS.md)、[flows/PROTOTYPES.md](../flows/PROTOTYPES.md)、[design/DESIGN_SYSTEM.md](../design/DESIGN_SYSTEM.md)、[ARCHITECTURE.md](../../ARCHITECTURE.md)

## 1. 目标与范围

把 Jive 从 Flutter 实现重写为**安卓原生应用**，以 v1.1.0+5 的行为为对齐目标，而非重新设计。全部页面结构、交互、流程分支以 `doc/flows/` 五份文档为验收底稿，视觉以 `DESIGN_SYSTEM.md`（夜幕影院/暖昼 Token）为唯一依据。

- **对齐范围**：flows 五份文档覆盖的全部功能——三 tab 骨架、首页三种 feed、搜索多源聚合、详情换源、播放十步流水线（含广告过滤与本地代理）、缓存/下载体系、追更收藏、TMDB 榜单流、LLM 推荐流、设置与来源管理、TV 遥控按键（见决策点 D6）、宽屏断点。
- **不改变的行为**：降级路径、五态播放模式、TTL 七档、下载状态机、追更 30 分钟检查等均按现状移植；flows 各文档「改版观察」中列出的优化点**默认不在本次范围**，除非规划中被显式采纳（见第 9 节决策点）。
- **规模参考**：Flutter 侧 118 个 Dart 源文件、73 个测试文件；播放链路 + 缓存体系约 5000 行核心逻辑（`lib/data/playback` + `lib/data/cache`），是移植深水区。
- **超出现状的新增**：仅两项被默认采纳（理由见 D5、第 6 节）：① 引入真正的路由表（修正 flows/NAVIGATION_MAP §5.1 指出的「无路由表」债，为深链铺路）；② 老版本本地数据迁移（可选，依 D1）。

## 2. 技术选型

| 领域 | 推荐方案 | 备选 | 说明 |
| --- | --- | --- | --- |
| 语言/SDK | Kotlin 2.x，JDK 17 | — | — |
| UI | Jetpack Compose + Material 3 | XML/View | 全新实现无历史包袱，Compose 是唯一合理默认 |
| minSdk / targetSdk | 26 / 35 | minSdk 24 | 26 = Android 8.0（2026 年覆盖率约 97%+），免 desugaring 大部分 API |
| 架构 | 单 Gradle 模块 + 分层包（`core/`、`feature/`、`ui/common/`） | 轻量多模块 | 对齐 Flutter `lib/` 的 feature-first 结构；移植期不拆模块降低摩擦，稳定后再拆 |
| 状态/异步 | Coroutines + Flow + ViewModel | RxJava | `StateFlow` ↔ Riverpod `AsyncValue` 对应关系见 §3.2 |
| DI | Hilt | Koin | 与 ViewModel/Worker 生态集成最好 |
| 网络 | OkHttp + kotlinx.serialization | Retrofit/Ktor client | VOD 源格式杂（JSON/正则抽取/HEAD 探测），直接用 OkHttp 手写更贴现状（Flutter 侧同样是 `http` 直连） |
| 持久化 | DataStore Preferences（KV 设置）+ JSON 文件（历史/收藏/缓存索引/下载任务，kotlinx.serialization，磁盘布局与 Flutter 版一致） | Room | 磁盘格式对齐 = `watch_history_v1`/`content_library_v2`/`download_tasks.json`/`jive_cache/` 可直接复用与迁移，逻辑一一对应（D4 可改 Room，见第 9 节） |
| 播放器 | Media3 1.x ExoPlayer | — | 唯一现实选择；替代 Flutter `video_player`（其 Android 实现即 ExoPlayer） |
| 本地代理 | Ktor Server (CIO engine)，仅监听 127.0.0.1 | NanoHTTPD / Media3 CacheDataSource | 现状架构是「播放器 ← 127.0.0.1 代理 ← 缓存/回源」，代理承担 HLS 清单改写与广告分片剔除，**不能**用 CacheDataSource 替代（会丢广告过滤与时间轴映射）；Ktor 协程模型与分片转发匹配（D2） |
| JS 插件运行时 | QuickJS Android（`quickjs-android`） | Liquid/自封装 JNI | 对应 `flutter_js` 的 Syncnext 插件运行时（`$http`/`$next` 桥）；排期上放最后批次（D3） |
| 图片 | Coil 3 | — | 对应 `cached_network_image`，Compose 原生支持 |
| 亮度/常亮/网络状态 | Android 原生 API：`WindowManager.LayoutParams.screenBrightness`、`keepScreenOn`、`ConnectivityManager.NetworkCallback` | — | 对应 `screen_brightness`/`wakelock_plus`/`connectivity_plus`，无需第三方库 |
| 磁盘空间 | `StatFs` / `StorageManager` | — | 对应平台通道 `jive/cache`（`platform_disk_space.dart`），原生后可直接读，**去掉平台通道** |
| 启动闪屏 | `androidx.core.splashscreen` + 自绘 Logo 页 | — | 复用 `doc/splash/SPLASH_PLAN.md` 已验证的「原生消白闪」思路 |
| 导航 | Navigation Compose + 类型安全路由 | 手写路由表 | 路由表即 flows/NAVIGATION_MAP §3 的导航地图（D5） |
| 测试 | JUnit5 + kotlinx-coroutines-test（逻辑）、Compose 语义测试（UI） | Paparazzi 截图 | 黄金样本策略见 §7 |

**明确不引入**：RxJava、多套 DI、MVI 框架（如 Orbit/Mavericks）、WorkManager（现状下载不支持后台续跑，进后台即暂停，行为保持一致；前台服务列为后续增强，不在本期）。

## 3. 工程结构与模块映射

### 3.1 目录映射总表

新工程建议放同仓 `android-native/`（D1），文档、设计 Token、后端契约继续共享。

| Flutter 现状 | Kotlin 目标 | 移植方式 |
| --- | --- | --- |
| `lib/main.dart` + `lib/app/` | `android-native/app/src/main/.../JiveApplication.kt`、`MainActivity.kt`、`ui/theme/` | 重写；主题 Token 按 DESIGN_SYSTEM §2 全量落 `JiveColors`/`JiveTypography` |
| `lib/shared/`（app_states/toast/anchored_menu/scrubber/video_card/video_grid/is_tv/double_back_exit/skip_settings/app_update_dialog） | `ui/common/` | 重写（Compose 组件语义不同），交互行为逐项对照 PROTOTYPES §14 |
| `lib/domain/` | `core/model/` | **直译**：纯数据模型，kotlinx.serialization 手写（对应手写 fromJson） |
| `lib/data/video_repository.dart`、`library_repository.dart`、`history_repository.dart` | `core/data/vod/`、`core/data/library/`、`core/data/history/` | 直译 + Repository 接口不变 |
| `lib/data/vod_source/`（config/registry/adapter/preferences）+ `adapters/`（mac_cms_v10/age/olevod/syncnext_plugin + runtime） | `core/data/vod/source/` + `core/data/vod/adapter/` + `jsengine/` | 前三个 adapter 直译；syncnext 的 JS 运行时换 QuickJS，`$http`/`$next` 桥接口保持同名同语义 |
| `lib/data/content/`（category_nav/blocklist/filter_policy） | `core/data/content/` | 直译 |
| `lib/data/playback/`（playback_session/url_resolver/hls_parser/ad_filter/local_proxy/content_type_sniffer/prefetch_policy/skip_policy） | `core/data/playback/` + `core/proxy/` | **重点直译**；`local_proxy` 网络层换 Ktor，其余解析/过滤逻辑行级对照 |
| `lib/data/cache/`（cache_manager/index/io/ttl/content_key/single_flight/url_normalizer/providers） | `core/data/cache/` | 直译；磁盘布局逐字节对齐（§7 等价性验收） |
| `lib/data/download/`（task_manager/manager/network_policy/providers/disk_space） | `core/data/download/` | 直译；disk_space 改 `StatFs`，无平台通道 |
| `lib/features/home/` + `paged_video_controller` | `feature/home/` | 重写；`AsyncNotifier` → `ViewModel + StateFlow` |
| `lib/features/search/` + `multi_source_search_controller` | `feature/search/` | 重写；防抖/取消/generation 隔离语义保持（ARCHITECTURE §5.3） |
| `lib/features/detail/`（detail_source_controller 等） | `feature/detail/` | 重写 |
| `lib/features/player/` + `widgets/`（8 个组件） | `feature/player/` | 重写；手势层与控制条对照 PLAYBACK_PIPELINE §3 逐项 |
| `lib/features/profile|cache|download|settings/` | `feature/profile|cache|download|settings/` | 重写 |
| Riverpod Provider 图（ARCHITECTURE §3.2） | Hilt module + 单例 `@Singleton` + ViewModel | `selectedVodSourceProvider` → `SelectedVodSourceStore`（StateFlow + DataStore 持久化） |
| 跨页搜索请求 `searchLaunchRequestProvider` | `SearchLaunchBus`（SharedFlow，AppShell 级收集） | 机制对齐 NAVIGATION_MAP §3.1 |
| 平台通道 `jive/cache` | 直接 API 调用 | 删除中间层 |
| `flutter_js` | QuickJS Android | D3，最后批次 |

### 3.2 状态模型对应约定

| Riverpod 概念 | Kotlin 对应 |
| --- | --- |
| `AsyncNotifier`（首页/搜索分页） | `ViewModel` 暴露 `StateFlow<UiState>`，UiState 为 sealed interface（Loading/Data/Error，对应 `AppLoadingView` 三态） |
| `FutureProvider.family`（详情） | `ViewModel`（SavedStateHandle 携带 videoRef） |
| `Notifier`（选中集/主题） | `StateFlow` + DataStore 写回 |
| `ref.invalidate` 重试 | UiState 事件 → ViewModel 重新加载 |
| `listenManual`（跨页请求） | `SharedFlow` 收集，进入组合即订阅 |

## 4. 总体排期

原则：**风险先行**。播放链路（P2）是整个移植的技术风险中心，紧随数据基座最先做；UI 主流程（P4）在链路稳定后铺开；JS 插件源、TMDB/推荐/追更等增量能力靠后。

```text
单人排期（约 16 周，88 人日 ±30%）
周    1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
P0    ██
P1       ████
P2          ████████
P3                  ██████
P4                         ████████
P5                                 ██████
P6                                      ████
P7                                         █████
P8                                              ████
```

```text
双人排期（约 10–11 周）：A = 播放/缓存深水区，B = UI/功能面
周    1  2  3  4  5  6  7  8  9 10 11
A: P0 P1  P2──────  P3──── P8(等价性/性能)
B: P0 P1  P4──────  P5──  P6── P7── P8
```

里程碑：

| 里程碑 | 内容 | 单人时点 |
| --- | --- | --- |
| M1 可浏览可搜索 | P1 完成：真实源分类/分页/搜索/详情数据闭环 | 第 3 周末 |
| M2 真机能播 | P2 完成：广告过滤 + 本地代理 + ExoPlayer 全链路真机播放 | 第 7 周末 |
| M3 边下边播 | P3 完成：缓存命中/离线下载/TTL 全路径 | 第 10 周末 |
| M4 功能对齐 | P4–P7 完成：flows 五文档覆盖的 UI 与流程全部可走 | 第 15 周末 |
| M5 可发布 | P8 完成：验收清单全绿、性能达标、签名包产出 | 第 16 周末 |

## 5. 分阶段工作规划表

预估为「熟悉 Flutter 现状与 Android 两端」的单人有效人日；每阶段结束须跑通该阶段验收标准并提交 golden 样本测试。

### P0 工程脚手架与设计 Token（5 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | 决策关闭 | 拍板第 9 节 D0–D6，写入本文档决策记录 | — | 决策表全部有结论 | 0.5 |
| P0-2 | 工程骨架 | `android-native/` Gradle 工程（版本目录 catalog、AGP、K2）、ktlint/detekt（对应 flutter_lints）、CI 跑 analyze+test 对应物 | AGENTS.md 工作流 | 空壳 App 可安装，CI 绿 | 1.5 |
| P0-3 | 设计 Token 落地 | `ui/theme/`：`JiveColors`（DESIGN_SYSTEM §2.1 全 14 色 × 日/夜）、`JiveTypography`（§2.2 六档）、Material3 接入、播放器固定深色色板 | DESIGN_SYSTEM §2；PROTOTYPES §1 | Token 对照表逐项核对通过 | 1.5 |
| P0-4 | 启动壳 | Application/MainActivity、系统 splash 消白闪、品牌 Logo 资源复用、`DoubleBackExitScope` 对应物（双击返回退出）、竖屏默认方向策略 | NAVIGATION_MAP §1、§2 | 冷启动无白闪；双击返回退出 | 1.5 |

### P1 数据基座：模型、网络、源适配（10 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P1-1 | 领域模型 | `core/model/`：`Video`/`VideoRef`/`globalId`/`PlaybackLine`/`VideoPage`/`VodSource`/`WatchRecord`/`Library`/`PlaybackStatus`/`SkipPolicy` 等 13 个模型直译 | `lib/domain/` 全部 | 与 Dart `toJson/fromJson` 字段一一对应（迁移可读老数据） | 1.5 |
| P1-2 | 网络层 | OkHttp 单例：连接 10s/读 15s 超时、请求取消、异常→`VideoDataException` 映射 | ARCHITECTURE §6.3 | 单测覆盖超时/取消/错误转换 | 1 |
| P1-3 | 偏好仓 | DataStore Preferences：主题模式、选中源、TTL、蜂窝下载开关、搜索历史（≤20 去重）；**老版本 SharedPreferences key 迁移表** | USER_FLOWS §6；CACHE_DOWNLOAD §2.3 | 主题三选一即时生效并持久化 | 1 |
| P1-4 | 源注册表 | 远端 JSON 拉取（10s 超时）→ 失败回退本地缓存 → 内置源兜底；`adapterType` 未知源丢弃；选中源持久化 | NAVIGATION_MAP §1；ARCHITECTURE §3.1 | 断网冷启动仍可用 | 1.5 |
| P1-5 | MacCmsV10 Adapter | 分类树/分页/详情/搜索、`vod_play_url` 的 `$$$` 多线路与剧集分隔解析、HTTPS 过滤、`sourceId` 回填 | ARCHITECTURE §3.1/§4.4 | 用真实源样本与 Dart 输出 diff 一致 | 2 |
| P1-6 | 统一仓储 + 内容过滤 | `VideoRepository`（fetchPage/fetchCategories/fetchDetail/search）、详情缓存（globalId 键）、黑名单分类/敏感片名过滤 + 长按开关 | USER_FLOWS §1.1 | 调试页可浏览/搜索/看详情 | 1.5 |
| P1-7 | AGE + Olevod Adapter | AGE JSON API（剧集 URL 为 resolver 句柄）、欧乐 `_vv` 签名 + 直链 HLS | ARCHITECTURE §3.1 | 各自真实源样本对照 | 1.5 |

### P2 播放链路深水区（16 人日）——全项目技术风险中心

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P2-1 | 选线 | `selectionFor`：playbackLines 评分（m3u8>mp4>/play/）、identity 匹配优先于 name/id | PLAYBACK_PIPELINE §1① | Dart 用例直译全过 | 1 |
| P2-2 | URL 解析器 | 已知名式直通；未知格式抓播放页（≤128KB）→ 正则抽候选 → HTTPS 限定 → 评分 → HEAD+512B Range 探测与重定向终 URL；结果 10 分钟缓存；失败按线路静默换线重试 | §1③ | 黄金样本：同一批 URL 两种实现解析结果一致 | 2.5 |
| P2-3 | 格式嗅探 | HEAD Content-Type → Range 文件头魔数，TTL 10 分钟 | §1④ | — | 0.5 |
| P2-4 | HLS 解析器 | master 至多一层变体；不支持标签/SAMPLE-AES/DRM/直播 → `directFallback`；清单模型全量 | §1⑤ | 黄金 m3u8 样本库解析输出 diff 一致（复用 Dart 测试样本） | 2.5 |
| P2-5 | 广告过滤 + 时间轴 | AdFilter v3 删片 + `TimelineMapping`（前后时间轴映射）+ `AdFilterReport`；过滤前后位置换算 | §1⑤⑨ | 换算往返误差 0；报告数据与 Dart 一致 | 2.5 |
| P2-6 | 本地代理 | Ktor CIO 仅 127.0.0.1：随机 token、`buildProxyPlan` 清单改写、Range/分片转发、会话路由注册/注销、无缓存管理器时 `proxyWithoutCaching` | §1⑦；CACHE_DOWNLOAD §1 | Range 请求单测 + 真机播放；并发分片压测无死锁 | 2.5 |
| P2-7 | 播放会话 | `PlaybackSession.prepare` 五态状态机（preparing/streamingAndCaching/cachePlayback/proxyWithoutCaching/direct）+ `PlaybackFallbackReason` 中文文案；offlineOnly 缓存不完整报错不回退 | §1②、§2 | 五种模式可注入测试；降级路径表逐条验证 | 1.5 |
| P2-8 | ExoPlayer 集成 | Media3 封装：initialize 20s 超时 → 关会话换直连重试一次；进度/倍速/暂停恢复；WakeLock 心跳；后台暂停+存进度+回前台恢复 | §1⑧、§3.4 | 真机起播；后台/前台行为对照 | 2 |
| P2-9 | 续播与跳片头 | 历史进度经 TimelineMapping 换算到过滤后时间轴；SkipPolicy（按影片 ≤200 条）自动过片头/片尾跳集 | §1⑨ | 换算单测 + 真机续播落点正确 | 1 |

### P3 缓存与下载（11 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P3-1 | 内容键 | `ContentKeyBuilder`（sourceId+videoId+线路+剧集 identity 哈希）+ 清单 SHA256 指纹、url_normalizer、single_flight | CACHE_DOWNLOAD §2.2 | 与 Dart 哈希值一致（决定老缓存可否复用） | 1 |
| P3-2 | 缓存索引 | 磁盘布局逐字节对齐：`index.json`/`state.json`/`source_manifest.m3u8`/`proxy_manifest.m3u8`/`timeline.json`、原子写 + 刷索引 | §2.1–2.2 | Flutter 版写的条目原生版可读，反之亦然 | 2 |
| P3-3 | 缓存 IO | 资源 sha256 id、扩展名白名单（ts/m4s/mp4/key…）、并发读写 | §2.2 | — | 1.5 |
| P3-4 | CacheManager | 配额（5% 安全余量钳 2–10GB）、WriteLease、引用租约、`initialize`（evictExpired+孤儿清扫）、播放中条目拒删 | §2.1 | 配额边界单测；扫描清理单测 | 2.5 |
| P3-5 | TTL 七档 | never/onExit（兜底 1 天）/1h/5h/1d/3d/7d 按最后访问清扫；旧值迁移 | §2.3 | 每档行为单测 | 0.5 |
| P3-6 | 边播边写 + 预取 | ResourceFetcher 边播边写；SegmentPrefetcher 时间窗（Wi-Fi 300s/蜂窝 120s/可关、并发 5、指数退避、updatePosition 重锚定） | PLAYBACK §1⑥⑩ | 播放中命中缓存路径（蓝点）；预取策略单测 | 1.5 |
| P3-7 | 下载任务管理器 | 状态机全路径（queued/downloading/paused/completed 验收/failed/cancelled/对账不一致→paused+cacheWriteFailed）、`finalizeEntry`、启动对账、`download_tasks.json` | §3.1 | 状态机每条边一个测试 | 1.5 |
| P3-8 | 网络策略 + 磁盘 | Wi-Fi/蜂窝/无网三态 + 蜂窝受限；后台 pauseForBackground/回前台 resume；StatFs 磁盘信息 | §3.2；§4 | NetworkCallback 注入测试 | 0.5 |

### P4 UI 骨架与主流程页面（15 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P4-1 | 路由 + AppShell | Navigation Compose 路由表（= NAVIGATION_MAP §3 导航地图全量）；悬浮胶囊底栏（毛玻璃、宽度钳制 480/600、平板 72 高、追更红点）；三 tab 保活（SaveableStateHolder 对应 IndexedStack，我的页每次进入重建对应 profileRevision）；搜索 tab 预建 + 300ms 延时弹键盘 | NAVIGATION_MAP §2、§3；PROTOTYPES §2.2 | 导航地图每条边可走通 | 2.5 |
| P4-2 | 公共组件 | 三态视图、全局 toast（2s 单条替换）、AlertDialog、bottom sheet（宽 ≤600）、锚定菜单、`VideoCard`（4:5+角标）、`VideoGrid`（2/4 列断点） | PROTOTYPES §14；USER_FLOWS §1.1 | 三种弹层形态与 toast 行为对照 | 2.5 |
| P4-3 | 首页综合流 | 简介头部（长按 Jive 过滤开关、源名▾切源 sheet）、续播条（<2/3 规则/✕ 会话隐藏）、吸顶分类头（feed 行+根/叶子 chips+全部频道入口）、分页网格（400px loadMore/下拉刷新/「新增 N 集」）、回顶钮 | PROTOTYPES §3；USER_FLOWS §1.1/§4 | 逐区块对照线框 §3 | 3 |
| P4-4 | 全部频道页 | 我的频道/全部分类网格、编辑模式（移除/长按拖拽排序/恢复默认）、按源持久化 | PROTOTYPES §6 | Compose 拖拽排序可用 | 1.5 |
| P4-5 | 搜索页 | 防抖 600ms+取消+generation 隔离、最近搜索 chips（单删/清空）、来源标签条（激活/备用/失败红态）、更多来源 sheet（>6 源流量确认、查找全部）、reviewCurrentSource 模式、跨页搜索通道对接 | PROTOTYPES §7；USER_FLOWS §2；NAVIGATION §3.1 | 流程图分支全走通 | 2.5 |
| P4-6 | 详情页 | 头部（海报/元信息/remarks/主演）、操作行（播放+收藏追更四项锚定菜单）、来源区（探测 chips: N集/有资源/0/失败；候选 sheet→确认换源；失败回滚）、简介展开、选集区（正倒序/>100 分组手风琴/平板网格）、选集下载 sheet | PROTOTYPES §8；USER_FLOWS §3 | 换源流程 §3.2 全分支 | 3 |

### P5 播放器 UI 与交互（10 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P5-1 | 两形态容器 | 竖屏窗口（AppBar 双行标题+16:9 面+InfoPanel：跳过设置/简介/选集）；全屏沉浸（锁横屏、immersiveSticky、退出回竖屏）；错误态 `PlayerErrorView`（重新获取并重试） | PROTOTYPES §9.1/9.2；PLAYBACK §3.4 | 形态互转与方向恢复 | 2 |
| P5-2 | 手势层 | 单击/双击/横拖 seek（目标时间预览浮层）/长按右半屏 2 倍速（缓冲不足回退+8s 恢复）/纵拖左亮度右音量 + 指示浮层 | PLAYBACK §3.1 | 手势矩阵逐项验收 | 1.5 |
| P5-3 | 控制条 + 进度条 | PlaybackScrubber（缓冲区段合并绘制/拖动预览）、seek 管线（暂停→seek→校验→恢复→存进度→重锚定、拖动期间冻结时长尺）、按钮行全量（上下集/音量长按静音/铺满/全屏） | PLAYBACK §3.2 | 与现状按钮清单逐项对照 | 2.5 |
| P5-4 | 状态与锁 | 状态圆点（五色）+ 长按详情底栏（降级原因+广告过滤报告）、屏幕锁（锁定后仅解锁钮）、下载当前集（仅 HLS）、倍速菜单、选集菜单 | PROTOTYPES §9.2 表 | — | 2 |
| P5-5 | 自动化行为 | 播完自动连播、片尾 SkipPolicy 跳集、15s 定时+后台存进度、暂停中央大播放键、缓冲菊花 | PLAYBACK §3.4 | — | 1 |
| P5-6 | TV 遥控映射 | OK/左右±10s/上下开关控制条/返回先收控制条/菜单键选集（依 D6 决定首期或延后） | PLAYBACK §3.3 | 遥控器真机验证 | 1 |

### P6 我的、下载管理、设置（7 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P6-1 | 我的页 | 快捷三卡（下载卡进度动画+失败红点/播放源卡副标题/更多）、追更/收藏/最近观看三 tab（徽标、有更新排前、下拉强制检查、全部已读）、历史卡（删除/长按删/清空、直达续播） | PROTOTYPES §10；USER_FLOWS §4/§5 | 逐区块对照线框 §10 | 2 |
| P6-2 | 下载管理页 | 概要行、筛选条、按片分组（下载中自动展开）、任务卡操作（暂停/恢复/重试/取消）、编辑模式批量、点已完成→offlineOnly 播放、AppBar 存储图标进缓存管理 | PROTOTYPES §11；CACHE_DOWNLOAD §3 | 状态机 UI 呈现对照 §3.1 | 2 |
| P6-3 | 缓存管理页 | 用量统计头、清空全部（确认）、条目单删（播放中拒删 toast） | PROTOTYPES §12 | — | 0.5 |
| P6-4 | 设置两页 | 更多设置（主题/预加载开关/蜂窝下载确认/自动清理 7 档/播放缓存入口）；来源管理（资源站/高清站双 Tab、检测全部 8s 测速持久化、点击设默认+toast） | PROTOTYPES §13；USER_FLOWS §6 | — | 1.5 |
| P6-5 | 离线续播串接 | `resume_watch`：完整离线缓存优先 → offlineOnly 起播；离线进度仓（≤100 条）与在线历史隔离；已播完 ≥95% 跳下一集 | CACHE_DOWNLOAD §4；USER_FLOWS §4 | 三分支全走通 | 1 |

### P7 策展、推荐与追更（8 人日）

| 编号 | 任务 | 内容与产出 | 对齐现状 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- | --- |
| P7-1 | 追更检查 | 30 分钟间隔+前台触发、单轮 ≤50 条、每源并发 3、剧集版本签名对比、未读徽标（底栏红点/tab 徽标） | USER_FLOWS §5 | 触发/对比/徽标单测 | 2 |
| P7-2 | 收藏库 | `content_library_v2` 串行队列写入、快照剥离剧集列表、isFavorite/isFollowing、四项菜单语义 | USER_FLOWS §5 | — | 1 |
| P7-3 | TMDB 榜单流 | Catalog 仓（ETag+快照）、固定卡位+流式 VOD 匹配、共享搜索池去重、范围 chips、footer（统计/重试失败项/继续加载）、不可播三选项对话框 | PROTOTYPES §4；USER_FLOWS §1.3 | 对照线框 §4 | 2.5 |
| P7-4 | 猜你喜欢流 | 后端 LLM 候选（personalized/coldStart）→ VOD 匹配两阶段、匹配中槽位、不可播区三选项、阶段进度卡与统计 | PROTOTYPES §5；USER_FLOWS §1.2；recommendation/ 契约 | 接口行为与 Dart 客户端一致 | 2 |
| P7-5 | 更新检查 | App 更新检查（仅 Android）+ 更新弹窗 + 外部浏览器下载 | NAVIGATION_MAP §1；hot-update 文档 | — | 0.5 |

### P8 等价性验收、性能与发布（6 人日）

| 编号 | 任务 | 内容与产出 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- |
| P8-1 | 等价性走查 | 附录 A 清单全量走查（对照 flows 五文档逐条） | 清单全绿 | 1.5 |
| P8-2 | 异常专项 | 弱网/断网/进程被杀恢复（下载对账、缓存孤儿清扫）、连续进出播放器资源释放 | ARCHITECTURE §11.7–8 | 1 |
| P8-3 | 性能对比 | 冷启动、起播耗时（点击→出画）、长列表滚动帧率、内存峰值，与 Flutter 版同机对比记录 | 不差于 Flutter 版 ±10% | 1.5 |
| P8-4 | 发布工程 | R8/混淆规则（QuickJS/serialization keep）、签名、包名与版本策略（D1）、灰度分发 | 产出可安装 release 包 | 1 |
| P8-5 | 数据迁移（可选） | 老 App → 新 App：SharedPreferences key 映射 + JSON/缓存目录直接继承（依 D1 决定是否做） | 升级安装后历史/收藏/追更/下载完整 | 1 |

## 6. 数据与双版本共存

- **磁盘格式对齐是本规划的核心策略**：P1/P3 的模型与缓存实现按「与 Flutter 版逐字节一致」验收，使两版 App 可读写同一批本地数据，也让 Flutter 侧 73 个测试中的数据层用例可直接转化为 golden 样本。
- **迁移路径（D1）**：推荐同仓 `android-native/` + 新包名（如 `com.jive.app.native` 二选一）+ 新版本号从 2.0.0 起；若采用「覆盖安装迁移」，需做 P8-5（读取老包 SharedPreferences 需要相同包名或 backup 规则，实现成本见任务）。
- **Flutter 版冻结策略**：移植期间 Flutter 版只做 P0 级 bugfix，不加功能，避免对齐目标漂移。

## 7. 测试与等价性验证策略

1. **黄金样本对照（最重要）**：把 Dart 侧测试使用的真实 m3u8/播放页/接口响应样本固化为共享 fixture，同一输入下比对 Dart 与 Kotlin 的解析输出（HLS 清单模型、AdFilter 删除决策、TimelineMapping、ContentKey 哈希、URL 解析候选）。P2–P3 每个任务验收都以「diff 一致」为标准。
2. **单测**：`lib/data` 对应的核心逻辑测试在 Kotlin 侧等价重建（播放链路、缓存索引、下载状态机、内容键、TTL、过滤策略），JUnit + coroutines-test。
3. **UI 验证**：Compose 语义测试覆盖关键交互（手势矩阵、控制条、批量编辑）；页面视觉以 PROTOTYPES 线框逐区块人工核对，不追求像素级复刻。
4. **真机巡检**：对应 Flutter 侧「官网截图巡检集成测试」，建立 androidTest 驱动真实源走通 浏览→搜索→播放→下载 冒烟链路。

## 8. 风险清单

| # | 风险 | 等级 | 预案 |
| --- | --- | --- | --- |
| R1 | 播放链路等价性（广告过滤/时间轴/降级路径行为漂移） | 高 | P2 最早启动；黄金样本 diff；flows/PLAYBACK_PIPELINE §2 降级路径表逐条真机验证 |
| R2 | 本地代理稳定性（Range/并发分片/半途断连收尾） | 高 | Ktor CIO 选型验证放 P2-6 首日 spike；压测脚本（并发 50 分片请求）；在途读 ≤2s 收尾语义对照 |
| R3 | QuickJS 桥与 flutter_js 行为差异（`$http`/`$next` 语义） | 中 | 适配层接口 P1 先定；JS adapter 排最后批次（P1-8 之后的独立小任务），其余三 adapter 先行 |
| R4 | 后端接口行为差异（TLS 指纹/Header/超时策略） | 低-中 | 网络层超时/Header 与 Flutter 版对齐；P7 联调真机验证 |
| R5 | TTL/LRU 清理差异导致误删离线内容 | 中 | 配额与清扫策略单测边界覆盖；黄金样本含「下载完成后被 TTL 波及」用例 |
| R6 | Compose 长列表/毛玻璃性能（分类吸顶 + 流式追加网格） | 中 | P4-3 用 baseline profile + 流式分页（`Paging` 不强制，保持手写 loadMore 语义）；P8-3 帧率对比 |
| R7 | 双端并行导致对齐目标漂移 | 中 | Flutter 版冻结（§6）；flows 文档作为唯一事实来源，行为变更必须先改 flows 再改码 |
| R8 | 单点开发知识集中（播放链路仅 1 人理解） | 中 | P2 产出对照笔记（每步与 Dart 文件行级映射），沉淀进 `doc/native-android/` |

## 9. 待拍板决策点

| # | 决策 | 选项 | 推荐 | 影响 |
| --- | --- | --- | --- | --- |
| D0 | 双端策略 | ① Android 原生 + iOS 维持 Flutter ② 原生版为唯一 App，Flutter 弃维护 | ① 起步，视原生版质量再定 | 决定 Flutter 冻结力度与排期 |
| D1 | 仓库/包名/迁移 | ① 同仓 `android-native/`，新包名，不做覆盖迁移 ② 同仓同包名，做 P8-5 覆盖迁移 | ①（P8-5 悬置） | P8-5 是否执行；发布渠道 |
| D2 | 本地代理实现 | Ktor CIO / NanoHTTPD / 自写 ServerSocket | Ktor CIO | P2-6 技术底座，P2 首日 spike 验证 |
| D3 | JS 插件源时机 | ① 首期对齐（P7 后加 P7-6）② 原生版先不载 Syncnext 源，注册表过滤 `syncnext_plugin` | ①，若 QuickJS 桥顺利则顺延进首期 | 注册表已按 adapterType 过滤未知源，② 成本为零 |
| D4 | 存储 | JSON 文件对齐（推荐）/ Room 重构 | JSON 对齐 | 迁移与等价性成本 vs 长期查询能力 |
| D5 | 路由 | Navigation Compose 类型安全路由（修 NAVIGATION_MAP §5.1 债） | 采纳 | P4-1 多 0.5 人日，为深链/TV 焦点记忆铺路 |
| D6 | TV 适配范围 | ① 首期含遥控键映射（P5-6，1 人日）② 延后 | ①（成本极低，ExoPlayer 键事件天然支持） | P5-6 去留 |
| D7 | 猜你喜欢后端 | 沿用现行 LLM 推荐后端契约（recommendation/ 文档） | 沿用 | P7-4 直接对接，无后端改动 |

## 附录 A 功能对齐验收清单（发布门槛）

- [ ] 启动：源注册表未就绪不出首页、断网可用本地缓存兜底、无白闪（NAVIGATION_MAP §1）
- [ ] 三 tab 保活与「我的」进入重建刷新、追更红点（NAVIGATION_MAP §2）
- [ ] 首页三种 feed：综合分页/推荐两阶段/榜单固定卡位，含各自 footer 与不可播三选项（USER_FLOWS §1；PROTOTYPES §3–5）
- [ ] 全部频道页编辑：移除/拖拽/恢复默认/按源持久化（PROTOTYPES §6）
- [ ] 搜索：防抖、最近搜索 ≤20、多源标签条、更多来源 sheet、>6 源流量确认、reviewCurrentSource（USER_FLOWS §2）
- [ ] 详情：播放/收藏追更四项菜单/换源两步+失败回滚/选集 >100 分组/下载 sheet（USER_FLOWS §3）
- [ ] 播放十步流水线全走通；五态模式与降级原因文案一一可触发（PLAYBACK_PIPELINE §1–2）
- [ ] 手势矩阵六项 + seek 管线 + 时长尺冻结（PLAYBACK_PIPELINE §3.1）
- [ ] 控制条按钮清单全量 + 状态圆点长按详情 + 屏幕锁 + TV 键映射（PLAYBACK_PIPELINE §3.2–3.3）
- [ ] 自动连播/片尾跳集/15s 存进度/后台暂停恢复/横竖屏与资源释放（PLAYBACK_PIPELINE §3.4）
- [ ] 缓存：配额钳制、磁盘布局逐字节对齐、TTL 七档、播放中拒删（CACHE_DOWNLOAD §2）
- [ ] 下载：状态机全边、蜂窝受限、后台暂停恢复、启动对账、离线播放 offlineOnly（CACHE_DOWNLOAD §3–4）
- [ ] 续播：首页续播条 <2/3 规则、离线优先、≥95% 跳下一集（USER_FLOWS §4）
- [ ] 追更：30min 前台检查、并发 3、未读徽标、全部已读（USER_FLOWS §5）
- [ ] 设置与来源管理：主题三选一、TTL 七档、测速设默认（USER_FLOWS §6）
- [ ] 宽屏断点 ≥600dp 五处差异（PROTOTYPES §14.3）
- [ ] 双击返回退出、App 更新弹窗（NAVIGATION_MAP §2；hot-update 文档）
