# 投屏功能方案（CAST PLAN）

状态：**待确认电视型号后启动开发**。本文档沉淀投屏的技术路线分析、关键约束与分期计划；两个待确认问题见第 7 节，确认后才进入 P0。

## 1. 目标

在播放页新增投屏能力，将当前剧集投到客厅的索尼电视播放，手机端提供遥控（播放/暂停/进度/音量/选集），进度回写观看记录。

## 2. 索尼电视的接收能力

近十年索尼电视基本为 Android TV / Google TV，自带三类接收协议：

- **Google Cast（Chromecast built-in）**：原生支持，HLS/MP4/DASH 均可，主路线候选。
- **DLNA**：支持，但主要面向 MP4/MPEG-TS 时代，**对 m3u8 兼容性因型号而异，不可靠**，仅作兜底。
- **AirPlay 2**：2019 年后机型支持，仅限 iOS 发送端。

## 3. 发送端路线对比

### 路线 A：Google Cast（推荐主路线）

- Flutter 无可靠现成 Cast 插件，需 platform channel 接原生 Cast SDK（Android 集成简单；iOS 需 `google-cast` pod 与配置，工作量中等）。
- 使用 **Default Media Receiver**（默认接收器，免注册 Cast 开发者账号），把视频 URL 交给电视直连播放。
- 体验最好：投屏后手机可退出/锁屏，电视独立播放。

### 路线 B：DLNA（纯 Dart，跨端兜底）

- SSDP 组播发现 + SOAP 控制（SetAVTransportURI / Play / Pause / Seek / GetPositionInfo），可纯 Dart 实现，无原生依赖，一两天出最小闭环。
- 缺点：HLS 支持存疑、无法携带自定义 header。

### 路线 C：AirPlay（iOS 顺手做）

- iOS 端 video_player 底层为 AVPlayer，挂 `AVRoutePickerView` 并开启 `allowsExternalPlayback` 即获系统级 AirPlay，成本极低。
- 仅限 iOS，且电视需 2019 年后机型。

## 4. 核心约束：本地代理（本项目特有）

现状：多数源播放时 URL 被改写为 `http://127.0.0.1:<port>/play/<token>/index.m3u8`，由手机本地代理（`lib/data/playback/local_proxy.dart`，绑定 `InternetAddress.loopbackIPv4`）承担广告过滤、Referer/UA header 注入、缓存写穿。**电视无法访问 loopback 地址**，两个子方案：

- **直连投屏**：把解析出的原始 URL 直接投给电视。简单，但失去广告过滤；若源站校验 Referer/UA，Cast 默认接收器不支持自定义 header，可能 403。
- **代理投屏（推荐）**：`local_proxy.dart` 增加可选 LAN 绑定（loopback → 局域网地址），投屏 URL 用 `http://<手机局域网IP>:<port>/play/<token>/...`。电视经手机中转，**广告过滤、header 注入、缓存全部保留**，现有链路零浪费。代价：手机需保持唤醒、App 在前台；Android 无问题，**iOS 锁屏/退后台约 30 秒后网络服务被系统挂起**，投屏期间需 wakelock 并向用户提示。

## 5. 遥控与状态同步

- Cast：`RemoteMediaClient` 提供 play/pause/seek 与 position 轮询。
- DLNA：AVTransport 的 Play/Pause/Seek + GetPositionInfo 轮询。
- 手机端"投屏中"面板：封面、当前集、进度条拖动、播放/暂停、音量、上一集/下一集、断开。
- 投屏期间本地播放器暂停（代理保活）；进度按现有节流策略回写 WatchRecord，断开后可回本地续播。

## 6. 代码落点（贴合现有结构）

- `lib/data/cast/`（新增）：`cast_service.dart` 抽象接口（discover/connect/load/play/pause/seek/dispose + 状态流）、`dlna_cast_service.dart`、`google_cast_service.dart`（platform channel）。
- `lib/features/cast/`（新增）：设备发现弹层、投屏中控制面板；`player_page` 顶栏加投屏入口。
- `local_proxy.dart`：增加可选 LAN 绑定参数（小改，向后兼容）。
- 测试：SSDP 响应解析、SOAP 消息构造、`127.0.0.1` → 局域网 IP 的 URL 改写。

## 7. 待确认问题（确认后才进入开发）

1. **电视型号/年份**：设置里是否有 "Chromecast built-in" / AirPlay？决定兜底路线选择。
2. **投屏时是否保留广告过滤**：保留 → 走代理投屏方案，手机投屏期间不能锁屏；不保留 → 直连投屏更简单。

## 8. 分期计划

1. **P0 技术验证（半天，先做这个）**：不做 UI，直接验证——① 电视用 Cast 默认接收器能否播放项目典型 m3u8 源；② DLNA 能否播放（m3u8 与 mp4 各试一个）。此步决定主路线，避免押错协议白做 SDK 集成。
2. **P1**：主路线最小闭环（发现设备 → 连接 → 投屏播放 → 断开）。
3. **P2**：遥控面板 + 进度同步 + 观看记录回写。
4. **P3**：代理 LAN 模式（保留广告过滤）+ 选集/连播联动。

## 9. 风险清单

- DLNA 对 HLS 支持不确定（P0 必须实测）。
- 源站 Referer/UA 校验导致 Cast 直连 403（代理投屏可规避）。
- iOS 后台网络限制使代理投屏在锁屏后中断。
- iOS 端 google-cast SDK 引入的体积与审核备注成本。
