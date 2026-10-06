import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../domain/video.dart';
import '../domain/video_feed.dart';
import '../domain/vod_source.dart';
import './vod_source/adapters/age_adapter.dart';
import './vod_source/adapters/mac_cms_v10_adapter.dart';
import './vod_source/adapters/olevod_adapter.dart';
import './vod_source/adapters/syncnext_plugin_adapter.dart';
import './content/category_blocklist.dart';
import './content/content_filter_policy.dart';
import './vod_source/vod_source_adapter.dart';
import './vod_source/vod_source_registry.dart';
import './vod_source/video_detail_cache.dart';

class VideoDataException implements Exception {
  const VideoDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class VideoRepository {
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  });

  Future<List<VideoCategory>> fetchCategories(VodSource source);

  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  });

  Future<Video> resolvePlayback(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  });
}

abstract interface class CancellableVideoRepository {
  Future<VideoPage> fetchPageCancellable(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
    required Future<void> abortTrigger,
  });
}

abstract interface class VideoFeedRepository {
  Set<VideoFeed> supportedFeeds(VodSource source);

  Future<VideoPage> fetchFeedPage(
    VodSource source, {
    required VideoFeed feed,
    int page = 1,
    int? categoryId,
  });
}

extension VideoRepositoryFeeds on VideoRepository {
  Set<VideoFeed> supportedFeeds(VodSource source) {
    final repository = this;
    return repository is VideoFeedRepository
        ? (repository as VideoFeedRepository).supportedFeeds(source)
        : const {VideoFeed.updated};
  }

  Future<VideoPage> fetchFeedPage(
    VodSource source, {
    required VideoFeed feed,
    int page = 1,
    int? categoryId,
  }) {
    final repository = this;
    if (repository is VideoFeedRepository) {
      return (repository as VideoFeedRepository).fetchFeedPage(
        source,
        feed: feed,
        page: page,
        categoryId: categoryId,
      );
    }
    if (feed != VideoFeed.updated) {
      throw const VideoDataException('当前来源暂不支持此排序');
    }
    return fetchPage(source, page: page, categoryId: categoryId);
  }
}

class VideoRepositoryImpl
    implements
        VideoRepository,
        VideoFeedRepository,
        CancellableVideoRepository {
  VideoRepositoryImpl({
    VodSourceAdapter? Function(VodSource source)? adapterResolver,
    this.contentFilterEnabled = true,
    VideoDetailCache? detailCache,
  }) : _adapterResolver = adapterResolver ?? _defaultAdapterResolver,
       _detailCache = detailCache ?? VideoDetailCache();

  final VodSourceAdapter? Function(VodSource source) _adapterResolver;

  /// 敏感分类过滤开关：开启时分类列表与视频页都会过滤黑名单内容。
  final bool contentFilterEnabled;
  final VideoDetailCache _detailCache;
  final Map<VideoDetailCacheKey, _DetailRequest> _detailRequests = {};
  bool _disposed = false;

  static final Map<String, VodSourceAdapter> _defaultAdapters = {
    'mac_cms_v10': MacCmsV10Adapter(http.Client()),
    AgeAdapter.adapterTypeName: AgeAdapter(http.Client()),
    OlevodAdapter.adapterTypeName: OlevodAdapter(http.Client()),
    SyncnextPluginAdapter.adapterTypeName: SyncnextPluginAdapter(http.Client()),
  };

  static VodSourceAdapter? _defaultAdapterResolver(VodSource source) =>
      _defaultAdapters[source.adapterType];

  VodSourceAdapter _adapterFor(VodSource source) {
    final adapter = _adapterResolver(source);
    if (adapter == null) {
      throw ArgumentError('不支持的内容源协议 "${source.adapterType}"（源：${source.id}）');
    }
    return adapter;
  }

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    final result = await _adapterFor(
      source,
    ).fetchPage(source, page: page, categoryId: categoryId, keyword: keyword);
    return _filterPage(result);
  }

  @override
  Future<VideoPage> fetchPageCancellable(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
    required Future<void> abortTrigger,
  }) async {
    final adapter = _adapterFor(source);
    final result = adapter is CancellableVodSourceAdapter
        ? await (adapter as CancellableVodSourceAdapter).fetchPageCancellable(
            source,
            page: page,
            categoryId: categoryId,
            keyword: keyword,
            abortTrigger: abortTrigger,
          )
        : await adapter.fetchPage(
            source,
            page: page,
            categoryId: categoryId,
            keyword: keyword,
          );
    return _filterPage(result);
  }

  VideoPage _filterPage(VideoPage result) {
    if (!contentFilterEnabled) return result;
    final items = result.items
        .where((item) => !isBlockedVideo(item))
        .toList(growable: false);
    if (items.length == result.items.length) return result;
    return VideoPage(
      items: items,
      page: result.page,
      pageCount: result.pageCount,
      total: result.total,
    );
  }

  @override
  Set<VideoFeed> supportedFeeds(VodSource source) {
    final adapter = _adapterFor(source);
    return adapter is VideoFeedSourceAdapter
        ? (adapter as VideoFeedSourceAdapter).supportedFeeds(source)
        : const {VideoFeed.updated};
  }

  @override
  Future<VideoPage> fetchFeedPage(
    VodSource source, {
    required VideoFeed feed,
    int page = 1,
    int? categoryId,
  }) async {
    final adapter = _adapterFor(source);
    final result = adapter is VideoFeedSourceAdapter
        ? await (adapter as VideoFeedSourceAdapter).fetchFeedPage(
            source,
            feed: feed,
            page: page,
            categoryId: categoryId,
          )
        : feed == VideoFeed.updated
        ? await adapter.fetchPage(source, page: page, categoryId: categoryId)
        : throw const VideoDataException('当前来源暂不支持此排序');
    if (!contentFilterEnabled) return result;
    final items = result.items
        .where((item) => !isBlockedVideo(item))
        .toList(growable: false);
    if (items.length == result.items.length) return result;
    return VideoPage(
      items: items,
      page: result.page,
      pageCount: result.pageCount,
      total: result.total,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async {
    final categories = await _adapterFor(source).fetchCategories(source);
    if (!contentFilterEnabled) return categories;
    return categories
        .where((item) => !isBlockedCategoryName(item.name))
        .toList(growable: false);
  }

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) {
    final adapter = _adapterFor(source);
    final cacheKey = videoDetailCacheKey(source, ref);
    final pending = _detailRequests[cacheKey];
    if (pending != null && (!forceRefresh || pending.forced)) {
      return pending.completer.future;
    }
    if (!forceRefresh) {
      final cached = _detailCache.get(cacheKey);
      if (cached != null) return Future.value(cached);
    } else {
      // Never serve a known stale address after an unsuccessful refresh.
      _detailCache.remove(cacheKey);
    }
    final request = _DetailRequest(forceRefresh);
    _detailRequests[cacheKey] = request;
    Future<void> load() async {
      try {
        final video = await adapter.fetchDetail(source, ref);
        if (!_disposed && identical(_detailRequests[cacheKey], request)) {
          _detailCache.put(cacheKey, video);
        }
        request.completer.complete(video);
      } catch (error, stack) {
        request.completer.completeError(error, stack);
      } finally {
        if (identical(_detailRequests[cacheKey], request)) {
          _detailRequests.remove(cacheKey);
        }
      }
    }

    unawaited(load());
    return request.completer.future;
  }

  @override
  Future<Video> resolvePlayback(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) {
    final adapter = _adapterFor(source);
    if (adapter is ReusablePlaybackDetailAdapter) {
      return fetchDetail(
        source,
        ref,
        forceRefresh: forceRefresh,
      ).then((adapter as ReusablePlaybackDetailAdapter).playbackFromDetail);
    }
    // Other sources still perform their normal playback/address resolution.
    return adapter.resolvePlayback(source, ref);
  }

  void dispose() {
    _disposed = true;
    _detailCache.dispose();
    _detailRequests.clear();
  }
}

class _DetailRequest {
  _DetailRequest(this.forced);

  final bool forced;
  final completer = Completer<Video>();
}

final videoRepositoryProvider = Provider<VideoRepository>((ref) {
  final filterEnabled = ref.watch(contentFilterEnabledProvider).value ?? true;
  final registry = ref
      .watch(vodSourceRegistryProvider)
      .maybeWhen(data: (r) => r, orElse: () => null);
  final repository = VideoRepositoryImpl(
    adapterResolver: registry?.adapterFor,
    contentFilterEnabled: filterEnabled,
  );
  ref.onDispose(repository.dispose);
  return repository;
});
