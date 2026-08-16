import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/cache/download_providers.dart';
import '../data/cache/download_task_manager.dart';
import '../domain/video.dart';
import 'cache_management_page.dart';
import 'player_page.dart';

class DownloadManagementPage extends ConsumerWidget {
  const DownloadManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadTasksProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          IconButton(
            tooltip: '自动缓存',
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
        data: (items) => items.isEmpty
            ? const AppEmptyView(
                icon: Icons.download_outlined,
                message: '还没有下载任务\n在详情页或播放页点击下载',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _summary(items),
                  const SizedBox(height: 12),
                  for (final task in items) _taskCard(context, ref, task),
                ],
              ),
      ),
    );
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
    final downloaded = tasks.fold<int>(
      0,
      (sum, task) => sum + task.downloadedBytes,
    );
    final total = tasks.fold<int>(0, (sum, task) => sum + task.totalBytes);
    final hasUnknownTotal = tasks.any(
      (task) =>
          task.status != DownloadTaskStatus.completed && task.totalBytes <= 0,
    );
    final completedResources = tasks.fold<int>(
      0,
      (sum, task) => sum + task.completedResourceCount,
    );
    final expectedResources = tasks.fold<int>(
      0,
      (sum, task) => sum + task.expectedResourceCount,
    );
    final sizeText = total > 0 && !hasUnknownTotal
        ? '${_formatBytes(downloaded)} / ${_formatBytes(total)}'
        : '${_formatBytes(downloaded)} · ${_resourceProgressText(completedResources, expectedResources)}';
    final progress = total > 0 && !hasUnknownTotal
        ? (downloaded / total).clamp(0.0, 1.0)
        : expectedResources > 0
        ? (completedResources / expectedResources).clamp(0.0, 1.0)
        : null;
    return Card(
      color: AppColors.elevated,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${active.length} 个进行中的任务',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '$sizeText · ${_formatSpeed(speed)}',
              style: const TextStyle(color: AppColors.secondary, fontSize: 12),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
            ] else if (active.isNotEmpty) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _taskCard(BuildContext context, WidgetRef ref, DownloadTask task) {
    final progress = task.totalBytes > 0
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
    final status = _statusText(task);
    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: task.status == DownloadTaskStatus.completed
            ? () => _playTask(context, ref, task)
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${task.title} · ${task.episodeName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(status, style: const TextStyle(fontSize: 12)),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                sizeText,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.secondary,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '速度 ${_formatSpeed(task.speedBytesPerSecond)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.secondary,
                    ),
                  ),
                  const Spacer(),
                  if (task.status == DownloadTaskStatus.downloading ||
                      task.status == DownloadTaskStatus.queued)
                    IconButton(
                      tooltip: '暂停',
                      onPressed: () => _manager(
                        ref,
                      ).then((manager) => manager.pause(task.taskId)),
                      icon: const Icon(Icons.pause),
                    )
                  else if (task.status == DownloadTaskStatus.paused ||
                      task.status == DownloadTaskStatus.failed)
                    IconButton(
                      tooltip: task.status == DownloadTaskStatus.failed
                          ? '重试'
                          : '继续',
                      onPressed: () => _manager(
                        ref,
                      ).then((manager) => manager.resume(task.taskId)),
                      icon: const Icon(Icons.play_arrow),
                    ),
                  if (task.status != DownloadTaskStatus.completed &&
                      task.status != DownloadTaskStatus.cancelled)
                    IconButton(
                      tooltip: '取消',
                      onPressed: () => _manager(
                        ref,
                      ).then((manager) => manager.cancel(task.taskId)),
                      icon: const Icon(Icons.close),
                    ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法恢复该下载的播放信息，请重新下载')));
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

  static String _statusText(DownloadTask task) => switch (task.status) {
    DownloadTaskStatus.queued => '排队中',
    DownloadTaskStatus.downloading => '下载中',
    DownloadTaskStatus.paused => '已暂停',
    DownloadTaskStatus.completed => '已完成',
    DownloadTaskStatus.failed => '失败 · ${downloadFailureText(task.error)}',
    DownloadTaskStatus.cancelled => '已取消',
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
