import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/download/download_providers.dart';
import '../../data/download/download_network_policy.dart';
import '../../data/download/download_screen_awake_preferences.dart';
import '../../data/download/download_task_manager.dart';
import '../../data/offline_progress_repository.dart';
import '../../data/history_repository.dart';
import '../../domain/video.dart';
import '../../domain/playback_selection.dart';
import '../../shared/app_toast.dart';
import '../../shared/format_utils.dart';
import '../../shared/screen_awake_controller.dart';
import '../cache/cache_management_page.dart';
import '../player/player_page.dart';
import 'widgets/download_summary_header.dart';
import 'widgets/download_task_card.dart';

enum _DownloadFilter { all, active, completed, failed }

class DownloadManagementPage extends ConsumerStatefulWidget {
  const DownloadManagementPage({super.key});

  @override
  ConsumerState<DownloadManagementPage> createState() =>
      _DownloadManagementPageState();
}

class _DownloadManagementPageState extends ConsumerState<DownloadManagementPage>
    with RouteAware {
  final Object _screenAwakeOwner = Object();
  late final ScreenAwakeController _screenAwakeController;
  late final RouteObserver<PageRoute<dynamic>> _routeObserver;
  PageRoute<dynamic>? _observedRoute;
  bool _routeVisible = false;
  _DownloadFilter? filter;
  bool _initialFilterScheduled = false;
  final Set<String> busyTaskIds = {};
  final Set<String> selectedTaskIds = {};
  final Set<VideoRef> expandedGroups = {};
  final Set<VideoRef> manuallyCollapsedGroups = {};
  bool batchBusy = false;
  bool editing = false;

  @override
  void initState() {
    super.initState();
    _screenAwakeController = ref.read(screenAwakeControllerProvider);
    _routeObserver = ref.read(screenAwakeRouteObserverProvider);
    ref.listenManual(downloadTasksProvider, (_, _) => _syncScreenAwake());
    ref.listenManual(
      downloadKeepScreenAwakeProvider,
      (_, _) => _syncScreenAwake(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _observedRoute) {
      if (_observedRoute != null) _routeObserver.unsubscribe(this);
      _observedRoute = route;
      _routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPush() => _setRouteVisible(true);

  @override
  void didPopNext() => _setRouteVisible(true);

  @override
  void didPushNext() => _setRouteVisible(false);

  @override
  void didPop() => _setRouteVisible(false);

  void _setRouteVisible(bool visible) {
    _routeVisible = visible;
    _syncScreenAwake();
  }

  void _syncScreenAwake() {
    if (!mounted) return;
    final enabled = ref.read(downloadKeepScreenAwakeProvider).value ?? false;
    final active = ref
        .read(downloadTasksProvider)
        .maybeWhen(
          data: (tasks) => tasks.any(
            (task) =>
                task.status == DownloadTaskStatus.queued ||
                task.status == DownloadTaskStatus.downloading,
          ),
          orElse: () => false,
        );
    unawaited(
      _screenAwakeController.setRequested(
        _screenAwakeOwner,
        enabled && _routeVisible && active,
      ),
    );
  }

  @override
  void dispose() {
    _routeObserver.unsubscribe(this);
    unawaited(_screenAwakeController.release(_screenAwakeOwner));
    super.dispose();
  }

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
      bottomNavigationBar: editing ? _batchActionBar() : null,
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
          final allGroups = _groupTasks(items);
          final groups = {
            for (final group in allGroups.entries)
              if (group.value.any((task) => _matchesFilter(task, activeFilter)))
                group.key: group.value
                    .where((task) => _matchesFilter(task, activeFilter))
                    .toList(),
          };
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
              if (!editing) ...[
                _filterBar(items, activeFilter),
                SizedBox(height: 12),
              ],
              if (visible.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('当前筛选下没有任务')),
                )
              else
                for (final group in groups.entries)
                  _videoGroup(
                    context,
                    group.key,
                    group.value,
                    title: _groupTitle(allGroups[group.key]!),
                  ),
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
      return Expanded(
        child: TextButton.icon(
          onPressed: enabled ? () => _handleBatchAction(action) : null,
          icon: Icon(icon, size: 18),
          label: Text(name),
          style: action == 'delete'
              ? TextButton.styleFrom(foregroundColor: context.appColors.error)
              : null,
        ),
      );
    }

    return BottomAppBar(
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            action(name: '暂停', action: 'pause', icon: Icons.pause),
            action(name: '继续', action: 'resume', icon: Icons.play_arrow),
            action(name: '删除', action: 'delete', icon: Icons.delete_outline),
          ],
        ),
      ),
    );
  }

  Map<VideoRef, List<DownloadTask>> _groupTasks(List<DownloadTask> tasks) {
    final groups = <VideoRef, List<DownloadTask>>{};
    final createdAtByGroup = <VideoRef, int>{};
    for (final task in tasks) {
      final key = VideoRef(
        sourceId: task.sourceId,
        sourceVideoId: task.sourceVideoId,
      );
      groups.putIfAbsent(key, () => []).add(task);
      createdAtByGroup.update(
        key,
        (createdAt) => min(createdAt, task.createdAtMs),
        ifAbsent: () => task.createdAtMs,
      );
    }
    // 组内按集数排序；所有比较相同时仍按任务 ID 固定顺序。
    for (final list in groups.values) {
      list.sort((a, b) {
        final byRank = _episodeRank(a).compareTo(_episodeRank(b));
        if (byRank != 0) return byRank;
        final byName = a.episodeName.compareTo(b.episodeName);
        if (byName != 0) return byName;
        final byCreated = a.createdAtMs.compareTo(b.createdAtMs);
        if (byCreated != 0) return byCreated;
        return a.taskId.compareTo(b.taskId);
      });
    }
    // 下载进度会持续刷新 updatedAtMs，分组顺序只使用创建时间。
    final orderedKeys = groups.keys.toList()
      ..sort((a, b) {
        final byCreated = createdAtByGroup[b]!.compareTo(createdAtByGroup[a]!);
        if (byCreated != 0) return byCreated;
        final bySource = a.sourceId.compareTo(b.sourceId);
        if (bySource != 0) return bySource;
        return a.sourceVideoId.compareTo(b.sourceVideoId);
      });
    return {for (final key in orderedKeys) key: groups[key]!};
  }

  static String _groupTitle(List<DownloadTask> tasks) {
    final firstCreated = tasks.reduce((a, b) {
      final byCreated = a.createdAtMs.compareTo(b.createdAtMs);
      if (byCreated != 0) return byCreated < 0 ? a : b;
      return a.taskId.compareTo(b.taskId) <= 0 ? a : b;
    });
    return firstCreated.title;
  }

  static int _episodeRank(DownloadTask task) {
    final match = RegExp(r'\d+').firstMatch(task.episodeName);
    return match == null ? 1 << 30 : int.parse(match.group(0)!);
  }

  Widget _videoGroup(
    BuildContext context,
    VideoRef groupKey,
    List<DownloadTask> tasks, {
    required String title,
  }) {
    return DownloadVideoGroup(
      key: ValueKey(groupKey),
      title: title,
      tasks: tasks,
      expanded: expandedGroups.contains(groupKey),
      editing: editing,
      selectedTaskCount: tasks
          .where((task) => selectedTaskIds.contains(task.taskId))
          .length,
      onToggleSelection: () => _toggleGroupSelection(tasks),
      onLongPress: () => _enterEditingWithTasks(tasks),
      onToggle: () => setState(() {
        if (expandedGroups.contains(groupKey)) {
          expandedGroups.remove(groupKey);
          manuallyCollapsedGroups.add(groupKey);
        } else {
          expandedGroups.add(groupKey);
          manuallyCollapsedGroups.remove(groupKey);
        }
      }),
      taskCardBuilder: (task) => _taskCard(task),
    );
  }

  void _enterEditing() => setState(() {
    editing = true;
    selectedTaskIds.clear();
  });

  void _enterEditingWithTasks(Iterable<DownloadTask> tasks) => setState(() {
    editing = true;
    selectedTaskIds
      ..clear()
      ..addAll(tasks.map((task) => task.taskId));
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

  void _toggleGroupSelection(List<DownloadTask> tasks) {
    final taskIds = tasks.map((task) => task.taskId).toList();
    final allSelected = taskIds.every(selectedTaskIds.contains);
    setState(() {
      if (allSelected) {
        selectedTaskIds.removeAll(taskIds);
      } else {
        selectedTaskIds.addAll(taskIds);
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

  /// 删除下载任务时始终一并删除对应的本地文件。
  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
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
      ) ??
      false;

  Future<void> _handleBatchAction(String action) async {
    if (batchBusy || selectedTaskIds.isEmpty) return;
    if (action == 'delete') {
      final confirmed = await _confirmDelete(
        title: '批量删除下载？',
        message: '将删除 ${selectedTaskIds.length} 个下载任务及其本地文件，此操作无法撤销。',
      );
      if (!confirmed) return;
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
            break;
          case 'delete':
            await manager.removeTask(task.taskId);
            await ref.read(offlineProgressRepositoryProvider).removeTask(task);
        }
      }
      if (action == 'resume') {
        await _resumeTasksWithPolicy(
          manager,
          tasks
              .where(
                (task) =>
                    task.status == DownloadTaskStatus.paused ||
                    task.status == DownloadTaskStatus.failed,
              )
              .toList(),
        );
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
      await _resumeTasksWithPolicy(
        manager,
        tasks
            .where(
              (task) =>
                  task.status == DownloadTaskStatus.paused ||
                  task.status == DownloadTaskStatus.failed,
            )
            .toList(),
      );
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

  Future<void> _resumeTask(DownloadTask task) => _runTaskAction(
    task,
    (manager) async => _resumeTasksWithPolicy(manager, [task]),
  );

  Future<void> _resumeTasksWithPolicy(
    DownloadTaskManager manager,
    List<DownloadTask> tasks,
  ) async {
    final blocked = <DownloadTask>[];
    var unavailable = false;
    for (final task in tasks) {
      final result = await manager.resume(task.taskId);
      switch (result) {
        case DownloadResumeResult.started:
          break;
        case DownloadResumeResult.blockedByCellular:
          blocked.add(task);
        case DownloadResumeResult.unavailable:
          unavailable = true;
      }
    }
    if (unavailable && mounted) {
      showAppToast(context, '当前无网络，连接后将自动继续');
    }
    if (blocked.isEmpty || !mounted) return;

    final allowAlways = await _confirmCellularResume(blocked);
    if (allowAlways == null || !mounted) return;
    if (allowAlways) {
      await ref.read(allowCellularDownloadsProvider.notifier).setAllowed(true);
    }
    for (final task in blocked) {
      await manager.resume(task.taskId, allowCellularOnce: true);
    }
  }

  Future<bool?> _confirmCellularResume(List<DownloadTask> tasks) async {
    var allowAlways = false;
    final knownRemaining = tasks.every((task) => task.totalBytes > 0);
    final remainingBytes = tasks.fold<int>(
      0,
      (sum, task) => sum + max(0, task.totalBytes - task.downloadedBytes),
    );
    final target = tasks.length == 1
        ? '《${tasks.single.title}》${tasks.single.episodeName}'
        : '${tasks.length} 个任务';
    final estimate = knownRemaining
        ? '，预计还需 ${formatBytes(remainingBytes)}'
        : '';
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('使用蜂窝网络继续下载？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$target$estimate，可能产生流量费用。'),
              SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('以后允许蜂窝网络下载'),
                subtitle: allowAlways ? Text('其他等待 Wi-Fi 的任务也将继续') : null,
                value: allowAlways,
                onChanged: (value) =>
                    setDialogState(() => allowAlways = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, allowAlways),
              child: Text('继续下载'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(List<DownloadTask> tasks) => DownloadSummaryHeader(
    tasks: tasks,
    batchBusy: batchBusy,
    onResumeAll: _resumeAll,
    onPauseAll: _pauseAll,
  );

  Widget _taskCard(DownloadTask task) => DownloadTaskCard(
    key: ValueKey(task.taskId),
    task: task,
    nested: true,
    editing: editing,
    selected: selectedTaskIds.contains(task.taskId),
    busy: busyTaskIds.contains(task.taskId),
    onToggleSelection: () => _toggleTaskSelection(task),
    onLongPress: () => _enterEditingWithTasks([task]),
    onPause: () => _runTaskAction(
      task,
      (manager) => manager.pause(task.taskId, waitUntilPaused: true),
    ),
    onResume: () => _resumeTask(task),
    onPlay: () => _playTask(context, ref, task),
  );

  Future<void> _playTask(
    BuildContext context,
    WidgetRef ref,
    DownloadTask task,
  ) async {
    final manager = await _manager(ref);
    final tasks =
        manager.tasks
            .where(
              (item) =>
                  item.status == DownloadTaskStatus.completed &&
                  item.sourceId == task.sourceId &&
                  item.sourceVideoId == task.sourceVideoId &&
                  item.playbackLineIdentity == task.playbackLineIdentity,
            )
            .toList()
          ..sort((a, b) {
            final rank = _episodeRank(a).compareTo(_episodeRank(b));
            if (rank != 0) return rank;
            return a.createdAtMs.compareTo(b.createdAtMs);
          });
    final restored = await Future.wait(tasks.map(manager.selectionForTask));
    final selectionsByIdentity = <String, PlaybackSelection>{};
    for (final item in restored.whereType<PlaybackSelection>()) {
      if (item.hasStableIdentity) {
        selectionsByIdentity.putIfAbsent(item.episodeIdentity, () => item);
      }
    }
    final selections = selectionsByIdentity.values.toList();
    final selection = selections
        .where((item) => item.episodeIdentity == task.episodeIdentity)
        .firstOrNull;
    if (!context.mounted) return;
    if (selection == null || !selection.hasStableIdentity) {
      showAppToast(context, '无法恢复该下载的播放信息，请重新下载');
      return;
    }
    final episode = selection.episode;
    final episodes = selections.map((item) => item.episode).toList();
    final progress = ref.read(offlineProgressProvider).value ?? const {};
    final latestHistory = ref.read(watchHistoryProvider).value ?? const [];
    final resumePositions = <String, Duration>{};
    for (final item in selections) {
      final record =
          progress[offlineProgressKey(
            sourceId: item.sourceId,
            sourceVideoId: item.sourceVideoId,
            playbackLineIdentity: item.playbackLineIdentity,
            episodeIdentity: item.episodeIdentity,
          )];
      final history = latestHistory
          .where(
            (entry) =>
                entry.video.sourceId == item.sourceId &&
                entry.video.sourceVideoId == item.sourceVideoId &&
                entry.playbackLineIdentity == item.playbackLineIdentity &&
                entry.episodeIdentity == item.episodeIdentity,
          )
          .firstOrNull;
      final completed = record?.completed ?? history?.completed ?? false;
      final positionMs = record?.positionMs ?? history?.positionMs;
      if (positionMs != null && !completed) {
        resumePositions[item.episodeIdentity] = Duration(
          milliseconds: positionMs,
        );
      }
    }
    final video = Video(
      id: task.sourceVideoId,
      title: task.title,
      sourceId: task.sourceId,
      sourceVideoId: task.sourceVideoId,
      episodes: episodes,
      playbackLines: [
        PlaybackLine(
          id: task.playbackLineIdentity,
          name: task.playbackLineIdentity,
          identity: task.playbackLineIdentity,
          episodes: episodes,
        ),
      ],
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          video: video,
          episode: episode,
          selection: selection,
          resumePosition:
              resumePositions[selection.episodeIdentity] ?? Duration.zero,
          episodeSelections: {
            for (final item in selections) item.episodeIdentity: item,
          },
          episodeResumePositions: resumePositions,
          offlineOnly: true,
        ),
      ),
    );
  }

  Future<DownloadTaskManager> _manager(WidgetRef ref) =>
      ref.read(downloadManagerProvider.future);
}
