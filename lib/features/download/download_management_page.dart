import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/download/download_providers.dart';
import '../../data/download/download_task_manager.dart';
import '../../domain/video.dart';
import '../../shared/app_toast.dart';
import '../cache/cache_management_page.dart';
import '../player/player_page.dart';

enum _DownloadFilter { all, active, completed, failed }

class DownloadManagementPage extends ConsumerStatefulWidget {
  const DownloadManagementPage({super.key});

  @override
  ConsumerState<DownloadManagementPage> createState() =>
      _DownloadManagementPageState();
}

class _DownloadManagementPageState
    extends ConsumerState<DownloadManagementPage> {
  _DownloadFilter? filter;
  bool _initialFilterScheduled = false;
  final Set<String> busyTaskIds = {};
  final Set<String> selectedTaskIds = {};
  final Set<String> expandedGroups = {};
  final Set<String> manuallyCollapsedGroups = {};
  bool batchBusy = false;
  bool editing = false;

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(downloadTasksProvider);
    final allVisibleSelected = editing && _allVisibleSelected();
    return Scaffold(
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(editing ? '已选 ${selectedTaskIds.length} 项' : '下载管理'),
        leading: editing
            ? IconButton(
                tooltip: '退出编辑',
                onPressed: _exitEditing,
                icon: Icon(Icons.close),
              )
            : null,
        actions: [
          if (editing) ...[
            IconButton(
              tooltip: allVisibleSelected ? '取消全选' : '全选当前筛选结果',
              onPressed: _toggleSelectAllVisible,
              icon: Icon(
                allVisibleSelected ? Icons.deselect : Icons.select_all,
              ),
            ),
          ] else
            IconButton(
              tooltip: '编辑任务',
              onPressed: _enterEditing,
              icon: Icon(Icons.edit_outlined),
            ),
          if (!editing)
            IconButton(
              tooltip: '播放缓存管理',
              icon: Icon(Icons.storage_outlined),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => CacheManagementPage())),
            ),
        ],
      ),
      body: tasks.when(
        loading: () => AppLoadingView(label: '正在加载下载任务…'),
        error: (_, _) => AppErrorView(
          message: '下载任务加载失败',
          onRetry: () => ref.invalidate(downloadTasksProvider),
        ),
        data: (items) {
          final activeFilter = filter ?? _initialFilter(items);
          if (filter == null && items.isNotEmpty && !_initialFilterScheduled) {
            _initialFilterScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && filter == null) {
                setState(() => filter = activeFilter);
              }
            });
          }
          final visible = items
              .where((task) => _matchesFilter(task, activeFilter))
              .toList();
          final groups = _groupTasks(visible);
          // 下载中的分组自动展开。在帧后写入状态，避免在 build 期间改状态。
          final autoExpand = groups.entries
              .where(
                (entry) => entry.value.any(
                  (task) => task.status == DownloadTaskStatus.downloading,
                ),
              )
              .map((entry) => entry.key)
              .where(
                (key) =>
                    !expandedGroups.contains(key) &&
                    !manuallyCollapsedGroups.contains(key),
              )
              .toList();
          if (autoExpand.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => expandedGroups.addAll(autoExpand));
            });
          }
          if (items.isEmpty) {
            return AppEmptyView(
              icon: Icons.download_outlined,
              message: '还没有下载任务\n在详情页或播放页点击下载',
            );
          }
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _summary(items),
              SizedBox(height: 12),
              if (editing)
                _batchActionBar()
              else
                _filterBar(items, activeFilter),
              SizedBox(height: 12),
              if (visible.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('当前筛选下没有任务')),
                )
              else
                for (final group in groups.entries)
                  _videoGroup(context, group.key, group.value),
            ],
          );
        },
      ),
    );
  }

  List<DownloadTask> _selectedTasks() => ref
      .read(downloadTasksProvider)
      .maybeWhen(
        data: (tasks) => tasks
            .where((task) => selectedTaskIds.contains(task.taskId))
            .toList(),
        orElse: () => <DownloadTask>[],
      );

  bool _batchActionEnabled(String action) {
    final tasks = _selectedTasks();
    if (tasks.isEmpty) return false;
    return switch (action) {
      'pause' => tasks.any(
        (task) =>
            task.status == DownloadTaskStatus.downloading ||
            task.status == DownloadTaskStatus.queued,
      ),
      'resume' => tasks.any(
        (task) =>
            task.status == DownloadTaskStatus.paused ||
            task.status == DownloadTaskStatus.failed,
      ),
      'delete' => true,
      _ => false,
    };
  }

  Widget _batchActionBar() {
    Widget action({
      required String name,
      required String action,
      required IconData icon,
    }) {
      final enabled = !batchBusy && _batchActionEnabled(action);
      return TextButton.icon(
        onPressed: enabled ? () => _handleBatchAction(action) : null,
        icon: Icon(icon, size: 18),
        label: Text(name),
        style: action == 'delete'
            ? TextButton.styleFrom(foregroundColor: context.appColors.error)
            : null,
      );
    }

    return BottomAppBar(
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  selectedTaskIds.isEmpty
                      ? '请选择'
                      : '${selectedTaskIds.length} 项',
                  style: TextStyle(
                    color: context.appColors.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              action(name: '暂停', action: 'pause', icon: Icons.pause),
              action(name: '继续', action: 'resume', icon: Icons.play_arrow),
              action(name: '删除', action: 'delete', icon: Icons.delete_outline),
              TextButton(
                onPressed: batchBusy ? null : _exitEditing,
                child: Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, List<DownloadTask>> _groupTasks(List<DownloadTask> tasks) {
    final groups = <String, List<DownloadTask>>{};
    for (final task in tasks) {
      final key = '${task.sourceId}|${task.sourceVideoId}|${task.title}';
      groups.putIfAbsent(key, () => []).add(task);
    }
    // 组内按集数排序（从剧集名提取数字，如「第10集」），无数字时按名称/创建时间。
    for (final list in groups.values) {
      list.sort((a, b) {
        final byRank = _episodeRank(a).compareTo(_episodeRank(b));
        if (byRank != 0) return byRank;
        final byName = a.episodeName.compareTo(b.episodeName);
        if (byName != 0) return byName;
        return a.createdAtMs.compareTo(b.createdAtMs);
      });
    }
    return groups;
  }

  static int _episodeRank(DownloadTask task) {
    final match = RegExp(r'\d+').firstMatch(task.episodeName);
    return match == null ? 1 << 30 : int.parse(match.group(0)!);
  }

  Widget _videoGroup(
    BuildContext context,
    String groupKey,
    List<DownloadTask> tasks,
  ) {
    final title = tasks.first.title;
    final completed = tasks
        .where((task) => task.status == DownloadTaskStatus.completed)
        .length;
    final expanded = expandedGroups.contains(groupKey);
    return Card(
      color: context.appColors.surface,
      margin: EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.fromLTRB(20, 4, 16, 4),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            subtitle: Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '${tasks.length} 集 · 完成 $completed 集',
                style: TextStyle(
                  fontSize: 12,
                  color: context.appColors.secondary,
                ),
              ),
            ),
            trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() {
              if (expanded) {
                expandedGroups.remove(groupKey);
                manuallyCollapsedGroups.add(groupKey);
              } else {
                expandedGroups.add(groupKey);
                manuallyCollapsedGroups.remove(groupKey);
              }
            }),
          ),
          if (expanded) ...[
            for (var i = 0; i < tasks.length; i++) ...[
              _taskCard(context, tasks[i], nested: true),
              if (i < tasks.length - 1)
                Divider(
                  height: 1,
                  indent: 24,
                  endIndent: 16,
                  color: context.appColors.divider,
                ),
            ],
          ],
        ],
      ),
    );
  }

  void _enterEditing() => setState(() {
    editing = true;
    selectedTaskIds.clear();
  });

  void _exitEditing() => setState(() {
    editing = false;
    selectedTaskIds.clear();
  });

  void _toggleTaskSelection(DownloadTask task) {
    setState(() {
      if (!selectedTaskIds.add(task.taskId)) {
        selectedTaskIds.remove(task.taskId);
      }
    });
  }

  List<DownloadTask> _visibleTasks() => ref
      .read(downloadTasksProvider)
      .maybeWhen(
        data: (value) {
          final activeFilter = filter ?? _initialFilter(value);
          return value
              .where((task) => _matchesFilter(task, activeFilter))
              .toList();
        },
        orElse: () => <DownloadTask>[],
      );

  bool _allVisibleSelected() {
    final tasks = _visibleTasks();
    return tasks.isNotEmpty &&
        tasks.every((task) => selectedTaskIds.contains(task.taskId));
  }

  void _toggleSelectAllVisible() {
    final tasks = _visibleTasks();
    final taskIds = tasks.map((task) => task.taskId).toList();
    final shouldDeselect =
        taskIds.isNotEmpty && taskIds.every(selectedTaskIds.contains);
    setState(() {
      if (shouldDeselect) {
        selectedTaskIds.removeAll(taskIds);
      } else {
        selectedTaskIds.addAll(taskIds);
      }
    });
  }

  /// 删除确认弹窗：返回是否确认，以及是否连带删除本地文件。
  Future<({bool confirmed, bool deleteCache})> _confirmDelete({
    required String title,
    required String message,
  }) async {
    var deleteCache = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              CheckboxListTile(
                value: deleteCache,
                onChanged: (value) =>
                    setDialogState(() => deleteCache = value ?? false),
                title: Text('同时删除本地文件'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('删除'),
            ),
          ],
        ),
      ),
    );
    return (confirmed: confirmed ?? false, deleteCache: deleteCache);
  }

  Future<void> _handleBatchAction(String action) async {
    if (batchBusy || selectedTaskIds.isEmpty) return;
    var deleteCache = false;
    if (action == 'delete') {
      final result = await _confirmDelete(
        title: '批量删除任务记录？',
        message: '将删除 ${selectedTaskIds.length} 条任务记录。',
      );
      if (!result.confirmed) return;
      deleteCache = result.deleteCache;
    }
    if (!mounted) return;
    setState(() => batchBusy = true);
    try {
      final manager = await _manager(ref);
      final tasks = ref
          .read(downloadTasksProvider)
          .maybeWhen(
            data: (value) => value
                .where((task) => selectedTaskIds.contains(task.taskId))
                .toList(),
            orElse: () => <DownloadTask>[],
          );
      for (final task in tasks) {
        switch (action) {
          case 'pause':
            if (task.status == DownloadTaskStatus.downloading ||
                task.status == DownloadTaskStatus.queued) {
              await manager.pause(task.taskId);
            }
          case 'resume':
            if (task.status == DownloadTaskStatus.paused ||
                task.status == DownloadTaskStatus.failed) {
              await manager.resume(task.taskId);
            }
          case 'delete':
            await manager.removeTask(task.taskId, deleteCache: deleteCache);
        }
      }
      if (mounted) {
        showAppToast(context, '批量操作已完成');
        _exitEditing();
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '批量操作失败，请重试');
      }
    } finally {
      if (mounted) setState(() => batchBusy = false);
    }
  }

  static _DownloadFilter _initialFilter(List<DownloadTask> tasks) {
    final hasUnfinished = tasks.any(
      (task) =>
          task.status == DownloadTaskStatus.downloading ||
          task.status == DownloadTaskStatus.queued ||
          task.status == DownloadTaskStatus.paused,
    );
    if (hasUnfinished) return _DownloadFilter.active;
    final hasCompleted = tasks.any(
      (task) => task.status == DownloadTaskStatus.completed,
    );
    return hasCompleted ? _DownloadFilter.completed : _DownloadFilter.all;
  }

  bool _matchesFilter(DownloadTask task, _DownloadFilter activeFilter) =>
      switch (activeFilter) {
        _DownloadFilter.all => true,
        _DownloadFilter.active =>
          task.status == DownloadTaskStatus.downloading ||
              task.status == DownloadTaskStatus.queued ||
              task.status == DownloadTaskStatus.paused,
        _DownloadFilter.completed =>
          task.status == DownloadTaskStatus.completed,
        _DownloadFilter.failed =>
          task.status == DownloadTaskStatus.failed ||
              task.status == DownloadTaskStatus.cancelled,
      };

  int _filterCount(List<DownloadTask> tasks, _DownloadFilter value) =>
      tasks.where((task) {
        switch (value) {
          case _DownloadFilter.all:
            return true;
          case _DownloadFilter.active:
            return task.status == DownloadTaskStatus.downloading ||
                task.status == DownloadTaskStatus.queued ||
                task.status == DownloadTaskStatus.paused;
          case _DownloadFilter.completed:
            return task.status == DownloadTaskStatus.completed;
          case _DownloadFilter.failed:
            return task.status == DownloadTaskStatus.failed ||
                task.status == DownloadTaskStatus.cancelled;
        }
      }).length;

  Widget _filterBar(List<DownloadTask> tasks, _DownloadFilter activeFilter) {
    const labels = {
      _DownloadFilter.all: '全部',
      _DownloadFilter.active: '未完成',
      _DownloadFilter.completed: '已完成',
      _DownloadFilter.failed: '异常',
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final value in _DownloadFilter.values)
            Padding(
              padding: EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('${labels[value]} ${_filterCount(tasks, value)}'),
                selected: activeFilter == value,
                onSelected: (_) => setState(() => filter = value),
                showCheckmark: false,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pauseAll() async {
    if (batchBusy) return;
    setState(() => batchBusy = true);
    try {
      await (await _manager(ref)).pauseAll();
    } catch (_) {
      if (mounted) {
        showAppToast(context, '批量暂停失败，请重试');
      }
    } finally {
      if (mounted) setState(() => batchBusy = false);
    }
  }

  Future<void> _resumeAll() async {
    if (batchBusy) return;
    setState(() => batchBusy = true);
    try {
      final manager = await _manager(ref);
      final tasks = ref
          .read(downloadTasksProvider)
          .maybeWhen(data: (value) => value, orElse: () => <DownloadTask>[]);
      for (final task in tasks) {
        if (task.status == DownloadTaskStatus.paused ||
            task.status == DownloadTaskStatus.failed) {
          await manager.resume(task.taskId);
        }
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '批量恢复失败，请重试');
      }
    } finally {
      if (mounted) setState(() => batchBusy = false);
    }
  }

  Future<void> _runTaskAction(
    DownloadTask task,
    Future<void> Function(DownloadTaskManager manager) action,
  ) async {
    if (busyTaskIds.contains(task.taskId)) return;
    setState(() => busyTaskIds.add(task.taskId));
    try {
      await action(await _manager(ref));
    } catch (_) {
      if (mounted) {
        showAppToast(context, '操作失败，请重试');
      }
    } finally {
      if (mounted) setState(() => busyTaskIds.remove(task.taskId));
    }
  }

  Widget _summary(List<DownloadTask> tasks) {
    final transferring = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.downloading ||
              task.status == DownloadTaskStatus.queued,
        )
        .toList();
    final speed = transferring.fold<int>(
      0,
      (sum, task) => sum + task.speedBytesPerSecond,
    );
    final resumable = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.paused ||
              task.status == DownloadTaskStatus.failed,
        )
        .length;
    final downloadedBytes = tasks.fold<int>(
      0,
      (sum, task) => sum + task.downloadedBytes,
    );
    return Card(
      color: context.appColors.elevated,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final speedView = transferring.isEmpty
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '当前状态',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColors.secondary,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '暂无进行中的下载',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '当前速度',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.appColors.secondary,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            _formatSpeed(speed),
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: context.appColors.accentForeground,
                            ),
                          ),
                        ],
                      );
                final downloadedView = Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '已下载',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.appColors.secondary,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      _formatBytes(downloadedBytes),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                );
                final batchActionStyle = OutlinedButton.styleFrom(
                  foregroundColor: context.appColors.text,
                  disabledForegroundColor: context.appColors.secondary,
                  backgroundColor: context.appColors.accent.withValues(
                    alpha: 0.10,
                  ),
                  side: BorderSide(
                    color: context.appColors.accentForeground.withValues(
                      alpha: 0.45,
                    ),
                  ),
                  textStyle: TextStyle(fontWeight: FontWeight.w600),
                );
                final actions = Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (resumable > 0)
                      OutlinedButton.icon(
                        onPressed: batchBusy ? null : _resumeAll,
                        icon: Icon(Icons.play_arrow, size: 18),
                        label: Text('全部继续'),
                        style: batchActionStyle,
                      ),
                    if (transferring.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: batchBusy ? null : _pauseAll,
                        icon: Icon(Icons.pause, size: 18),
                        label: Text('全部暂停'),
                        style: batchActionStyle,
                      ),
                  ],
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(child: speedView),
                          SizedBox(width: 16),
                          downloadedView,
                        ],
                      ),
                      if (transferring.isNotEmpty || resumable > 0) ...[
                        SizedBox(height: 12),
                        actions,
                      ],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: speedView),
                    downloadedView,
                    if (transferring.isNotEmpty || resumable > 0) ...[
                      SizedBox(width: 16),
                      actions,
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(
    BuildContext context,
    DownloadTask task, {
    bool nested = false,
  }) {
    final taskBusy = busyTaskIds.contains(task.taskId);
    final pausing =
        taskBusy &&
        (task.status == DownloadTaskStatus.downloading ||
            task.status == DownloadTaskStatus.queued);
    final hasKnownProgress =
        task.totalBytes > 0 || task.expectedResourceCount > 0;
    final progress = task.status == DownloadTaskStatus.completed
        ? 1.0
        : task.totalBytes > 0
        ? (task.downloadedBytes / task.totalBytes).clamp(0.0, 1.0)
        : task.expectedResourceCount > 0
        ? (task.completedResourceCount / task.expectedResourceCount).clamp(
            0.0,
            1.0,
          )
        : task.status == DownloadTaskStatus.downloading
        ? null
        : 0.0;
    final isCompleted = task.status == DownloadTaskStatus.completed;
    final showProgress =
        hasKnownProgress &&
        switch (task.status) {
          DownloadTaskStatus.downloading ||
          DownloadTaskStatus.queued ||
          DownloadTaskStatus.paused => true,
          _ => false,
        };
    final displayedBytes = isCompleted && task.totalBytes > 0
        ? task.totalBytes
        : task.downloadedBytes;
    final sizeText = _formatBytes(displayedBytes);
    final progressText = progress == null
        ? null
        : '${(progress * 100).round()}%';
    final metaText = switch (task.status) {
      DownloadTaskStatus.completed => sizeText,
      DownloadTaskStatus.failed =>
        '${downloadFailureText(task.error)} · $sizeText',
      DownloadTaskStatus.cancelled => '已取消 · $sizeText',
      DownloadTaskStatus.downloading when _isFinalizing(task) =>
        '整理中 · $sizeText',
      DownloadTaskStatus.downloading when !hasKnownProgress =>
        '正在解析 · $sizeText',
      DownloadTaskStatus.queued when !hasKnownProgress => '等待开始 · $sizeText',
      DownloadTaskStatus.paused when !hasKnownProgress => '等待继续 · $sizeText',
      _ => '$progressText · $sizeText',
    };
    final showSpeed = switch (task.status) {
      DownloadTaskStatus.downloading || DownloadTaskStatus.queued => true,
      _ => false,
    };
    final VoidCallback? primaryAction = editing || taskBusy
        ? null
        : switch (task.status) {
            DownloadTaskStatus.downloading ||
            DownloadTaskStatus.queued => () => _runTaskAction(
              task,
              (manager) => manager.pause(task.taskId, waitUntilPaused: true),
            ),
            DownloadTaskStatus.paused ||
            DownloadTaskStatus.failed => () => _runTaskAction(
              task,
              (manager) => manager.resume(task.taskId),
            ),
            DownloadTaskStatus.completed => () => _playTask(context, ref, task),
            DownloadTaskStatus.cancelled => null,
          };
    Widget? action;
    if (!editing) {
      action = switch (task.status) {
        DownloadTaskStatus.downloading ||
        DownloadTaskStatus.queued => IconButton(
          key: ValueKey('download-pause-${task.taskId}'),
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints.tightFor(width: 36, height: 32),
          padding: EdgeInsets.zero,
          tooltip: pausing ? '暂停中' : '暂停',
          onPressed: primaryAction,
          icon: pausing
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: context.appColors.secondary,
                  ),
                )
              : Icon(Icons.pause, size: 22),
        ),
        DownloadTaskStatus.paused || DownloadTaskStatus.failed => IconButton(
          key: ValueKey('download-resume-${task.taskId}'),
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints.tightFor(width: 36, height: 32),
          padding: EdgeInsets.zero,
          tooltip: task.status == DownloadTaskStatus.failed ? '重试' : '继续',
          onPressed: primaryAction,
          icon: Icon(Icons.play_arrow, size: 24),
        ),
        DownloadTaskStatus.completed => IconButton(
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints.tightFor(width: 36, height: 32),
          padding: EdgeInsets.zero,
          tooltip: '播放',
          onPressed: primaryAction,
          icon: Icon(Icons.play_circle_outline, size: 24),
        ),
        DownloadTaskStatus.cancelled => null,
      };
    }
    return Card(
      color: nested ? Colors.transparent : context.appColors.surface,
      elevation: nested ? 0 : null,
      margin: EdgeInsets.only(bottom: nested ? 0 : 10),
      child: InkWell(
        key: ValueKey('download-task-row-${task.taskId}'),
        onTap: editing ? () => _toggleTaskSelection(task) : primaryAction,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            nested ? 24 : 16,
            nested ? 6 : 12,
            8,
            nested ? 6 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (editing)
                    Checkbox(
                      value: selectedTaskIds.contains(task.taskId),
                      onChanged: (_) => _toggleTaskSelection(task),
                    ),
                  Expanded(
                    child: Text(
                      nested
                          ? task.episodeName
                          : '${task.title} · ${task.episodeName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: nested ? 15 : 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (action != null) ...[SizedBox(width: 4), action],
                ],
              ),
              if (showProgress) ...[
                SizedBox(height: nested ? 2 : 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: context.appColors.divider,
                    color: context.appColors.accent,
                  ),
                ),
              ],
              SizedBox(height: nested ? 3 : 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      metaText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: task.status == DownloadTaskStatus.failed
                            ? context.appColors.error
                            : context.appColors.secondary,
                      ),
                    ),
                  ),
                  if (showSpeed) ...[
                    SizedBox(width: 12),
                    Text(
                      '速度 ${_formatSpeed(task.speedBytesPerSecond)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.appColors.secondary,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playTask(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    final manager = await _manager(ref);
    final selection = await manager.selectionForTask(task);
    if (!context.mounted) return;
    if (selection == null || !selection.hasStableIdentity) {
      showAppToast(context, '无法恢复该下载的播放信息，请重新下载');
      return;
    }
    final episode = selection.episode;
    final video = Video(
      id: task.sourceVideoId,
      title: task.title,
      sourceId: task.sourceId,
      sourceVideoId: task.sourceVideoId,
      episodes: [episode],
      playbackLines: [
        PlaybackLine(
          id: task.playbackLineIdentity,
          name: task.playbackLineIdentity,
          identity: task.playbackLineIdentity,
          episodes: [episode],
        ),
      ],
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PlayerPage(video: video, episode: episode, selection: selection),
      ),
    );
  }

  Future<DownloadTaskManager> _manager(WidgetRef ref) =>
      ref.read(downloadManagerProvider.future);

  static bool _isFinalizing(DownloadTask task) =>
      task.status == DownloadTaskStatus.downloading &&
      task.expectedResourceCount > 0 &&
      task.completedResourceCount >= task.expectedResourceCount;

  static String _formatSpeed(int bytes) => '${_formatBytes(bytes)}/s';

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
