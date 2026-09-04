# Jive 项目简介

> 一个无需自建后端的 Flutter 视频点播（VOD）客户端：直连第三方资源站，把「多源聚合、边播边下、广告过滤」这类通常只有成熟播放器才有的能力，做到了一个纯客户端 MVP 里。

- **平台**：Android / iOS / macOS（Android 6.0.1 API 23 起兼容），另有 Android TV 最小适配分支
- **技术栈**：Flutter 3.32+ / Dart 3.8、Riverpod 3、`video_player`、`flutter_js`
- **架构**：Feature-first + 轻量 Clean Architecture + Riverpod
- **后端**：零后端。列表、搜索、详情直连 VOD API；源配置支持远端下发 + 本地缓存 + 内置资产三级回退

---

## 1. 它是什么

Jive 是一个面向移动端的影视聚合播放器。用户在一个 App 内浏览多个第三方资源站（MacCMS、AGE 动漫、欧乐高清、Syncnext 插件源等），完成搜索、选集、播放、缓存、下载、续播的完整闭环。首页常驻一个 Flutter 官方演示视频，保证播放链路在任何外部服务不可用时仍可独立验收。

典型使用路径：

```text
首页（分类/频道/续播条） → 搜索（多源聚合） → 详情（跨源探测/选集/收藏）
   → 播放器（边播边下/广告过滤/手势控制） → 离线续播
```

---

## 2. 亮点功能

### 2.1 多 VOD 源聚合架构

- **Adapter 协议抽象**：`VodSourceRegistry + VodSourceAdapter` 统一接入异构资源站，已支持 MacCMS V10 JSON、AGE 自研 JSON 协议（age_v2）、欧乐 HTML 抓取 + `_vv` 签名直链（olevod_v1）、Syncnext JS 插件（syncnext_plugin）四类协议。
- **在设备上跑第三方 JS 插件**：基于 `flutter_js` 实现通用 JS 插件运行时，桥接 `$http` / `$next` / Cookie，直接加载社区 Syncnext 插件的 `config.json + files`，无需为每个插件源写 Dart 代码。
- **三级切源体验**：
  - 全局浏览源：首页标题区切换，持久化，分类与列表重建；
  - 搜索页局部切源：1 个当前源 + 最多 3 个备用源**并发自动探测**，来源标签展示准确/估算数量与失败状态，"更多"按需请求；
  - 详情页局部切源：默认只请求当前源，点击"检测其他来源"才并发探测，跨源候选确认后**原子切换、失败回滚**，保留当前选集。
- **资源身份隔离**：`globalId = sourceId:sourceVideoId`，缓存、收藏、历史、播放器重试全部按源绑定，不同源的相同 `vod_id` 互不冲突；旧本地数据自动迁移。

### 2.2 本地代理 + 边播边下（类迅雷/流媒体 CDN 思路）

- App 内启动**本地回环 HTTP 代理**（`LocalProxyServer`），播放器请求 `localhost`，代理按 token 路由转发 manifest 与分片，从而把"播放"和"缓存/下载"收敛到同一条数据通路。
- **HLS manifest 代理改写**：解析 m3u8、重写分片地址，判定可缓存性（`HlsDecision`）。
- **统一缓存核心**：`CacheManager` 负责磁盘配额计算、**LRU + TTL 双维度淘汰**、引用计数 `CacheRef` 与写租约 `WriteLease`；读穿/写穿 + **SingleFlight 在飞请求去重**，并发拉同一分片只发一次网络请求。
- **稳定缓存寻址**：`ContentKey` 用「源+视频+线路+剧集」身份做 sha256 寻址；`url_normalizer` 剔除 URL 时效签名参数，带签名的过期链接仍命中缓存。
- **智能预取**：`SegmentPrefetcher` 边播边并发预取分片，指数退避、预取窗口随播放位置重锚定；预取策略区分 Wi-Fi / 蜂窝，可在设置中开关。

### 2.3 HLS 广告过滤（adfilter-v3）

- 自研广告分片识别算法：**夹心中插检测 + 节奏侏儒（rhythm-dwarf）识别**，输出 `AdFilterReport`。
- 过滤后重写 m3u8，在广告缝保留 `DISCONTINUITY` 并去掉 PDT 空洞，避免播放器时间轴跳变。
- **TimelineMapping** 负责源时间轴 ↔ 过滤后时间轴双向换算；配合"冻结 seek 时钟 + 断点吸附重试"，解决广告时段拖动进度被放大的问题。
- 播放状态圆点实时展示当前链路（边播边下/缓存命中/代理/直连），长按查看过滤详情。

### 2.4 显式下载与离线播放

- `DownloadTaskManager` 下载引擎：任务持久化、**并发许可池、暂停/恢复/断点续下**、速度采样。
- 下载产物即缓存条目，复用 playback 的解析能力与 cache 的配额管理；离线时续播优先走本地。
- 下载管理页支持任务筛选、批量暂停/删除、磁盘容量展示（原生 `MethodChannel` 读磁盘空间）。

### 2.5 播放器体验

- 完整播放控制：播放/暂停、上下集、倍速、选集、全屏、横竖屏切换、连播；失效地址"重新获取并重试"。
- **手势层**：单击/双击、横滑 seek、**长按 2 倍速**、纵滑调亮度/音量；播放页亮度调节与屏幕常亮（`screen_brightness` / `wakelock_plus`）。
- **可拖动预览进度条**：自绘 `PlaybackScrubber`，合并展示缓冲区间；seek 稳定时钟防止广告断点处落点漂移。
- **跳过片头/片尾**：按影片记忆跳过时长（30/60/90/自定义，默认关闭），详情页与非全屏播放器共用。
- 播放状态机完整覆盖 idle / loadingUrl / initializing / playing / paused / buffering / completed / error / disposed，处理后台切换、地址过期、资源释放。
- 进度持久化策略：每 5–10 秒、暂停、退出、完播时保存，不逐帧写盘。

### 2.6 内容与个性化

- **首页两级分类导航 + 自定义"我的频道"**：频道集合与顺序按来源持久化，支持拖拽排序（`reorderable_grid_view`）、编辑增删。
- **敏感内容过滤**：分类黑名单 + 内容过滤总开关（默认开启，长按首页标题可切换）。
- 收藏、观看历史（双 tab 网格）、搜索历史（去重、最多 20 条）、首页续播条（剧集完播仍挂、电影过 2/3 不挂）。
- 搜索防抖（600ms）、generation 隔离旧请求、空关键词不请求。

### 2.7 多端适配

- **手机 / 平板（iPad）**：自适应视频网格（两列/四列）、详情页平板布局（加大封面、剧集等宽网格）。
- **Android TV 最小适配**：leanback 入口、完整遥控器焦点体系（确定性方向导航、焦点描边）、TV 播放控制层与按键映射；经 `jive/device` MethodChannel 识别设备。
- **macOS 桌面端**已可运行。
- **Android 6 兼容**：向安全上下文追加内置 ISRG Root X1 证书，老设备也能建立现代 TLS 连接。

### 2.8 工程化与质量

- **测试覆盖数据与播放核心逻辑**：`test/` 镜像 `lib/`，覆盖 Adapter（含 JS 插件运行时）、HLS 解析、广告过滤、缓存淘汰/索引/IO、下载任务管理、控制器与共享组件。
- 分层约束严格：页面不直接出现 `http.get` / `SharedPreferences.getInstance`，全部经 Riverpod Provider → Repository → Adapter。
- 完善的文档体系：架构总纲、逐文件代码地图（CODEBASE_MAP）、设计系统规范、缓存/多源/投屏/TV 等专题方案与归档验收文档。

---

## 3. 技术栈一览

| 领域 | 选型 | 说明 |
| --- | --- | --- |
| 框架 | Flutter 3.32+ / Dart 3.8 | Android/iOS/macOS，Android 6+ 兼容 |
| 状态管理 | `flutter_riverpod` 3.x | 手写 Provider，未用 codegen；AsyncNotifier 承载列表/搜索/详情 |
| 视频播放 | `video_player` | HLS/MP4/DASH 格式嗅探（HEAD content-type + 魔数回退） |
| JS 运行时 | `flutter_js` | 设备端执行 Syncnext 社区插件 |
| 网络 | `http` | 按需请求；本地回环代理承接播放流量 |
| 本地存储 | `shared_preferences` + 文件系统 | 收藏/历史/配置；缓存分片走磁盘文件 + state.json 索引 |
| 图片 | `cached_network_image` | 封面缓存，统一 URL 规范化与请求头 |
| 设备能力 | `screen_brightness`、`wakelock_plus`、`connectivity_plus`、`path_provider` | 亮度、常亮、网络状态、目录 |
| 其他 | `crypto`（ContentKey sha256）、`reorderable_grid_view`（频道排序） | |

> 刻意未引入：`dio`（网络层保持轻量）、`go_router`（仍为命令式 Navigator）、`freezed`/`json_serializable`（模型手写序列化，含容错迁移）。

---

## 4. 架构与数据流

```text
页面 Widget
  ↓
Riverpod Provider / Notifier（状态编排）
  ↓
VideoRepository（内容门面，按 adapterType 分发）
  ↓
VodSourceRegistry → VodSourceAdapter（按 sourceId 选择协议实现）
  ↓
VOD API / 本地存储
```

播放链路独立成体系：

```text
PlayerPage → PlaybackSession（解析 manifest、注册代理路由、挂缓存写穿与分片预取）
              ├─ LocalProxyServer（本地回环代理）
              ├─ HlsParser + AdFilter（改写/过滤 m3u8）
              ├─ CacheManager（LRU/TTL、SingleFlight、配额）
              └─ SegmentPrefetcher / DownloadTaskManager（预取与下载）
```

目录划分：`lib/domain`（纯模型）、`lib/data`（`vod_source/`、`content/`、`playback/`、`cache/`、`download/`）、`lib/features`（每页一目录）、`lib/shared`（复用组件）、`lib/tv`（TV 适配）。

---

## 5. 快速开始

```bash
flutter pub get
flutter run            # 连接设备或模拟器
flutter test           # 全量单元/组件测试
flutter analyze        # 静态检查
flutter build apk      # Android APK
```

VOD 源列表位于 `config/vod_sources.json`（不纳入 git，仓库自带示例），支持远端配置优先、远端缓存、内置资产三级加载；仅放行启用的 HTTPS 源。

> 第三方 VOD 内容与播放源在正式发布前须完成授权与平台合规确认。

---

## 6. 演进方向

- **V1.2 后端**：VOD 源目录、远程配置下发，可选邮箱注册/登录（见 `doc/backend/`）。
- **投屏**：Cast / DLNA / AirPlay 路线对比与分期方案已备（`doc/cast/`），待电视型号确认后启动 P0 验证。
- **TV 适配**：焦点体系与播放按键映射已完成，待真机实测。
- 自建后端接入时仅需替换 Data Source / Repository 实现，页面与播放器业务层不受影响。
