import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../../data/video_repository.dart';
import '../../data/vod_source_registry.dart';
import '../../domain/playback_selection.dart';
import '../../domain/video.dart';
import 'cache_providers.dart';
import 'download_task_manager.dart';

final downloadManagerProvider = FutureProvider<DownloadTaskManager>((
  ref,
) async {
  final cache = await ref.watch(cacheManagerProvider.future);
  final registry = await ref.watch(vodSourceRegistryProvider.future);
  final repository = ref.read(videoRepositoryProvider);
  final client = http.Client();
  final manager = DownloadTaskManager(
    store: cache.store,
    cacheManager: cache,
    client: client,
    resolveSelection: (task) async {
      final source = registry.findById(task.sourceId);
      if (source == null) return null;
      final fresh = await repository.resolvePlayback(
        source,
        VideoRef(sourceId: task.sourceId, sourceVideoId: task.sourceVideoId),
      );
      final lines = fresh.playbackLines
          .where((line) => line.identity == task.playbackLineIdentity)
          .toList();
      if (lines.isEmpty) return null;
      final line = lines.first;
      final episodes = line.episodes
          .where((episode) => episode.identity == task.episodeIdentity)
          .toList();
      final episode = episodes.isNotEmpty
          ? episodes.first
          : line.episodes
                .where(
                  (item) =>
                      item.id == task.episodeId ||
                      item.name == task.episodeName,
                )
                .firstOrNull;
      if (episode == null) return null;
      return selectionFor(fresh.copyWith(playbackLines: [line]), episode);
    },
  );
  await manager.initialize();
  ref.onDispose(() {
    unawaited(manager.dispose().whenComplete(client.close));
  });
  return manager;
});

final downloadTasksProvider = StreamProvider<List<DownloadTask>>((ref) async* {
  final manager = await ref.watch(downloadManagerProvider.future);
  yield manager.tasks;
  yield* manager.changes;
});
