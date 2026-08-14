import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../domain/video.dart';
import '../domain/vod_source.dart';
import 'adapters/mac_cms_v10_adapter.dart';
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
  }) : _adapterResolver = adapterResolver ?? _defaultAdapterResolver;

  final VodSourceAdapter? Function(VodSource source) _adapterResolver;
  final Map<String, ({Video video, DateTime fetchedAt})> _detailCache = {};
  static const _cacheDuration = Duration(minutes: 2);

  static final Map<String, VodSourceAdapter> _defaultAdapters = {
    'mac_cms_v10': MacCmsV10Adapter(http.Client()),
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
  }) => _adapterFor(
    source,
  ).fetchPage(source, page: page, categoryId: categoryId, keyword: keyword);

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) =>
      _adapterFor(source).fetchCategories(source);

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
  final registry = ref
      .watch(vodSourceRegistryProvider)
      .maybeWhen(data: (r) => r, orElse: () => null);
  if (registry == null) return VideoRepositoryImpl();
  return VideoRepositoryImpl(adapterResolver: registry.adapterFor);
});
