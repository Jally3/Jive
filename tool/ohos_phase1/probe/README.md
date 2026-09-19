# 独立播放器验证工程

此工程只依赖 Flutter 和适配版 `video_player`，用于先判定插件能否在鸿蒙模拟器播放 MP4/HLS、拖动与切换全屏。`ohos/` runner 已生成，包含网络权限。

安装较新的 DevEco Studio、配套 SDK 和模拟器后，先在当前终端配置 SDK 与工具路径（安装目录以实际位置为准）。原 DevEco 6.0.1 / API 21 SDK 会在 Flutter 引擎的 ArkTS 编译阶段失败。

```bash
export DEVECO_ROOT=/Applications/DevEco-Studio.app/Contents
export HOS_SDK_HOME="$DEVECO_ROOT/sdk"
export DEVECO_SDK_HOME="$DEVECO_ROOT/sdk"
export PATH="$DEVECO_ROOT/tools/ohpm/bin:$DEVECO_ROOT/tools/hvigor/bin:$DEVECO_ROOT/tools/node/bin:$PATH"
```

然后在仓库根目录执行：

```bash
cd tool/ohos_phase1/probe
../../../.ohos-sdk/bin/flutter doctor -v
../../../.ohos-sdk/bin/flutter pub get
../../../.ohos-sdk/bin/flutter build hap --debug
../../../.ohos-sdk/bin/flutter devices
../../../.ohos-sdk/bin/flutter run -d <设备ID>
```

随后使用仓库根目录的 `tool/ohos_phase1/main.dart` 测试 Jive 的 `HlsParser` 与 `LocalProxyServer`。详细结果和验收项见 `doc/ohos/PHASE1_VALIDATION.md`。
