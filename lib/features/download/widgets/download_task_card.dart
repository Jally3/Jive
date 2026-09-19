import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme.dart';
import '../../../data/download/download_network_policy.dart';
import '../../../data/download/download_task_manager.dart';
import '../../../data/history_repository.dart';
import '../../../data/offline_progress_repository.dart';
import '../../../shared/format_utils.dart';

/// 下载管理页的按视频分组卡片：标题行 + 可折叠的剧集任务列表。
/// 任务行的状态（编辑/选中/忙碌）由页面通过 builder 注入。
class DownloadVideoGroup extends StatelessWidget {
  const DownloadVideoGroup({
    super.key,
    required this.title,
    required this.tasks,
    required this.expanded,
    required this.onToggle,
    required this.taskCardBuilder,
  });

  final String title;
  final List<DownloadTask> tasks;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget Function(DownloadTask task) taskCardBuilder;

  @override
  Widget build(BuildContext context) {
    final completed = tasks
        .where((task) => task.status == DownloadTaskStatus.completed)
        .length;
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
            onTap: onToggle,
          ),
          if (expanded) ...[
            for (var i = 0; i < tasks.length; i++) ...[
              taskCardBuilder(tasks[i]),
              if (i < tasks.length - 1)
                Divider(
                  height: 1,
                  indent: 32,
                  endIndent: 24,
                  color: context.appColors.divider.withValues(alpha: 0.55),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 单个下载任务卡片：进度、状态文案（含离线观看进度）、主操作按钮。
class DownloadTaskCard extends ConsumerWidget {
  const DownloadTaskCard({
    super.key,
    required this.task,
    required this.nested,
    required this.editing,
    required this.selected,
    required this.busy,
    required this.onToggleSelection,
    required this.onPause,
    required this.onResume,
    required this.onPlay,
  });

  final DownloadTask task;

  /// 嵌在视频分组内时去掉卡片自带边距，展示为剧集行。
  final bool nested;
  final bool editing;
  final bool selected;
  final bool busy;

  final VoidCallback onToggleSelection;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onPlay;

  static bool isFinalizing(DownloadTask task) =>
      task.status == DownloadTaskStatus.downloading &&
      task.expectedResourceCount > 0 &&
      task.completedResourceCount >= task.expectedResourceCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taskBusy = busy;
    final pausing =
        taskBusy &&
        (task.status == DownloadTaskStatus.downloading ||
            task.status == DownloadTaskStatus.queued);
    final hasKnownProgress =
        task.totalBytes > 0 || task.expectedResourceCount > 0;
    final networkPaused =
        task.status == DownloadTaskStatus.paused &&
        task.pauseReason == DownloadPauseReason.network;
    final networkAccess = ref.watch(downloadNetworkAccessProvider);
    final networkWaitText =
        networkAccess == DownloadNetworkAccess.cellularBlocked
        ? '等待 Wi-Fi'
        : '等待网络';
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
    var watched = ref
        .watch(offlineProgressProvider)
        .value?[offlineProgressKeyForTask(task)];
    if (watched == null) {
      final latest = (ref.watch(watchHistoryProvider).value ?? const [])
          .where(
            (record) =>
                record.video.sourceId == task.sourceId &&
                record.video.sourceVideoId == task.sourceVideoId &&
                record.playbackLineIdentity == task.playbackLineIdentity &&
                record.episodeIdentity == task.episodeIdentity,
          )
          .firstOrNull;
      if (latest != null) {
        watched = OfflineEpisodeProgress(
          key: offlineProgressKeyForTask(task),
          positionMs: latest.positionMs,
          durationMs: latest.durationMs,
          updatedAt: latest.updatedAt,
          completed: latest.completed,
        );
      }
    }
    final watchedEnough = watched != null && watched.progress >= 2 / 3;
    final showProgress =
        hasKnownProgress &&
        switch (task.status) {
          DownloadTaskStatus.downloading ||
          DownloadTaskStatus.queued ||
          DownloadTaskStatus.paused => true,
          DownloadTaskStatus.completed => watched != null,
          _ => false,
        };
    final displayedBytes = isCompleted && task.totalBytes > 0
        ? task.totalBytes
        : task.downloadedBytes;
    final sizeText = formatBytes(displayedBytes);
    final progressText = progress == null
        ? null
        : '${(progress * 100).round()}%';
    final statusText = switch (task.status) {
      DownloadTaskStatus.completed when watched?.completed == true => '已看完',
      DownloadTaskStatus.completed when watched != null =>
        '看到 ${formatDuration(watched.positionMs)} / ${formatDuration(watched.durationMs)}',
      DownloadTaskStatus.completed => '已下载',
      DownloadTaskStatus.failed => downloadFailureText(task.error),
      DownloadTaskStatus.cancelled => '已取消',
      DownloadTaskStatus.downloading when isFinalizing(task) => '整理中',
      DownloadTaskStatus.downloading when !hasKnownProgress => '正在解析',
      DownloadTaskStatus.queued when !hasKnownProgress => '等待开始',
      DownloadTaskStatus.paused when networkPaused =>
        '$networkWaitText${progressText == null ? '' : ' · $progressText'}',
      DownloadTaskStatus.paused when !hasKnownProgress => '等待继续',
      _ => progressText ?? '',
    };
    final showSpeed = switch (task.status) {
      DownloadTaskStatus.downloading || DownloadTaskStatus.queued => true,
      _ => false,
    };
    final VoidCallback? primaryAction = editing || taskBusy
        ? null
        : switch (task.status) {
            DownloadTaskStatus.downloading ||
            DownloadTaskStatus.queued => onPause,
            DownloadTaskStatus.paused || DownloadTaskStatus.failed => onResume,
            DownloadTaskStatus.completed => onPlay,
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
          tooltip: task.status == DownloadTaskStatus.failed
              ? '重试'
              : networkPaused
              ? '$networkWaitText，点击继续'
              : '继续',
          onPressed: primaryAction,
          icon: Icon(Icons.play_arrow, size: 24),
        ),
        DownloadTaskStatus.completed => IconButton(
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          tooltip: '播放',
          onPressed: primaryAction,
          style: IconButton.styleFrom(
            backgroundColor: context.appColors.elevated,
            foregroundColor: context.appColors.text,
          ),
          icon: Icon(Icons.play_arrow, size: 22),
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
        onTap: editing ? onToggleSelection : primaryAction,
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
                      value: selected,
                      onChanged: (_) => onToggleSelection(),
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
                        color: watchedEnough
                            ? context.appColors.secondary
                            : context.appColors.text,
                      ),
                    ),
                  ),
                  if (action != null) ...[SizedBox(width: 4), action],
                ],
              ),
              if (showProgress) ...[
                SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: watched?.progress ?? progress,
                    minHeight: 3,
                    backgroundColor: context.appColors.divider,
                    color: watchedEnough
                        ? context.appColors.secondary
                        : context.appColors.accent,
                  ),
                ),
              ],
              SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      statusText,
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
                      '速度 ${formatSpeed(task.speedBytesPerSecond)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.appColors.secondary,
                      ),
                    ),
                  ],
                  SizedBox(width: 12),
                  Text(
                    sizeText,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.appColors.secondary,
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
}
