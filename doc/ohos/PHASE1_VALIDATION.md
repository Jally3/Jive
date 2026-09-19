# 鸿蒙适配第一阶段：播放链路验证

## 固定组合与隔离

- 工作分支：`codex/harmonyos-adaptation`。
- 原项目 `.fvmrc` 继续固定标准 Flutter `3.41.3`；不要用适配 SDK 执行 `fvm use`。
- 本阶段适配 SDK：`CPF-Flutter/flutter_flutter` tag `3.41.10-ohos-1.0.1`。
- 本阶段播放器：`CPF-Flutter/flutter_packages` tag `video_player-v2.11.1-ohos-1.0.0`，由根目录 `pubspec_overrides.yaml` 仅在本分支覆盖。
- SDK 本地克隆到被 Git 忽略的 `.ohos-sdk/`；`ohos/` 是适配 SDK 生成的鸿蒙 runner。
- `tool/ohos_phase1/probe/` 是只依赖 Flutter 和适配版播放器的独立应用；根目录的 `tool/ohos_phase1/main.dart` 再验证 Jive 的真实 HLS 解析与本地代理。

## 当前验证结果（2026-09-18）

| 项目 | 结果 | 证据或限制 |
| --- | --- | --- |
| 适配 SDK 下载与启动 | 通过 | `.ohos-sdk/bin/flutter --version` 报告 `3.41.10-ohos-1.0.1`、Dart `3.11.5`。 |
| 播放器依赖解析 | 通过 | 适配 SDK `flutter pub get` 解析到 `video_player 2.11.1` 和 `video_player_ohos 1.0.0+2`。 |
| 独立播放器工程 | 通过构建及模拟器初测 | `tool/ohos_phase1/probe/` 只依赖 Flutter、`video_player`；`flutter build hap --debug --no-codesign` 成功。API 21 模拟器上 MP4 显示画面并播放完 4 秒；Apple 示例 HLS 进度推进，拖动后显示 373/599 秒。全屏按钮触发横屏，但横屏截图出现黑色播放器画面，仍需复测。 |
| 最小播放入口静态分析 | 通过 | 标准 `fvm flutter analyze tool/ohos_phase1/main.dart` 无问题。 |
| 现有本地代理单元测试 | 通过 | `fvm flutter test test/data/playback/local_proxy_test.dart`，11 项通过。 |
| 鸿蒙 runner 生成 | 已生成 | `.ohos-sdk/bin/flutter create --platforms ohos --project-name jive .` 创建 `ohos/`，随后因缺少 Hmos SDK 退出。 |
| Jive 代理验证包 | 通过构建及模拟器初测 | `flutter build hap --debug --no-codesign -t tool/ohos_phase1/main.dart` 成功。模拟器打开 `http://127.0.0.1:<端口>/play/phase1/index.m3u8`，画面可见，进度推进至 62/634 秒。使用 Mux 公开媒体清单；未涉及磁盘缓存。 |
| 完整 Jive 默认入口 | 构建、安装、Ability 启动成功；页面未通过 | `flutter build hap --debug --no-codesign` 生成 HAP，`hdc install` 与 `aa start` 成功；API 21 模拟器截图仍是白屏，尚不能作为完整应用可运行的证明。根目录 HAP 会被不同 `-t` 构建覆盖。 |

### 工具链安装后的复测

2026-09-18 用户安装了 DevEco Studio 6.0.1、HarmonyOS SDK API 21 和 API 21 模拟器（`127.0.0.1:5557`）。适配 SDK 的 `flutter doctor -v` 已显示 HarmonyOS toolchain 通过；`unknown channel`、其他 iPad 搜索失败和 Google Maven 超时不影响本次鸿蒙构建判断。

独立工程首次构建要求同时设置 `DEVECO_SDK_HOME`。补齐该变量后，Hvigor 进入 ArkTS 编译，但 `@ohos/flutter_ohos` 因 API 21 SDK 缺少 `CompetitionStrategy`、`Window.isInFreeWindowMode` 等接口失败（19 个编译错误）。用户随后安装 DevEco Studio 26.0.0 及 SDK API 26。两个验证包使用 API 26 SDK 均构建成功。通过 `hdc install` 安装 unsigned HAP，并用 `hdc shell aa start` 在现有 API 21 模拟器启动；无需为模拟器配置签名。`flutter run` 仍要求 DevEco 自动生成签名配置。

API 26 模拟器镜像尚未取得：DevEco Device Manager 显示网络请求失败，模拟器命令行也无法解析镜像服务器域名。因此当前运行证据来自 **API 26 构建、API 21 模拟器运行**，不能据此推断 API 26 设备或真机的行为。模拟器可观察画面与进度，但声音、后台恢复、实际全屏视频画面和缓存读取尚未验证。Apple 示例媒体清单包含 Jive 解析器不支持的 `#EXT-X-BITRATE`；Jive 代理验证入口改用 Mux 公开媒体清单，不修改正式解析器规则。

### 日常运行与热重载

从仓库根目录使用 `./tool/build_ohos.sh` 打包完整 Jive，默认生成 Debug unsigned HAP，产物在 `build/ohos/hap/`。脚本使用 `.ohos-sdk/` 的适配版 Flutter、根目录的鸿蒙插件覆盖配置，并自动补齐 DevEco 工具路径。DevEco 不在默认安装目录时，先设置 `DEVECO_ROOT`（指向其 `Contents` 目录）。可用 `--release`、`--profile`、`--target <Dart 入口>` 切换构建；需要已有签名配置时加 `--signed`。例如：

```bash
./tool/build_ohos.sh
./tool/build_ohos.sh --release
./tool/build_ohos.sh --debug --target tool/ohos_phase1/main.dart
```

打包脚本会先运行 `tool/patch_ohos_system_ui.py`，为当前适配 SDK 的 `SystemChrome.setEnabledSystemUIMode` 成功分支补充平台通道回复。补丁覆盖 SDK 源码及缓存的 Debug/Profile/Release HAR；直接调用 `.ohos-sdk/bin/flutter build hap` 前也需先运行该补丁脚本。SDK 更新后补丁脚本可再次执行。

适配 SDK 的 `flutter devices` 能识别当前模拟器为 `127.0.0.1:5555`（`ohos-arm64`）。`flutter run -d 127.0.0.1:5555 -t tool/ohos_phase1/main.dart` 会自动构建、安装和启动，但其源码固定启用签名；若本机尚未配置签名，使用 `run` 前须在 DevEco Studio 为 `ohos/` 工程生成一次调试签名。调试签名材料不要提交到仓库。

未配置签名时，仍可先用 `build hap --debug --no-codesign` 与 `hdc install` 安装调试包。随后在对应 Flutter 工程目录执行 `flutter attach -d 127.0.0.1:5555`：独立播放器探针已实测连接 Dart VM Service，并出现 `r` 热重载、`R` 热重启交互命令。尚未实际触发一次代码修改后的热重载。当前适配 SDK 的 `flutter emulators` 在 macOS 上有 `launch-ohos-emulator` 参数解析问题，需从 DevEco Device Manager 或 `Emulator -start` 启动模拟器。

## 下一步

1. 取得 API 26 模拟器镜像后，复测 MP4、HLS、拖动、本地代理和全屏画面；检查播放器横屏黑画面是否稳定复现。
2. 补测暂停/恢复、前后台切换和声音；在云真机复核关键播放链路。
3. 验证需要请求头的流、代理分段与磁盘缓存的联动，再决定是否迁移完整播放器页面。

根目录入口复用 Jive 的 `HlsParser` 与 `LocalProxyServer`，但不包含完整播放器页面、磁盘缓存或下载。示例视频依赖外部网络；网络失败需要与插件初始化失败分别记录。第一阶段只有在模拟器及云真机验证关键播放链路后才能判定通过。

## 参考

- [Flutter OpenHarmony SDK](https://gitcode.com/CPF-Flutter/flutter_flutter)
- [适配版 video_player](https://gitcode.com/CPF-Flutter/flutter_packages/tree/master/packages/video_player/video_player_ohos)
- [DevEco Studio 模拟器](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-emulator-create)
