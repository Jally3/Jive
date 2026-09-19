# 双 SDK 布局与 OHOS SDK 共享安装

状态：**持续生效**。本仓库长期保留两套 Flutter SDK，职责严格分离；本文说明各自的来源、解析规则和跨仓库共享方式。

## 双 SDK 布局

```text
官方 Flutter 3.41.3（fvm 管理，.fvmrc 锁定）
├── analyze / test
├── Android
└── iOS

CPF Flutter 3.41.10-ohos-1.0.1（OpenHarmony SIG 分支，机器级共享安装）
└── OHOS（flutter build hap、ohos/ runner）
```

| | 官方 Flutter | CPF Flutter（OHOS） |
| --- | --- | --- |
| 版本 | `3.41.3` | `3.41.10-ohos-1.0.1` |
| 管理 | fvm（`.fvmrc`），`fvm flutter` / `.fvm/flutter_sdk` | `tool/setup_ohos_sdk.sh`，默认装在 `~/.ohos-flutter/flutter_flutter` |
| 来源 | Google 官方 | `https://gitcode.com/CPF-Flutter/flutter_flutter.git` @ tag `3.41.10-ohos-1.0.1` |
| 用途 | `fvm flutter analyze/test/run`、Android、iOS | 仅 `./tool/build_ohos.sh` 与 `ohos/` runner |
| 锁定文件 | `.fvmrc` | `tool/ohos_sdk_version` |

**禁止用 CPF SDK 执行 `fvm use`，也禁止把 CPF SDK 安装进 `~/fvm/versions/`**——fvm 会把它当作可选官方版本列出，任何仓库误切都会混淆双 SDK 语义。

## 共享 SDK 的解析顺序

`tool/build_ohos.sh` 与 `tool/patch_ohos_system_ui.py` 使用同一解析链：

1. 环境变量 `OHOS_FLUTTER_ROOT`（显式指定，必须是含 `bin/flutter` 的 CPF checkout）；
2. `~/.ohos-flutter/flutter_flutter`（机器级共享安装，推荐）；
3. `<仓库>/.ohos-sdk`（旧版仓库内私有拷贝，仅作向后兼容回退）；
4. 都找不到则报错，提示运行 `tool/setup_ohos_sdk.sh`。

构建时还会校验 `bin/cache/flutter.version.json` 的 `frameworkVersion` 必须等于 `tool/ohos_sdk_version` 锁定的版本，防止拿错 SDK 构建。

## 安装与升级

```bash
./tool/setup_ohos_sdk.sh              # 安装 tool/ohos_sdk_version 锁定的 tag 并引导工具链
./tool/setup_ohos_sdk.sh <tag>        # 显式指定 tag
```

脚本行为：目标目录缺失时执行 `git clone --depth 1 --filter=blob:none --branch <tag>`；已存在但版本不符时报错并给出 fetch/checkout 升级命令；最后运行 `bin/flutter --version` 引导（首次会下载 Dart SDK 与工具产物）。升级版本时同步更新 `tool/ohos_sdk_version` 并提交。

## 必带的系统 UI 补丁（不可省略）

CPF `3.41.10-ohos-1.0.1` 上游有一个 bug：OHOS 嵌入层的 `SystemUiMode` 平台通道调用只执行不回复，Dart 侧 Future 永远悬挂。`tool/patch_ohos_system_ui.py` 在**每次构建前**幂等地补一行回复（共三处：SDK 引擎源码、`bin/cache/artifacts/engine/ohos-*/flutter.har` 缓存、`ohos/oh_modules` 内已安装的 flutter_ohos）：

```diff
             this.platform.platformMessageHandler.showSystemUiMode(mode);
+            result.success(null);
           } catch (err) {
```

因此 `engine/.../systemchannels/PlatformChannel.ets` 在 SDK checkout 中**始终显示为已修改**——这是构建工具链的确定性产物，不是手工编辑；干净克隆 + 运行补丁脚本即可复现。直接绕过 `build_ohos.sh` 调用 `bin/flutter build hap` 之前，必须先手动运行该补丁脚本。

**冷缓存收敛**：首次构建时引擎产物才下载，补丁脚本只能在构建后补到 HAR。`build_ohos.sh` 通过“构建 → 再补丁 → 若有实际改动则重建一次”保证最终产物一定使用已打补丁的嵌入层；温缓存下第二遍补丁为 no-op，零额外开销。

## 其他仓库接入

其他本地仓库要构建 OHOS 产物时：

1. 机器上已有共享 SDK 的，无需任何动作（解析链第 2 条自动命中）；需要不同 tag 时用 `OHOS_FLUTTER_ROOT` 指向另一个 checkout。
2. 新机器：复制本仓库的 `tool/setup_ohos_sdk.sh`、`tool/ohos_sdk_version`、`tool/patch_ohos_system_ui.py`（后者的 `ROOT` 语义改为各自仓库根），先 setup 后构建。
3. 插件覆盖（如 `video_player` 的 OHOS 版）在各仓库自己的 `pubspec_overrides.yaml` 中以 gitcode CPF 远程 ref 声明，与 SDK 位置无关。

## 本仓库相关文件

- `tool/ohos_sdk_version` — 锁定的 CPF tag（唯一版本源）
- `tool/setup_ohos_sdk.sh` — 安装 / 校验 / 引导
- `tool/build_ohos.sh` — OHOS 构建入口（解析 SDK、版本校验、补丁收敛、签名注入）
- `tool/patch_ohos_system_ui.py` — 系统 UI 回复补丁（幂等）
- `ohos/local.properties` — 构建时自动把 `flutter.sdk` 同步为解析结果（不入库）
