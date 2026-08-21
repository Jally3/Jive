import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/cache/download_providers.dart';
import '../data/cache/download_task_manager.dart';
import '../domain/video.dart';
import '../shared/app_toast.dart';
import 'cache_management_page.dart';
import 'player_page.dart';

enum _DownloadFilter { all, active, completed, failed }

class DownloadManagementPage extends ConsumerStatefulWidget {
  const DownloadManagementPage({super.key});

  @override
  ConsumerState<DownloadManagementPage> createState() =>
      _DownloadManagementPageState();
}

class _DownloadManagementPageState
    extends ConsumerState<DownloadManagementPage> {
  _DownloadFilter filter = _DownloadFilter.all;
  final Set<String> busyTaskIds = {};
  final Set<String> selectedTaskIds = {};
  final Set<String> expandedGroups = {};
  bool batchBusy = false;
  bool editing = false;

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(downloadTasksProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? '已选 ${selectedTaskIds.length} 项' : '下载管理'),
        leading: editing
            ? IconButton(
                tooltip: '退出编辑',
                onPressed: _exitEditing,
                icon: const Icon(Icons.close),
              )
            : null,
        actions: [
          if (editing) ...[
            IconButton(
              tooltip: '全选当前筛选结果',
              onPressed: _selectAllVisible,
              icon: const Icon(Icons.select_all),
            ),
          ] else
            IconButton(
              tooltip: '编辑任务',
              onPressed: _enterEditing,
              icon: const Icon(Icons.edit_outlined),
            ),
          if (!editing)
            IconButton(
              tooltip: '缓存管理',
              icon: const Icon(Icons.storage_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CacheManagementPage()),
              ),
            ),
        ],
      ),
      body: tasks.when(
        loading: () => const AppLoadingView(label: '正在加载下载任务…'),
        error: (_, _) => AppErrorView(
          message: '下载任务加载失败',
          onRetry: () => ref.invalidate(downloadTasksProvider),
        ),
        data: (items) {
          final visible = items.where(_matchesFilter).toList();
          final groups = _groupTasks(visible);
          // 下载中的分组自动展开。在帧后写入状态，避免在 build 期间改状态。
          final autoExpand = groups.entries
              .where(
                (entry) => entry.value.any(
                  (task) => task.status == DownloadTaskStatus.downloading,
                ),
              )
              .map((entry) => entry.key)
              .where((key) => !expandedGroups.contains(key))
              .toList();
          if (autoExpand.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => expandedGroups.addAll(autoExpand));
            });
          }
          if (items.isEmpty) {
            return const AppEmptyView(
              icon: Icons.download_outlined,
              message: '还没有下载任务\n在详情页或播放页点击下载',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _summary(items),
              const SizedBox(height: 12),
              if (editing) _batchActionBar() else _filterBar(items),
              const SizedBox(height: 12),
              if (visible.isEmpty)
                const Padding(
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
        orElse: () => const <DownloadTask>[],
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
      'delete' => tasks.any(
        (task) =>
            task.status != DownloadTaskStatus.downloading &&
            task.status != DownloadTaskStatus.queued,
      ),
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
            ? TextButton.styleFrom(foregroundColor: AppColors.error)
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
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  selectedTaskIds.isEmpty
                      ? '请选择'
                      : '${selectedTaskIds.length} 项',
                  style: const TextStyle(
                    color: AppColors.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              action(name: '暂停', action: 'pause', icon: Icons.pause),
              action(name: '继续', action: 'resume', icon: Icons.play_arrow),
              action(name: '删除', action: 'delete', icon: Icons.delete_outline),
              TextButton(
                onPressed: batchBusy ? null : _exitEditing,
                child: const Text('取消'),
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
    final expanded =
        expandedGroups.contains(groupKey) ||
        tasks.any((task) => task.status == DownloadTaskStatus.downloading);
    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            dense: true,
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('$completed / ${tasks.length} 集已完成'),
            trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() {
              if (expanded) {
                expandedGroups.remove(groupKey);
              } else {
                expandedGroups.add(groupKey);
              }
            }),
          ),
          if (expanded)
            for (final task in tasks) _taskCard(context, task, nested: true),
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

  void _selectAllVisible() {
    final tasks = ref
        .read(downloadTasksProvider)
        .maybeWhen(
          data: (value) => value.where(_matchesFilter),
          orElse: () => const <DownloadTask>[],
        );
    setState(
      () => selectedTaskIds
        ..clear()
        ..addAll(tasks.map((task) => task.taskId)),
    );
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
                title: const Text('同时删除本地文件'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
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
            orElse: () => const <DownloadTask>[],
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
            if (task.status != DownloadTaskStatus.downloading &&
                task.status != DownloadTaskStatus.queued) {
              await manager.removeTask(task.taskId, deleteCache: deleteCache);
            }
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

  bool _matchesFilter(DownloadTask task) => switch (filter) {
    _DownloadFilter.all => true,
    _DownloadFilter.active =>
      task.status == DownloadTaskStatus.downloading ||
          task.status == DownloadTaskStatus.queued ||
          task.status == DownloadTaskStatus.paused,
    _DownloadFilter.completed => task.status == DownloadTaskStatus.completed,
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

  Widget _filterBar(List<DownloadTask> tasks) {
    const labels = {
      _DownloadFilter.all: '全部',
      _DownloadFilter.active: '进行中',
      _DownloadFilter.completed: '已完成',
      _DownloadFilter.failed: '失败/取消',
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final value in _DownloadFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('${labels[value]} ${_filterCount(tasks, value)}'),
                selected: filter == value,
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
          .maybeWhen(
            data: (value) => value,
            orElse: () => const <DownloadTask>[],
          );
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
    final active = tasks.where(
      (task) =>
          task.status == DownloadTaskStatus.downloading ||
          task.status == DownloadTaskStatus.queued,
    );
    final speed = active.fold<int>(
      0,
      (sum, task) => sum + task.speedBytesPerSecond,
    );
    final completed = tasks
        .where((task) => task.status == DownloadTaskStatus.completed)
        .length;
    final failed = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.failed ||
              task.status == DownloadTaskStatus.cancelled,
        )
        .length;
    final resumable = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.paused ||
              task.status == DownloadTaskStatus.failed,
        )
        .length;
    final totalBytes = tasks.fold<int>(0, (sum, task) => sum + task.totalBytes);
    final downloadedBytes = tasks.fold<int>(
      0,
      (sum, task) => sum + task.downloadedBytes,
    );
    final expectedResources = tasks.fold<int>(
      0,
      (sum, task) => sum + task.expectedResourceCount,
    );
    final completedResources = tasks.fold<int>(
      0,
      (sum, task) => sum + task.completedResourceCount,
    );
    final overall = totalBytes > 0
        ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
        : expectedResources > 0
        ? (completedResources / expectedResources).clamp(0.0, 1.0)
        : null;
    Widget stat(String label, String value, {Color? valueColor}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: valueColor ?? AppColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.secondary),
          ),
        ],
      ),
    );
    return Card(
      color: AppColors.elevated,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: active.isEmpty
                      // 没有进行中的下载时不显示速度，避免 0 B/s 的噪音。
                      ? const Text(
                          '当前没有进行中的下载',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.secondary,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '当前速度',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.secondary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatSpeed(speed),
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                ),
                if (active.isNotEmpty || resumable > 0)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (resumable > 0)
                        OutlinedButton.icon(
                          onPressed: batchBusy ? null : _resumeAll,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('全部继续'),
                        ),
                      if (active.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: batchBusy ? null : _pauseAll,
                          icon: const Icon(Icons.pause, size: 18),
                          label: const Text('全部暂停'),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                stat('进行中', '${active.length}'),
                stat('已完成', '$completed'),
                stat(
                  '失败/取消',
                  '$failed',
                  valueColor: failed > 0 ? AppColors.error : null,
                ),
                stat('已下载', _formatBytes(downloadedBytes)),
              ],
            ),
            if (overall != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: overall,
                  minHeight: 6,
                  backgroundColor: AppColors.divider,
                ),
              ),
            ],
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
    // 排队中的任务显示空进度条，避免不定态动画被误解为正在下载。
    final progress = task.status == DownloadTaskStatus.queued
        ? 0.0
        : task.totalBytes > 0
        ? (task.downloadedBytes / task.totalBytes).clamp(0.0, 1.0)
        : task.expectedResourceCount > 0
        ? (task.completedResourceCount / task.expectedResourceCount).clamp(
            0.0,
            1.0,
          )
        : null;
    final sizeText = task.totalBytes > 0
        ? '${_formatBytes(task.downloadedBytes)} / ${_formatBytes(task.totalBytes)}'
        : '${_formatBytes(task.downloadedBytes)} · ${_resourceProgressText(task.completedResourceCount, task.expectedResourceCount)}';
    final statusColor = _statusColor(task.status);
    // 只有下载中的任务显示速度；失败任务显示原因；其余只显示大小/片段。
    final metaText = switch (task.status) {
      DownloadTaskStatus.downloading =>
        '$sizeText · 速度 ${_formatSpeed(task.speedBytesPerSecond)}',
      DownloadTaskStatus.failed =>
        '$sizeText · ${downloadFailureText(task.error)}',
      _ => sizeText,
    };
    return Card(
      color: nested ? Colors.transparent : AppColors.surface,
      elevation: nested ? 0 : null,
      margin: EdgeInsets.only(bottom: nested ? 0 : 10),
      child: InkWell(
        onTap: editing
            ? () => _toggleTaskSelection(task)
            : task.status == DownloadTaskStatus.completed
            ? () => _playTask(context, ref, task)
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
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
                      '${task.title} · ${task.episodeName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 状态 chip：彩色圆点 + 短状态文字，失败原因放到信息行。
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _statusShort(task),
                        style: TextStyle(
                          fontSize: 12,
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: AppColors.divider,
                  color: statusColor,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      metaText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.secondary,
                      ),
                    ),
                  ),
                  if (!editing &&
                      (task.status == DownloadTaskStatus.downloading ||
                          task.status == DownloadTaskStatus.queued))
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '暂停',
                      onPressed: busyTaskIds.contains(task.taskId)
                          ? null
                          : () => _runTaskAction(
                              task,
                              (manager) => manager.pause(task.taskId),
                            ),
                      icon: const Icon(Icons.pause),
                    )
                  else if (!editing &&
                      (task.status == DownloadTaskStatus.paused ||
                          task.status == DownloadTaskStatus.failed))
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: task.status == DownloadTaskStatus.failed
                          ? '重试'
                          : '继续',
                      onPressed: busyTaskIds.contains(task.taskId)
                          ? null
                          : () => _runTaskAction(
                              task,
                              (manager) => manager.resume(task.taskId),
                            ),
                      icon: const Icon(Icons.play_arrow),
                    ),
                  if (!editing &&
                      (task.status == DownloadTaskStatus.downloading ||
                          task.status == DownloadTaskStatus.queued))
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '取消下载',
                      onPressed: busyTaskIds.contains(task.taskId)
                          ? null
                          : () => _confirmCancelTask(task),
                      icon: const Icon(Icons.close),
                    ),
                  if (!editing && task.status == DownloadTaskStatus.completed)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '播放',
                      onPressed: () => _playTask(context, ref, task),
                      icon: const Icon(Icons.play_circle_outline),
                    ),
                  if (!editing &&
                      task.status != DownloadTaskStatus.downloading &&
                      task.status != DownloadTaskStatus.queued)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '删除任务记录',
                      onPressed: busyTaskIds.contains(task.taskId)
                          ? null
                          : () => _confirmRemoveTask(task),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: AppColors.error,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 取消即删除：停止下载并移除任务记录，页面不再保留「已取消」状态。
  Future<void> _confirmCancelTask(DownloadTask task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('取消下载？'),
        content: Text('将停止下载「${task.episodeName}」并删除任务记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('再想想'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消下载'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _runTaskAction(task, (manager) => manager.removeTask(task.taskId));
  }

  Future<void> _confirmRemoveTask(DownloadTask task) async {
    final result = await _confirmDelete(
      title: '删除任务记录？',
      message: '将从下载列表移除「${task.episodeName}」的任务记录。',
    );
    if (!result.confirmed || !mounted) return;
    await _runTaskAction(
      task,
      (manager) =>
          manager.removeTask(task.taskId, deleteCache: result.deleteCache),
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

  /// 短状态文案：失败原因较长，放在任务卡信息行展示，chip 只显示短标签。
  static String _statusShort(DownloadTask task) => switch (task.status) {
    DownloadTaskStatus.queued => '排队中',
    DownloadTaskStatus.downloading => '下载中',
    DownloadTaskStatus.paused => '已暂停',
    DownloadTaskStatus.completed => '已完成',
    DownloadTaskStatus.failed => '失败',
    DownloadTaskStatus.cancelled => '已取消',
  };

  static Color _statusColor(DownloadTaskStatus status) => switch (status) {
    DownloadTaskStatus.queued => AppColors.secondary,
    DownloadTaskStatus.downloading => AppColors.accent,
    DownloadTaskStatus.paused => Colors.orangeAccent,
    DownloadTaskStatus.completed => AppColors.success,
    DownloadTaskStatus.failed => AppColors.error,
    DownloadTaskStatus.cancelled => AppColors.secondary,
  };

  static String _formatSpeed(int bytes) => '${_formatBytes(bytes)}/s';

  static String _resourceProgressText(int completed, int expected) {
    if (expected <= 0) return '片段数计算中';
    return '片段 $completed/$expected';
  }

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
