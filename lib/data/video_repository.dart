import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../domain/video.dart';
import '../domain/vod_source.dart';
import 'adapters/age_adapter.dart';
import 'adapters/mac_cms_v10_adapter.dart';
import 'adapters/olevod_adapter.dart';
import 'adapters/syncnext_plugin_adapter.dart';
import 'category_blocklist.dart';
import 'content_filter_policy.dart';
import 'vod_source_adapter.dart';
import 'vod_source_registry.dart';

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

  Future<Video> resolvePlayback(VodSource source, VideoRef ref);
}

class VideoRepositoryImpl implements VideoRepository {
  VideoRepositoryImpl({
    VodSourceAdapter? Function(VodSource source)? adapterResolver,
    this.contentFilterEnabled = true,
  }) : _adapterResolver = adapterResolver ?? _defaultAdapterResolver;

  final VodSourceAdapter? Function(VodSource source) _adapterResolver;

  /// 敏感分类过滤开关：开启时分类列表与视频页都会过滤黑名单内容。
  final bool contentFilterEnabled;
  final Map<String, ({Video video, DateTime fetchedAt})> _detailCache = {};
  static const _cacheDuration = Duration(minutes: 2);

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
  }) async {
    final cacheKey = ref.globalId;
    final cached = _detailCache[cacheKey];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _cacheDuration) {
      return cached.video;
    }
    final video = await _adapterFor(source).fetchDetail(source, ref);
    _detailCache[cacheKey] = (video: video, fetchedAt: DateTime.now());
    return video;
  }

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      _adapterFor(source).resolvePlayback(source, ref);
}

final videoRepositoryProvider = Provider<VideoRepository>((ref) {
  final filterEnabled = ref.watch(contentFilterEnabledProvider).value ?? true;
  final registry = ref
      .watch(vodSourceRegistryProvider)
      .maybeWhen(data: (r) => r, orElse: () => null);
  if (registry == null) {
    return VideoRepositoryImpl(contentFilterEnabled: filterEnabled);
  }
  return VideoRepositoryImpl(
    adapterResolver: registry.adapterFor,
    contentFilterEnabled: filterEnabled,
  );
});
