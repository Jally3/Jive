import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../data/download/download_task_manager.dart';
import '../../../shared/format_utils.dart';

/// 下载管理页顶部的汇总卡片：当前速度/已下载 + 全部暂停/继续快捷操作。
/// 窄屏（<520）纵向堆叠，宽屏横向排布。
class DownloadSummaryHeader extends StatelessWidget {
  const DownloadSummaryHeader({
    super.key,
    required this.tasks,
    required this.batchBusy,
    required this.onResumeAll,
    required this.onPauseAll,
  });

  final List<DownloadTask> tasks;
  final bool batchBusy;
  final VoidCallback onResumeAll;
  final VoidCallback onPauseAll;

  @override
  Widget build(BuildContext context) {
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
    final waitingForNetwork = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.paused &&
              task.pauseReason == DownloadPauseReason.network,
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
                            waitingForNetwork > 0
                                ? '$waitingForNetwork 个任务等待网络'
                                : '暂无进行中的下载',
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
                            formatSpeed(speed),
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
                      formatBytes(downloadedBytes),
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
                        onPressed: batchBusy ? null : onResumeAll,
                        icon: Icon(Icons.play_arrow, size: 18),
                        label: Text('全部继续'),
                        style: batchActionStyle,
                      ),
                    if (transferring.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: batchBusy ? null : onPauseAll,
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
}
