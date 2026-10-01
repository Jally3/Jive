import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme.dart';
import '../../../data/download/download_providers.dart';
import '../../../data/download/download_task_manager.dart';
import '../../../domain/video.dart';
import '../../../shared/app_toast.dart';
import '../../../shared/format_utils.dart';

/// 详情页「选择下载剧集」底部弹层：列出全部剧集与既有下载任务，
/// 勾选后把选中的集号列表交回详情页创建任务。
class DetailDownloadSheet extends StatefulWidget {
  const DetailDownloadSheet({
    super.key,
    required this.video,
    required this.currentEpisodeIndex,
    required this.onOpenManagement,
  });

  final Video video;
  final int currentEpisodeIndex;

  /// 弹层内部 pop 之后再由详情页打开下载管理，保证用页面路由栈。
  final VoidCallback onOpenManagement;

  @override
  State<DetailDownloadSheet> createState() => _DetailDownloadSheetState();
}

class _DetailDownloadSheetState extends State<DetailDownloadSheet> {
  late final Set<int> _checked = {widget.currentEpisodeIndex};

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final tasks = ref.watch(downloadTasksProvider).value ?? [];
        final addedIndexes = <int>{
          for (var index = 0; index < widget.video.episodes.length; index++)
            if (taskForEpisode(
                  tasks,
                  widget.video,
                  widget.video.episodes[index],
                )
                case final task?
                when task.status != DownloadTaskStatus.cancelled)
              index,
        };
        final availableIndexes = {
          for (var index = 0; index < widget.video.episodes.length; index++)
            if (!addedIndexes.contains(index)) index,
        };
        final effectiveChecked = _checked.intersection(availableIndexes);
        final allAvailableSelected =
            availableIndexes.isNotEmpty &&
            effectiveChecked.length == availableIndexes.length;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.7,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选择下载剧集',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: availableIndexes.isEmpty
                            ? null
                            : () {
                                setState(() {
                                  if (allAvailableSelected) {
                                    _checked.clear();
                                  } else {
                                    _checked
                                      ..clear()
                                      ..addAll(availableIndexes);
                                  }
                                });
                              },
                        child: Text(allAvailableSelected ? '取消全选' : '全选'),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '下载时自动跳过广告片段',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.appColors.secondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.video.episodes.length,
                      itemBuilder: (_, index) {
                        final episode = widget.video.episodes[index];
                        final task = taskForEpisode(
                          tasks,
                          widget.video,
                          episode,
                        );
                        final alreadyAdded =
                            task != null &&
                            task.status != DownloadTaskStatus.cancelled;
                        return CheckboxListTile(
                          key: ValueKey('download-episode-$index'),
                          value: alreadyAdded || _checked.contains(index),
                          checkboxShape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          fillColor: alreadyAdded
                              ? WidgetStatePropertyAll(
                                  context.appColors.accentPressed.withValues(
                                    alpha: .2,
                                  ),
                                )
                              : null,
                          title: Text(
                            episode.name,
                            style: alreadyAdded
                                ? TextStyle(color: context.appColors.tertiary)
                                : null,
                          ),
                          subtitle: task == null
                              ? null
                              : Text(
                                  downloadTaskSummary(task),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.appColors.secondary,
                                  ),
                                ),
                          onChanged: (value) {
                            if (alreadyAdded) {
                              showAppToast(context, '已经添加到下载');
                              return;
                            }
                            setState(() {
                              if (value == true) {
                                _checked.add(index);
                              } else {
                                _checked.remove(index);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            key: const ValueKey('download-management-button'),
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onOpenManagement();
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: context.appColors.secondary,
                              side: BorderSide(
                                color: context.appColors.tertiary,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            icon: Icon(Icons.download_done_outlined),
                            label: Text('下载管理'),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: FilledButton.icon(
                            key: const ValueKey('confirm-download-button'),
                            onPressed: effectiveChecked.isEmpty
                                ? null
                                : () => Navigator.pop(
                                    context,
                                    effectiveChecked.toList(),
                                  ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            icon: Icon(Icons.download),
                            label: Text('确认下载（${effectiveChecked.length} 集）'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 该剧集对应的下载任务（优先非取消状态，其次最新一条）。
DownloadTask? taskForEpisode(
  List<DownloadTask> tasks,
  Video video,
  Episode episode,
) {
  final matches = tasks
      .where(
        (task) =>
            task.sourceId == video.sourceId &&
            task.sourceVideoId == video.sourceVideoId &&
            sameDownloadEpisode(task, episode),
      )
      .toList();
  return matches
          .where((task) => task.status != DownloadTaskStatus.cancelled)
          .firstOrNull ??
      matches.firstOrNull;
}

bool sameDownloadEpisode(DownloadTask task, Episode episode) {
  if (task.episodeIdentity.isNotEmpty &&
      episode.identity.isNotEmpty &&
      task.episodeIdentity == episode.identity) {
    return true;
  }
  if (task.episodeId.isNotEmpty &&
      episode.id.isNotEmpty &&
      task.episodeId == episode.id) {
    return true;
  }
  return task.episodeName.trim().isNotEmpty &&
      task.episodeName.trim().toLowerCase() ==
          episode.name.trim().toLowerCase();
}

String downloadTaskSummary(DownloadTask task) {
  final status = switch (task.status) {
    DownloadTaskStatus.queued => '排队中',
    DownloadTaskStatus.downloading => '下载中',
    DownloadTaskStatus.paused => '已暂停',
    DownloadTaskStatus.completed => '已完成',
    DownloadTaskStatus.failed => '失败，可重试',
    DownloadTaskStatus.cancelled => '已取消',
  };
  final progress = task.expectedResourceCount > 0
      ? ' · ${(task.progress * 100).round()}%'
      : '';
  final size = task.totalBytes > 0
      ? ' · ${formatBytes(task.downloadedBytes)}/${formatBytes(task.totalBytes)}'
      : '';
  final speed = task.status == DownloadTaskStatus.downloading
      ? ' · ${formatSpeed(task.speedBytesPerSecond)}'
      : '';
  return '$status$progress$size$speed';
}
