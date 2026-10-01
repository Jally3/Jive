# 冲突解决日志：refactor/code-structure → codex/playback-startup-trace

日期：2026-10-01（Asia/Shanghai）。本次接手的是已经发起、尚未完成的 Git merge。

## 起点与处理范围

- 当前分支：`codex/playback-startup-trace`。
- 当前 HEAD：`3e11aa1`（新增播放追踪功能）。
- 合入提交 MERGE_HEAD：`8cf29e501d52c7378ffb3479348a742f7e3b6535`，来自 `refactor/code-structure`（下载批量操作栏、版本 1.1.3+5）。
- 共同祖先：`45cb275e588f639341dd109d25609b76c0f23c47`。
- 接手时 Git 标记了 5 个冲突文件，共 10 个冲突块；其余合入改动已经暂存。
- 额外扫描发现 `doc/follow/FOLLOW_UPDATES_REQUIREMENTS.md` 有 17 个历史冲突块，来自已提交的 `28d0f72` 合并，未被本次 Git 标为 unmerged；一并整理。
- 原始冲突文件及三个 Git stage 内容备份在 `/private/tmp/jive-conflict-resolution-2026-10-01/`，仅供本次本机审查，未加入仓库。

## 逐文件决策

| 文件 | 解决方式与依据 |
| --- | --- |
| `lib/features/player/player_page.dart` | 保留合入分支的 `PlayerStateBase` + 7 个 mixin 架构，移除已迁入 parts 的重复字段和方法；保留当前分支的 `startupTrace` 页面参数、initState 接收和 dispose 取消。 |
| `lib/features/player/parts/player_state.dart` | 增加共享 `_startupTrace` 字段，供页面与会话 mixin 使用。 |
| `lib/features/player/parts/player_session_lifecycle.dart` | 迁入当前分支的启动追踪：片头配置读取、离线检查、播放地址解析、格式嗅探、HLS 会话准备、控制器初始化及直链回退、续播 seek、倍速/音量、播放、完成/失败收尾和启动 I/O 回调。共同祖先的方法与合入版本比较后，确认业务差异仅为常亮接口和心跳管理；保留合入分支的 `ScreenAwakeController.release(owner)`，由共享控制器管理心跳。 |
| `lib/data/cache/cache_io.dart` | 合并两侧行为：保留可选缓存/回源 I/O 追踪，同时保留 `isCancelled` 检查、上游 subscription 取消、sink 关闭、lease 释放、part 删除及 `finishing` 防重复清理。完整下载和错误路径均保留追踪事件。 |
| `lib/features/settings/more_settings_page.dart` | 同时保留下载常亮开关、受编译开关控制的“开发诊断 → 播放耗时分析”和“关于 → 版本号”；保留 `appVersionProvider` 与追踪页导入。 |
| `pubspec.yaml` | 采用合入分支 `1.1.3+5`，避免退回当前分支 `1.1.1+5`；依赖约束不变。 |
| `doc/codebase/CODEBASE_MAP.md` | 同时登记缓存模型拆分、播放器 parts、启动追踪与设置能力，补录已合入的 `restore_fvm.sh`。 |
| `doc/follow/FOLLOW_UPDATES_REQUIREMENTS.md` | 17 处历史标记采用 `codex/jive-dev` 侧与现有实现一致的描述：追更锚点菜单、右上角下载入口、片头/片尾菜单、三个个人页 Tab、纯红点及未读集数角标、仅新增集数触发提醒。依据为关系按钮、详情 AppBar、个人页及 LibraryRepository 的现有实现；同步修正范围/验收条目中残留的同行下载和点击追更文案。仅修改文档。 |

自动合并后的详情页追踪参数传递已检查，仍将同一次 trace 传入 `PlayerPage`。原有自动合并内容保留在索引中；没有重置工作区或另行发起合并。

## 新增回归覆盖

- `test/data/cache/cache_io_test.dart`：带追踪的响应取消后，上游被取消、写入配额归零、临时文件和正式文件均不残留、无完成资源记录，并保留首字节追踪且不误报缓存提交。
- `test/features/player/player_page_test.dart`：开启 `JIVE_PLAYBACK_TRACE` 后，传入的 trace 在成功启动和初始化中退出时分别只输出一次 success/cancelled 汇总；关闭开关时这 2 项跳过。

## 验证结果

- `fvm dart format lib test`：226 个文件，最终无格式变化。
- `fvm flutter analyze --no-pub`：通过，No issues found。
- `./tool/check_flutter_sdk.sh`：通过，Flutter 3.41.3，全部生成配置一致。
- `fvm flutter test --no-pub test/data/cache/cache_io_test.dart --reporter expanded`：16 项通过。
- `fvm flutter test --no-pub --dart-define=JIVE_PLAYBACK_TRACE=true test/features/player/player_page_test.dart --plain-name 'startup trace survives refactoring' --reporter expanded`：2 项通过。
- 全量测试：已执行；首页/详情 2 项失败，并在下载页蜂窝恢复用例持续等待。将单用例超时设为 30 秒后仍未正常结束，因此终止等待，再单独排除该用例验证其余测试。
- `fvm flutter test --no-pub --name '^(?!.*waiting Wi-Fi asks before a one-time cellular resume).*$' --reporter expanded`：626 项通过、2 项跳过（追踪开关关闭）、2 项失败（下述已复现的既有失败），退出码 1。仅排除 1 个持续等待用例。
- 冲突标记扫描：仓库可见文本无残留；`git diff --check` 通过。
- 暂存后 `git ls-files -u` 与 `git diff --name-only --diff-filter=U` 均为空；`git diff --cached --check` 通过。

### 原始合入提交上的对照验证

从 `git archive MERGE_HEAD` 在 `/private/tmp/jive-merge-baseline-8cf29e5/` 建立独立源码快照，复用同版本 FVM SDK 与依赖配置，未修改当前工作区。

1. 首页 `collapsed root row shows a transparent primary feed label`：当前结果和原始提交均失败；宽度期望 40.5，实际 52.5。
2. 详情 `returning from the player expands the group of the played episode`：当前结果和原始提交均在滚动寻找第 120 集时失败，`Bad state: No element`（Scrollable finder 无匹配）。原始提交两份测试文件合计 46 项通过、2 项失败。
3. 下载 `waiting Wi-Fi asks before a one-time cellular resume`：当前结果和原始提交均持续等待；原始下载测试先通过 15 项后停在同一用例。下载页面及其测试与 MERGE_HEAD 完全相同。本次未修改这三个既有问题。

因此这些失败/持续等待已在合入前存在，不能把本次验证称为“全量通过”。

### 原始测试输出（本机临时文件）

- `/private/tmp/jive-merge-full-test-2026-10-01.log`：首次全量运行（持续等待后终止）。
- `/private/tmp/jive-merge-full-test-final-2026-10-01.log`：30 秒单用例超时尝试（持续等待后终止）。
- `/private/tmp/jive-merge-test-without-stalled-case-2026-10-01.log`：排除持续等待用例后的其余全量验证。
- `/private/tmp/jive-merge-cache-test-2026-10-01.log`、`/private/tmp/jive-merge-trace-test-2026-10-01.log`：专项回归。
- `/private/tmp/jive-merge-baseline-test-2026-10-01.log`、`/private/tmp/jive-merge-baseline-download-test-2026-10-01.log`：原始合入提交对照。

## 审查状态

冲突解决、回归测试及本日志已暂存到 Git 索引，unmerged 路径为 0；保留 MERGE_HEAD，尚未创建 merge commit，留给审查后决定。

建议审查：

```bash
git status
git diff --cached --check
git diff --cached -- lib/data/cache/cache_io.dart lib/features/player/player_page.dart lib/features/player/parts/player_state.dart lib/features/player/parts/player_session_lifecycle.dart lib/features/settings/more_settings_page.dart pubspec.yaml
git diff --cached -- doc/codebase/CODEBASE_MAP.md doc/follow/FOLLOW_UPDATES_REQUIREMENTS.md test/data/cache/cache_io_test.dart test/features/player/player_page_test.dart
```

`git diff --cached` 相对当前 HEAD 展示整个合并结果；要只检查追踪在重构结构中的保留情况，可使用 `git diff MERGE_HEAD -- lib/features/player lib/data/cache/cache_io.dart lib/features/settings/more_settings_page.dart`。
