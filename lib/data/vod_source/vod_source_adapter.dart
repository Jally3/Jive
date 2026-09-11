import '../../domain/playback_source.dart';
import '../../domain/video.dart';
import '../../domain/video_feed.dart';
import '../../domain/vod_source.dart';

abstract interface class VodSourceAdapter {
  String get adapterType;

  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  });

  Future<List<VideoCategory>> fetchCategories(VodSource source);

  Future<Video> fetchDetail(VodSource source, VideoRef ref);

  Future<Video> resolvePlayback(VodSource source, VideoRef ref);
}

/// Optional capability for aborting an in-flight list/search request without
/// closing the adapter's shared HTTP client.
abstract interface class CancellableVodSourceAdapter {
  Future<VideoPage> fetchPageCancellable(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
    required Future<void> abortTrigger,
  });
}

/// Optional source capability for server-side ordered content feeds.
///
/// Adapters that do not implement this interface remain compatible and are
/// treated as supporting [VideoFeed.updated] only.
abstract interface class VideoFeedSourceAdapter {
  Set<VideoFeed> supportedFeeds(VodSource source);

  Future<VideoPage> fetchFeedPage(
    VodSource source, {
    required VideoFeed feed,
    int page = 1,
    int? categoryId,
  });
}

/// Optional adapter stage: turn one episode's intermediate URL into a
/// playable media source (Syncnext `Player()`).
abstract interface class EpisodePlaybackResolver implements VodSourceAdapter {
  Future<PlaybackSource> resolveEpisodePlayback(
    VodSource source,
    String episodeUrl,
  );
}
