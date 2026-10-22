# 导航地图：启动链路与页面跳转骨架

状态：持续生效（基于 v1.1.0+5）
相关文档：[README.md](README.md)、[USER_FLOWS.md](USER_FLOWS.md)、[PROTOTYPES.md](PROTOTYPES.md)

## 1. 启动链路

```text
main.dart
  │ WidgetsFlutterBinding.ensureInitialized()
  │ 读取持久化主题模式(theme_mode_preferences.dart → loadThemeMode)
  │ 设置透明状态栏
  ▼
runApp(ProviderScope(JiveApp))          # app.dart
  │ MaterialApp(亮/暗双主题, themeMode 由 themeModeProvider 驱动)
  │ home = _StartupGate（无命名路由，唯一 home）
  ▼
_StartupGate 监听 selectedVodSourceProvider（片源注册表就绪状态）
  │
  ├─ loading ──────────────► SplashPage（features/splash/splash_page.dart）
  │
  ├─ error ────────────────► AppErrorView（错误页）
  │                            重试 = ref.invalidate(vodSourceRegistryProvider)
  │
  └─ data(源就绪) ─┬─ 未满最短停留 ──► SplashPage
                   └─ 满足条件 ─────► AppShell（主框架）
```

- 最短闪屏时长：`splashMinHold = 800ms`（`splash_page.dart`）；系统关闭动画（`MediaQuery.disableAnimationsOf`）时跳过等待直接进首页。
- 启动闸门的意义：源注册表来自远端 JSON（10s 超时，失败回退本地缓存），必须先就绪才能浏览；闸门保证不会 pop 回闪屏。
- **AppShell 就绪后的首帧副作用**（`app.dart` `_AppShellState.initState`）：
  1. App 更新检查（仅 Android，非 web）：`app_update_service.dart` → 有新版弹 `showAppUpdateDialog`；
  2. 追更检查：`favoriteControllerProvider.checkForUpdates()`。
- **下载生命周期**（`_DownloadLifecycle` 包裹 MaterialApp）：App 进后台 → 下载管理器 `pauseForBackground()`；回前台 → `resumeFromForeground()` + 再次追更检查。

## 2. AppShell 骨架

底部为**悬浮胶囊导航栏**（毛玻璃 BackdropFilter，非贴边 TabBar），主体为 `IndexedStack` 保活三个 tab：

| Tab | 页面 | 保活策略 | 备注 |
| --- | --- | --- | --- |
| 0 首页 | `HomePage` | 启动即建、常驻 | 挂 `active` ValueNotifier，离开 tab 时可暂停刷新类工作 |
| 1 搜索 | `SearchPage` | 启动**预建**（把首切开销挪到启动阶段，避免切 tab 卡顿） | 注入共享 `_searchFocusNode` |
| 2 我的 | `ProfilePage` | **每次进入重建**（`profileRevision` 自增作 key），保证下载数/徽标等刷新 | 追更有未读时图标带红点（`unreadFollowUpdateCountProvider > 0`） |

布局与行为细节：

- `extendBody: true`：页面内容延伸到底栏之下，底栏悬浮其上；首页态底栏毛玻璃更通透，其他页提高不透明度防干扰。
- 底栏宽度钳制：横屏 ≤600、竖屏 ≤480，居中；平板（最短边 ≥600）高度 72、图标字号放大。
- 切到搜索 tab 后延时 300ms 弹起键盘（等切换动画结束，避免与首帧抢资源）。
- Android 根页包 `DoubleBackExitScope`：双击返回退出应用。

## 3. 全局导航地图

```text
SplashPage / 启动错误页
└─ AppShell（IndexedStack + 悬浮底栏 ── 页面栈根，永不 pop）
   ├─ Tab0 首页 HomePage
   │    ├─ 点视频卡 / 榜单卡 ──────push──► VideoDetailPage(video)
   │    ├─ 分类栏「全部频道」图标 ──push──► CategoryChannelsPage(
   │    │                                    roots/children/myChannelIds/当前选中,
   │    │                                    回调 4 个: 选根分类/选子分类/保存我的频道/关闭)
   │    │                                  ◄──pop── 选定后带回首页
   │    ├─ SourceIndicatorButton(源名▾) ──sheet──► SourceSelectorSheet（全局切源）
   │    └─ 不可播槽位对话框「查看搜索结果」──► searchLaunchRequestProvider
   │                                           （跨页请求，AppShell 监听后切 tab）
   ├─ Tab1 搜索 SearchPage
   │    └─ 点结果卡 ────────────────push──► VideoDetailPage(video)
   ├─ Tab2 我的 ProfilePage
   │    ├─ 快捷卡「下载」────────────push──► DownloadManagementPage
   │    ├─ 快捷卡「播放源」──────────push──► SourceManagementPage
   │    ├─ 快捷卡「更多」────────────push──► MoreSettingsPage
   │    ├─ 追更/收藏卡 ─────────────push──► VideoDetailPage
   │    └─ 最近观看卡 ──resumeWatchRecord──► PlayerPage（不经过详情页直达续播）
   │
   ├─ VideoDetailPage（详情，features/detail/detail_page.dart）
   │    ├─ 播放按钮 / 剧集 chip ────push──► PlayerPage(video, episode
   │    │                                    [, selection, resumePosition,
   │    │                                     episodeSelections, …])
   │    │                                   ◄──pop(Episode)── 同步详情页选中集
   │    ├─ AppBar 下载图标 ──sheet──► 选集下载 sheet ──确认──► 入队下载
   │    │                             └─ sheet 内「下载管理」─push─► DownloadManagementPage
   │    └─ 来源区「更多▾」──sheet──► DetailMoreSourcesSheet / 候选列表 sheet
   │                                   （选定候选 → 确认对话框 → 换源重载详情）
   ├─ PlayerPage（播放器，全屏沉浸 / 竖屏窗口两形态）
   │
   ├─ DownloadManagementPage（下载管理）
   │    ├─ AppBar 存储图标 ─────────push──► CacheManagementPage
   │    └─ 点已完成任务 ────────────push──► PlayerPage(offlineOnly: true)
   ├─ MoreSettingsPage（更多设置）
   │    └─ 「播放缓存」──────────────push──► CacheManagementPage
   ├─ CacheManagementPage（播放缓存管理，无下级 push）
   └─ SourceManagementPage（来源管理：设默认源、测速，无下级 push）
```

### 3.1 特殊导航通道（不走 Navigator.push）

| 通道 | 机制 | 用途 |
| --- | --- | --- |
| 跨页搜索请求 | Riverpod 状态 `searchLaunchRequestProvider`（`search_launch_request.dart`），AppShell `listenManual` 监听 | 首页不可播槽位「查看搜索结果」→ 切到搜索 tab 并带关键词/源；带 keyword/sourceId/mode |
| 播放器返回值 | `Navigator.pop<Episode>(episode)` | 详情页据此同步「当前选中集」高亮 |
| Tab 保活重建 | `profileRevision` ValueKey | 我的页每次切入重新 build，刷新下载进度/追更徽标，无需事件总线 |
| 全局切源 | `selectedVodSourceProvider` 持久化 + 监听 | 首页头部源名按钮弹 sheet 选择后，各页面响应式跟随 |

## 4. 路由与弹层方式盘点

- **路由**：无命名路由、无 go_router。页面间全部 `Navigator.of(context).push(MaterialPageRoute(...))`；tab 切换走 IndexedStack 状态而非路由。影响：页面栈即 push 顺序，无路由表可查（本文件第 3 节即事实上的路由表）；深链/外部唤起目前无统一入口。
- **弹层三种模式**（全 app 统一）：
  | 模式 | 组件 | 用途举例 |
  | --- | --- | --- |
  | bottom sheet | `showModalBottomSheet`（宽 ≤600 居中） | 选源、选集下载、换源候选、更多来源、倍速外的大部分选择 |
  | AlertDialog | `showDialog` | 确认类：清空历史、蜂窝下载确认、流量确认、删除确认 |
  | 锚定菜单 | `app_anchored_menu.dart`（在控件下方展开、越界钳制） | 收藏/追更四项菜单、跳过片头秒数 |
- **轻提示**：`app_toast.dart` 全局居中 toast（2 秒自消、单条替换、无 action 时点击穿透）。

## 5. 改版观察（供规划参考）

1. **无路由表**：全部 MaterialPageRoute 硬编码 push，页面间参数为位置参数；若引入深链（通知点播、外部唤起、TV 焦点记忆）需先建立路由层。
2. **「我的」页整页重建**：切入即重建整棵子树（profileRevision），列表多时可能有可感知开销；改为局部刷新是潜在优化点。
3. **特殊通道分散**：跨页搜索（Provider）、播放器返回值（pop 带值）、tab 重建（key）三种「页面间通信」机制并存，改版时可考虑统一。
4. **弹层规范已统一**（sheet/对话框/锚定菜单/toast 四件套），改版新增交互时应沿用而非引入新弹层形态。
