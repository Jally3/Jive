# 闪屏页开发技术书

状态：**开发中**。目标：冷启动用夜幕底 + **Logo 与「Jive」词标**接住引擎首帧与源加载，消除系统白屏与整页转圈。不引入开屏广告、登录或引导。

相关文档：[`../design/DESIGN_SYSTEM.md`](../design/DESIGN_SYSTEM.md)（夜幕影院 Token）、[`../archive/mvp/APP_REQUIREMENTS_V1.md`](../archive/mvp/APP_REQUIREMENTS_V1.md)（页面结构含启动页）、[`../codebase/CODEBASE_MAP.md`](../codebase/CODEBASE_MAP.md)（落地后同步文件地图）。

## 1. 背景与目标

V1 页面结构以「启动页 → 首页」为根，但当前冷启动是两段空白：

| 阶段 | 现状 |
|---|---|
| 进程起来、Flutter 首帧前 | Android `launch_background.xml` / iOS `LaunchScreen.storyboard` 为**白底** |
| 首帧后、源未就绪 | `JiveApp` 对 `selectedVodSourceProvider` 的 `loading` 画整页 `CircularProgressIndicator` |
| 源就绪 | `AppShell` |

产品要求闪屏展示 **Logo + 「Jive」**。Logo 沿用现有应用图标（新月 + 播放键，母图 `tool/app_icon_source.png`），词标与首页标题同一套字体层级。

## 2. 目标与非目标

### 目标（In Scope）

- 原生启动图与 Flutter 闪屏底色均为 `AppColors.background`（`#0B0D10`），冷启动不闪白。
- Flutter 闪屏居中展示 **Logo** 与 **「Jive」**；源加载期间用轻量指示，不抢品牌。
- 源就绪且满足最短展示后进入 `AppShell`，不能 pop 回闪屏。
- 源失败仍用现有 `AppErrorView` + 重试，不卡死在品牌页。
- 手机 / iPad / TV 同一套布局，不锁方向。

### 非目标（Out of Scope）

- 开屏广告、跳过倒计时、运营图。
- 引导页、登录、权限申请。
- Lottie / 复杂动效；不引入 `flutter_native_splash`。
- 在闪屏预拉首页列表（避免和首页自己的加载抢请求）。
- TV 专属闪屏或单独构建变体。

## 3. 功能需求

### FR-1 原生启动层（消白闪）

Flutter 引擎画出第一帧前，由系统窗口背景承担。

- Android：`drawable/launch_background.xml` 与 `drawable-v21/launch_background.xml` 的色层改为 `#0B0D10`（抽到 `values/colors.xml` 的 `splash_background`，与 `AppColors.background` 同值）。
- Android：`LaunchTheme` 与 `NormalTheme` 的 `android:windowBackground` 都指向该 drawable，避免引擎起来后窗口仍是系统浅色。
- iOS：`LaunchScreen.storyboard` 根视图背景改为 `#0B0D10`。
- **原生层不放 Logo、不写「Jive」**。原因：原生启动图把 Logo 单独居中，Flutter 首帧改成「Logo + 词标」垂直组居中时，Logo 会向上跳。纯色底最稳，品牌由 Flutter 首帧一次画齐。

### FR-2 Flutter 闪屏页（Logo + Jive）

新增 `lib/features/splash/splash_page.dart`，作为源闸门期间的 `home`。

**构图（垂直居中一组，水平居中）：**

```text
        [ Logo ]
           16
         Jive
        （可选 slogan，本版不做）
              ·
              ·
    底部轻量加载指示（距底 48 + 安全区）
```

| 元素 | Token / 规格 | 说明 |
|---|---|---|
| 页背景 | `background` `#0B0D10` | 与原生启动图同色 |
| Logo | 见 §5 资源 | 现有 App Icon 图形；**不要**再套一层圆角方底，避免双层夜幕块 |
| Logo 边长 | 手机 96pt；`shortestSide >= 600` 为 120pt | 4pt 网格 |
| Logo ↔ 词标间距 | 16 | `pagePadding` |
| 「Jive」 | `display` 28 / 36、字重 700、`text` `#F5F7FA` | 与首页标题同一写法 |
| 加载指示 | 18pt `CircularProgressIndicator`，色 `accent`，stroke 2 | 贴底部，不挡品牌 |
| 动效 | 进入 `AppShell` 可用 200ms fade；尊重「减少动态效果」则直接切 | 不做缩放、视差 |

- Slogan「今晚，看点好内容」本版**不**上闪屏，避免和首页重复抢词；若后续要加，用 `body` 15 + `secondary`，距词标 8pt。
- 禁止在 Widget 里写十六进制；颜色走 `AppColors`。
- 无障碍：`Semantics(label: 'Jive')` 包住 Logo+词标；加载指示 `label: '正在启动'`。

### FR-3 进入与离开

```text
原生 Launch（#0B0D10）
        ↓ 引擎首帧
SplashPage（Logo + Jive + 轻加载）
        ↓ 源就绪 且 已满最短展示
AppShell（IndexedStack 首页壳）
        ↓ 源失败
AppErrorView（重试 → 回到等待源，再进 AppShell）
```

- **最短展示**：800ms，从 `SplashPage` 首次 insert 起算。源已在本地缓存时也不会一闪而过。
- **离开条件**：`selectedVodSourceProvider` 为 `data` **并且** 满 800ms。用 `Future.wait([minHold, source.future])` 或等价逻辑；不要轮询。
- **失败**：`error` 时换现有错误页，不展示品牌闪屏当错误页。重试 `invalidate(vodSourceRegistryProvider)`，期间回到闪屏。
- **导航**：`JiveApp.home` 按状态切换 Widget，**不要** `push` 闪屏路由，避免返回键回到闪屏。
- 现有 `selectedVodSourceProvider` 仍是进首页的唯一业务闸门；闪屏不改源加载顺序。

### FR-4 设备

- 手机竖屏、iPad、TV 横屏共用一页；`Column` + `MainAxisAlignment.center`。
- 不在闪屏调用 `setPreferredOrientations`。
- TV：闪屏无可聚焦控件；失败页的「重试」保持可聚焦（`AppErrorView` 已有）。

## 4. 非功能需求

- 不增加启动路径上的网络请求。
- 同一 APK 覆盖手机与电视，无闪屏构建变体。
- Logo 资源随包体积：一张 3x PNG（建议最长边 360px）即可，由 Flutter 按 DPR 缩放。
- 首帧前不依赖 Flutter 资源解码失败：原生是纯色；Logo 解码失败时词标仍在，Logo 位用 `surfaceElevated` 方块占位（规范：失败不破图、不白底）。

## 5. 资源与品牌

### 5.1 Logo 来源

| 文件 | 用途 |
|---|---|
| `tool/app_icon_source.png` | 图标母图（新月 + 播放键，透明圆角） |
| `tool/app_icon_master.png` | 1024 方图，由 `tool/generate_app_icon.py` 生成 |
| `assets/branding/splash_logo.png` | **闪屏用**（新增）：从母图导出，透明底，不要桌面图标那层圆角遮罩外的多余边 |

桌面图标（`mipmap/ic_launcher`、`AppIcon.appiconset`）带圆角遮罩，**不能**直接 `Image.asset` 当闪屏 Logo，否则夜幕底上再叠一块圆角方。闪屏 Logo 用透明底图形，铺在 `#0B0D10` 上。

`pubspec.yaml` 增加：

```yaml
assets:
  - config/vod_sources.json
  - assets/branding/splash_logo.png
```

### 5.2 与首页的关系

首页 `_introHeader` 已是「Jive」28/700 + slogan。闪屏只复用词标，不复用 slogan、不复用长按过滤手势。

## 6. 技术要点

### 6.1 根组件改动（`lib/app/app.dart`）

当前：

```dart
home: sourceState.when(
  loading: () => Scaffold(... CircularProgressIndicator ...),
  error: (error, _) => Scaffold(... AppErrorView ...),
  data: (_) => const AppShell(),
),
```

改为：

- `loading` → `SplashPage`
- `error` → 现有错误 Scaffold（不变）
- `data` → 若最短展示未满，仍 `SplashPage`；满了再 `AppShell`

最短展示状态放在 `JiveApp` 的一层 `StatefulWidget` / `ConsumerStatefulWidget` 上（例如 `_StartupGate`），`initState` 里启动 800ms timer，与 `ref.watch(selectedVodSourceProvider)` 合取。不要把 timer 写进 `SplashPage` 自己 pop。

### 6.2 闪屏 Widget

```text
lib/features/splash/splash_page.dart   # SplashPage：无业务，纯展示
```

- `Scaffold(backgroundColor: AppColors.background)`
- 不使用 `AppBar`
- Logo：`Image.asset('assets/branding/splash_logo.png', width: logoSize, height: logoSize, filterQuality: FilterQuality.medium)`
- 词标：`Text('Jive', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: AppColors.text, height: 36/28))`

平板 `logoSize` 用 `MediaQuery.sizeOf(context).shortestSide >= 600 ? 120 : 96`。

### 6.3 原生颜色

Android `values/colors.xml` 增加：

```xml
<color name="splash_background">#0B0D10</color>
```

`launch_background.xml` 用 `@color/splash_background`，去掉 `@android:color/white`。

iOS storyboard 根视图 `red="0.043" green="0.051" blue="0.063"`（#0B0D10）。LaunchImage 可留空或去掉居中 ImageView，避免白图露出来。

### 6.4 测试

`test/features/splash/splash_page_test.dart`：

1. 源 `loading`：能找到 Logo（`find.byType(Image)` 或 asset key）和 `find.text('Jive')`；找不到底部导航。
2. 源已就绪但未满 800ms：仍在闪屏。
3. 就绪且 pump 满 800ms：出现 `floating-nav-bar`。
4. 源 `error`：`AppErrorView`，点重试后能再进闪屏/首页。

`test/widget_test.dart`：启动冒烟在 override 源之后 **pump 满 800ms**（或 `pump(const Duration(milliseconds: 800))`）再断言导航栏，避免闪屏最短展示把现有用例打红。

### 6.5 文档同步

落地后更新 `CODEBASE_MAP.md`：

- `lib/features/splash/splash_page.dart`
- `lib/app/app.dart` 注释补上闪屏闸门

本技术书状态改为「开发中」→ 完成后整份移入 `doc/archive/splash/`。

## 7. 验收标准

1. Android / iOS 冷启动：系统启动图为夜幕黑，无白闪。
2. Flutter 首帧：屏幕中央可见 Logo 与「Jive」，二者为上下结构、水平居中。
3. 源加载瞬间完成时，闪屏仍至少停留约 800ms。
4. 源就绪后进入首页三 Tab，系统返回键不能回到闪屏。
5. 源失败显示错误与重试；重试成功进首页。
6. iPad 与 TV 横屏：品牌组仍居中，不贴边、不拉伸 Logo。
7. `flutter analyze` 与 `flutter test`（含闪屏用例与更新后的 `widget_test`）通过。

## 8. 分期

1. **P0 原生消白**：Android / iOS 启动底改为 `#0B0D10`（可单独合入，立刻改善冷启动）。
2. **P1 Flutter 闪屏**：`SplashPage`（Logo + Jive）+ `_StartupGate` 最短 800ms + 源闸门。
3. **P2 测试与资源**：导出 `assets/branding/splash_logo.png`、单测、`widget_test` 等待、更新 `CODEBASE_MAP`。
4. **P3 真机**：Android 冷启动、iOS 冷启动、从后台杀进程再进；看原生→Flutter 是否同色无跳变。

## 9. 风险

| 风险 | 处理 |
|---|---|
| 原生仍闪白 | `LaunchTheme` 与 `NormalTheme` 必须同时改；iOS 去掉白色 LaunchImage |
| Logo 与词标不同源、观感割裂 | 只用 `app_icon_source` 透明月牙，禁止用带圆角遮罩的 launcher 图 |
| 800ms 让测试变慢/变红 | 启动冒烟显式 `pump(800ms)`；不要把时长做成难以覆盖的随机值 |
| 源 provider 在 build 里二次 loading | 闸门只 watch 现有 `selectedVodSourceProvider`，不在闪屏里 `invalidate` |
| 减少动态效果 | 进入首页的 fade 读 `MediaQuery.disableAnimationsOf`，为 true 则瞬间切换 |

## 10. 实现清单（开发时勾选）

- [x] `android/.../values/colors.xml` 增加 `splash_background`
- [x] `drawable/launch_background.xml`、`drawable-v21/launch_background.xml`
- [x] `values/styles.xml`、`values-night/styles.xml` 的 `NormalTheme` 窗口背景
- [x] `ios/Runner/Base.lproj/LaunchScreen.storyboard` 背景
- [x] `assets/branding/splash_logo.png` + `pubspec.yaml`
- [x] `lib/features/splash/splash_page.dart`
- [x] `lib/app/app.dart` 启动闸门
- [x] `test/features/splash/splash_page_test.dart`
- [x] 修正 `test/widget_test.dart` 等待
- [x] `doc/codebase/CODEBASE_MAP.md`
