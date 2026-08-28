import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/download/download_providers.dart';
import '../../data/download/download_task_manager.dart';
import '../../data/history_repository.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/playback_progress.dart';
import '../../domain/video.dart';
import '../../domain/watch_record.dart';
import '../../shared/app_toast.dart';
import 'player_page.dart';

Future<bool> confirmDeleteWatchRecord(
  BuildContext context, {
  required String title,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除观看记录？'),
      content: Text('将从最近观看中移除「$title」。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return accepted == true;
}

Future<void> deleteWatchRecord({
  required BuildContext context,
  required WidgetRef ref,
  required WatchRecord record,
}) async {
  final accepted = await confirmDeleteWatchRecord(
    context,
    title: record.video.title,
  );
  if (!accepted) return;
  await ref.read(watchHistoryProvider.notifier).remove(record.video.globalId);
}

/// 按观看记录续播：优先离线下载，否则重新解析播放地址。
Future<void> resumeWatchRecord({
  required BuildContext context,
  required WidgetRef ref,
  required WatchRecord record,
}) async {
  final overlay = Overlay.of(context);
  var dialogOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    final downloadManager = await ref.read(downloadManagerProvider.future);
    final downloadedTask = downloadManager.tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.completed &&
              task.sourceId == record.video.sourceId &&
              task.sourceVideoId == record.video.sourceVideoId &&
              (record.episodeIdentity.isNotEmpty
                  ? task.episodeIdentity == record.episodeIdentity
                  : task.episodeId == record.episodeId ||
                        task.episodeName == record.episodeName),
        )
        .firstOrNull;
    if (downloadedTask != null) {
      final selection = await downloadManager.selectionForTask(downloadedTask);
      if (selection != null && context.mounted) {
        Navigator.pop(context);
        dialogOpen = false;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              video: record.video,
              episode: selection.episode,
              selection: selection,
              resumePosition: PlaybackProgress(
                positionMs: record.positionMs,
                durationMs: record.durationMs,
                completed: record.completed,
              ).resumePosition(),
            ),
          ),
        );
        return;
      }
    }
    final source = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(
          data: (registry) => registry.findById(record.video.sourceId),
          orElse: () => null,
        );
    if (source == null) throw const VideoDataException('未知来源');
    final detail = await ref
        .read(videoRepositoryProvider)
        .resolvePlayback(source, record.video.ref);
    if (!context.mounted) return;
    Navigator.pop(context);
    dialogOpen = false;
    if (detail.episodes.isEmpty) {
      throw const VideoDataException('播放地址已失效且无法重新获取');
    }
    final line = record.playbackLineIdentity.isEmpty
        ? null
        : detail.playbackLines
              .where((item) => item.identity == record.playbackLineIdentity)
              .toList()
              .firstOrNull;
    final candidates = line?.episodes ?? detail.episodes;
    final current = record.episodeIdentity.isNotEmpty
        ? candidates
                  .where((item) => item.identity == record.episodeIdentity)
                  .firstOrNull ??
              _fallbackEpisode(candidates, record)
        : _fallbackEpisode(candidates, record);
    final episode = _episodeForResume(candidates, current, record);
    final resumePosition = identical(episode, current)
        ? PlaybackProgress(
            positionMs: record.positionMs,
            durationMs: record.durationMs,
            completed: record.completed,
          ).resumePosition()
        : Duration.zero;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          video: detail,
          episode: episode,
          resumePosition: resumePosition,
        ),
      ),
    );
  } catch (error) {
    if (context.mounted && dialogOpen && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    if (context.mounted) {
      showAppToastVia(overlay, error.toString());
    }
  }
}

Episode _fallbackEpisode(List<Episode> candidates, WatchRecord record) {
  final matched = candidates.where(
    (item) => item.name == record.episodeName || item.id == record.episodeId,
  );
  return matched.isEmpty ? candidates.first : matched.first;
}

/// 剧集当前集已完播时改播下一集；没有下一集则重播本集。
Episode _episodeForResume(
  List<Episode> candidates,
  Episode current,
  WatchRecord record,
) {
  if (!record.completed) return current;
  final index = candidates.indexWhere((item) {
    if (current.identity.isNotEmpty && item.identity == current.identity) {
      return true;
    }
    return item.id == current.id || item.name == current.name;
  });
  if (index >= 0 && index + 1 < candidates.length) {
    return candidates[index + 1];
  }
  return current;
}
