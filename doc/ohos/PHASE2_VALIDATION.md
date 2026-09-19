# 鸿蒙适配第二阶段：完整应用与播放稳定性验证

状态：**进行中**。本阶段从最小播放探针进入完整 Jive 应用，验证启动、首页到播放的主路径，并补测播放器横屏、拖动、暂停恢复和前后台切换。本轮（2026-09-19 下午）补充了连续播放监控、签名构建机制和缓存链路（请求头、下载联动）的验证。

## 验证基线

- 验证日期：2026-09-19。
- 分支：`codex/harmonyos-adaptation`。
- Flutter OpenHarmony SDK：`3.41.10-ohos-1.0.1`，自本轮起为机器级共享安装 `~/.ohos-flutter/flutter_flutter`（gitcode CPF-Flutter/flutter_flutter @ tag，含 `tool/patch_ohos_system_ui.py` 幂等系统 UI 补丁；见 [SDK_SETUP.md](SDK_SETUP.md)）。
- `video_player`：`video_player-v2.11.1-ohos-1.0.0`。
- 构建工具：DevEco Studio 26.0.0、HarmonyOS SDK API 26。
- 运行设备：`127.0.0.1:5555`，系统 API 21 模拟器（镜像 HarmonyOS-6.0.1 phone_all_arm）。
- 构建类型：签名 Debug HAP。API 26 模拟器或真机仍未取得，因此本轮结果只证明 API 21 模拟器行为。

## 当前结果

| 验证项 | 结果 | 证据与限制 |
| --- | --- | --- |
| 完整应用构建、安装与启动 | 通过 | `./tool/build_ohos.sh --debug --signed` 成功；签名 HAP 安装后可进入首页，第一阶段记录的白屏未复现。当前只能判定"现版本未复现"，尚未找到此前白屏的根因。 |
| 完整业务主路径 | 通过初测 | 首页内容和图片正常加载；已走通"首页 → 视频详情 → 播放"，播放器显示实际视频画面及字幕。 |
| 直连 HLS | 通过模拟器复测 | Mux HLS 画面与进度正常；横屏画面可见，之前的横屏黑画面未复现。 |
| 拖动、暂停与恢复 | 通过模拟器复测 | 横屏中从约 163 秒拖动到 489 秒，画面继续更新；暂停后按钮切换为"播放"，恢复成功。 |
| 横竖屏切换 | 通过模拟器复测 | 进入横屏和退出到竖屏均成功，切换后视频画面保持可见。 |
| 本地代理 HLS | 通过模拟器复测 | 播放地址为 `http://127.0.0.1:<端口>/play/phase1/index.m3u8`，画面可见且进度推进。 |
| 前后台恢复 | 通过基础初测 | 本地代理 HLS 播放时回到桌面，约 3 秒后重新启动 Ability，页面与视频画面恢复，进度继续推进。尚未覆盖长时间后台、系统回收和锁屏。 |
| 自动连播 | 通过模拟器初测 | 本轮自动化导航到第 01 集播放，短篇动画连续播放约 10 分钟后已自动切到第 04 集，切集后画面正常。 |
| 连续播放与黑屏监控 | 通过 3 分钟窗口 | 以每分钟截图 + 视频区亮度统计（视频区裁剪 `0,235,1316,520`）监控，9 个采样 mean 158–193、stdev ≥52，全部有画面，无黑屏帧；HiLog 中无 Fatal/Crash/JSCrash 记录。30 分钟长程与高频旋转/前后台矩阵仍未执行。 |
| 鉴权请求头传递 | 通过单测（模拟器未复测） | 发现并修复缺陷：session 头白名单会丢弃 `Authorization`/`Cookie`/自定义令牌头。已改为 denylist（`lib/domain/playback_source.dart`），新增 `test/domain/playback_source_test.dart`、`cache_io_test` 4 例、`local_proxy_test` 2 例覆盖。模拟器上带鉴权头的真实 HLS 样本复测仍待做。 |
| 下载与缓存联动 | 通过单测 | 新增用例：预取窗口落盘后，全新播放侧 fetcher（共享 CacheManager）在断网下逐片命中缓存、零网络请求；未下载分片断网回源按预期失败。 |
| 声音 | 未验证 | 自动化截图无法判断音频输出，需要真机人工听测。 |
| API 26 运行 | 阻塞 | 本机只有 API 21 模拟器镜像（`~/Library/Huawei/Sdk/system-image` 仅 HarmonyOS-6.0.1）；API 26 镜像需在 DevEco Device Manager 登录华为账号下载，云真机需另行接入。 |
| 真机或云真机 | 未开始 | 声音、硬解码、生命周期和实际性能仍需真机结论。 |
| 磁盘缓存设备级链路 | 未开始 | 请求头/命中/离线回放已有单测证明，设备上带真实源站与真实网络断开的复测仍未做。 |

## 新发现

### 1. 视频纹理层存在稳定性风险（本轮量化）

完整播放器有可见画面并持续推进。本轮对一次约 10 分钟的连续播放采样：`OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null` 累计 3465 次，速率约 291 次/分钟且匀速出现（起播阶段 553 次/10 秒量级），与拖动、切集等交互无相关性；期间无黑屏帧（亮度采样全部有效）、无崩溃。该错误属于 Flutter OpenHarmony 外部纹理层在模拟器上的固有噪声，进入发布适配前仍需在 API 26 环境和真机上确认频率是否下降，并确认长时间播放、频繁旋转和前后台切换后是否出现丢帧或黑屏。

### 2. session 请求头白名单会丢弃鉴权头（已修复）

`lib/domain/playback_source.dart` 原用白名单只放行 `accept/accept-language/origin/referer/user-agent`，而插件可能通过 `playerJson`/`playerCandidates` 返回任意 `headers`（含 `Authorization`、`Cookie`、自定义令牌头），本地代理与缓存链路会把它们静默丢弃，导致需要鉴权头的源站 403。已改为 denylist：只剔除破坏请求框架的头（`host`、`content-length`、`transfer-encoding`、`connection`、`keep-alive`、`upgrade`、`te`、`trailer`、`proxy-connection`）、HTTP 客户端自管理的 `accept-encoding` 和由代理自行处理的 `range`；下游（播放器注入）方向仍保持白名单。新增策略与链路单测共 10 例。**行为变化**：带鉴权头的源在鸿蒙端播放从"必然失败"变为"按插件声明转发"，需在设备上用真实样本复测。

### 3. 调试包必须保持签名一致；签名配置已改为注入机制

模拟器保留旧应用数据时，unsigned HAP 安装返回 `install sign info inconsistent`。使用现有调试签名构建后可以覆盖安装并保留数据。本轮把该流程固化为不落库的注入机制：

- `ohos/build-profile.json5` 保持无签名通用配置（`signingConfigs: []`，产品上的 `signingConfig: "default"` 引用是注入挂钩）。
- `./tool/build_ohos.sh --signed` 现在自动执行：`tool/ohos_signing.py inject`（从 gitignored 的 `tool/ohos_signing.local.json` 读取 DevEco 生成的 signingConfigs 块并拼入构建配置）→ 构建 → `restore`（trap 保证失败也还原）。
- 首次使用：在 DevEco Studio（File > Project Structure > Signing Configs）生成自动签名后，把 `signingConfigs` 块抄入 `tool/ohos_signing.local.json`（模板见 `tool/ohos_signing.local.example.json`）。
- 注入/还原已在隔离副本上验证往返一致；仓库不包含本机证书路径或口令（DevEco 的 material 口令本机加密，无法从 `~/.ohos` 导出，必须从 IDE 抄录）。

### 4. 一次性播放探针已移除

第一阶段用于隔离验证的 `tool/ohos_phase1/`（含内嵌探针工程）已于本轮清理，根目录 HAP 不再存在完整应用与探针入口互相覆盖 `entry-default-signed.hap` 的问题；`ohos/entry/src/ohosTest` 的 DevEco 默认模板测试（与 Jive 无关的脚手架）一并移除。当前唯一 HAP 入口是完整 Jive（`lib/main.dart`）。

## 阶段判断

第二阶段已完成以下核心证明：

1. 完整 Jive 不再停留在启动白屏，首页能够加载。
2. 首页、详情和实际播放主路径能够在 API 21 模拟器运行。
3. 直连 HLS、本地代理 HLS、横竖屏、拖动、暂停恢复和短时前后台切换均有成功证据。
4. 短时连续播放（约 10 分钟）无黑屏、无崩溃，自动连播正常；纹理错误已量化为匀速噪声（约 291 次/分钟）。
5. 鉴权请求头、缓存命中、断网回放和下载联动在单元测试层面闭环；签名构建机制已固化为不落库的注入流程。

第二阶段目前**不能判定完成**。剩余门槛是：

1. 在 API 26 模拟器或设备上重复完整测试矩阵（镜像下载需登录华为账号，本轮无法自主完成）。
2. 至少一台鸿蒙真机或云真机验证声音、硬解码、横屏和前后台恢复。
3. 30 分钟连续播放与 20 次旋转、10 次前后台切换的高频矩阵（本轮仅执行 3 分钟监控窗口 + 交互验证）。
4. 设备级复测：带鉴权请求头的真实 HLS 样本、磁盘缓存命中、断网续播和缓存清理。
5. 纹理错误在真机/API 26 上的频率与黑屏关联确认。

## 下一轮执行顺序

1. 先解决 API 26 运行环境或接入云真机（DevEco Device Manager 登录华为账号下载 API 26 镜像），原样复跑本轮用例。
2. 执行 30 分钟连续播放、20 次横竖屏切换、10 次前后台切换矩阵，统计纹理错误、黑屏、崩溃和卡顿。
3. 用带鉴权请求头的 HLS 样本在设备上验证代理改写与分段请求头传递（单测已证明链路，设备级待复测）。
4. 开启磁盘缓存，验证首次播放、缓存命中、断网续播和缓存清理。
5. 人工验证声音、音画同步和耳机/扬声器切换。
