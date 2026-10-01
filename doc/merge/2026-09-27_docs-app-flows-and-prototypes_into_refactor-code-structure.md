# 合并日志：docs/app-flows-and-prototypes → refactor/code-structure

## 合并目标

- 源分支：`docs/app-flows-and-prototypes`（开始时为 `e8423a1`）
- 目标分支：`refactor/code-structure`（开始时为 `1fdbd75`）
- 共同祖先：`da8dc09`
- 源分支独有提交：8 个
- 目标分支独有提交：5 个
- 策略：保留目标分支的分层/组件化结构，将源分支的新功能、稳定性修复、测试与文档迁入新结构。

## 任务拆分

1. **合并前检查与记录**
   - 确认工作区干净、分支头与共同祖先。
   - 记录双方独有提交和预期冲突范围。
2. **发起 Git 合并**
   - 切换至 `refactor/code-structure`。
   - 合并 `docs/app-flows-and-prototypes`，保留合并状态以便逐项处理。
3. **文档与代码地图**
   - 合并 `doc/codebase/CODEBASE_MAP.md`，同时保留新文档入口与重构后的文件布局。
   - 合并完成后将本日志登记到 `doc/README.md`（若索引结构适合）。
4. **下载模块冲突**
   - 在拆分后的下载任务模型/存储结构上，迁移源分支的离线保护与请求可靠性改动。
   - 保留对应回归测试。
5. **首页冲突**
   - 以目标分支的 controllers/widgets/support 分层为骨架。
   - 迁移源分支的分类栏吸顶交互及相关测试。
6. **播放器冲突**
   - 以目标分支的 parts mixin 拆分结构为骨架。
   - 迁移源分支的播放器交互、预取稳定性及测试改动。
7. **全量一致性检查**
   - 搜索并清除冲突标记。
   - 执行 Dart 格式化、静态分析和测试。
   - 检查 `CODEBASE_MAP.md` 与最终文件结构一致。
8. **完成记录**
   - 在本日志补充实际冲突、解决方式、验证结果与最终状态。

## 合并前预检

`git merge-tree` 预测以下文件由双方同时修改，需要在实际合并后确认：

- `doc/codebase/CODEBASE_MAP.md`
- `lib/data/download/download_task_manager.dart`
- `lib/features/home/home_page.dart`
- `lib/features/player/player_page.dart`

## 冲突与处理记录

已在目标分支执行：

```bash
git merge --no-commit --no-ff docs/app-flows-and-prototypes
```

实际产生 4 个内容冲突，与预检一致：

| 文件 | 处理任务 | 状态 |
| --- | --- | --- |
| `doc/codebase/CODEBASE_MAP.md` | 合并重构文件索引与源分支新增/变更文件说明 | 已解决 |
| `lib/data/download/download_task_manager.dart` | 在拆分结构上迁移下载可靠性与离线保护 | 已解决 |
| `lib/features/home/home_page.dart` | 在首页分层结构上迁移分类栏吸顶交互 | 已解决 |
| `lib/features/player/player_page.dart` | 在 parts mixin 结构上迁移播放器交互 | 已解决 |

目标 worktree 在合并前已有未提交的 `macos/Podfile.lock` 修改；该文件不在源分支差异中，将原样保留且不计入本次冲突处理。

处理结果：

- 代码地图同时保留 `download_task.dart`、`download_permit_pool.dart` 与新增 `download_task_store.dart`。
- 下载管理保留拆分后的任务模型和许可池，迁入可取消请求、连接/空闲/总超时、无数据看门狗与刷新重试。
- 首页在 `HomeCategoryHeader` 组件与 `FeedScrollMemory` 结构上实现最后一行吸顶、完整分类覆盖层、父分类上下文与子分类自动显示。
- 播放器将控制栏、播放命令、会话生命周期和 wakelock 修正分别迁入对应 mixin，保留拆分架构。
- 频道页关闭按钮直接移除自身路由，避免叠加路由残留。

## 验证记录

- `fvm flutter analyze --no-pub`：通过，无问题。
- `test/data/download/download_task_manager_test.dart`：14 项通过。
- `test/features/home/nav_overlay_test.dart`：24 项通过。
- `test/features/player/player_page_test.dart`：43 项通过。
- 全量测试：602 项通过，1 项失败。失败项为 `detail_page_test.dart` 的 `returning from the player expands the group of the played episode`，原因是 844×390 横屏下选集按钮位于测试视口外。
- 已在合并前目标提交 `1fdbd75` 的独立临时 worktree 复现同一失败，确认为目标分支既有问题，非本次合并回归。
- `git diff --check --cached`：通过。
