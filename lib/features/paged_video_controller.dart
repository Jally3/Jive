import 'package:flutter/foundation.dart';
import '../data/video_repository.dart';
import '../domain/video.dart';
import '../domain/vod_source.dart';

class PagedVideoController extends ChangeNotifier {
  PagedVideoController(
    this.repository,
    this.source, {
    this.categoryId,
    this.keyword,
  });
  final VideoRepository repository;
  VodSource source;
  int? categoryId;
  String? keyword;
  final List<Video> items = [];
  int _page = 0;
  bool hasMore = true;
  bool loading = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;

  /// 各分类/关键词首页结果的短时缓存，避免来回切换分类时重复请求。
  final Map<String, _FirstPageSnapshot> _firstPageCache = {};
  static const _firstPageCacheDuration = Duration(minutes: 2);

  String get _cacheKey => '${categoryId ?? ''}|${keyword ?? ''}';

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadInitial({
    int? category,
    String? search,
    bool forceRefresh = false,
  }) async {
    categoryId = category;
    keyword = search;
    _generation++;
    items.clear();
    _page = 0;
    hasMore = true;
    error = null;
    if (!forceRefresh) {
      final cached = _firstPageCache[_cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) <
              _firstPageCacheDuration) {
        items.addAll(cached.items);
        _page = cached.page;
        hasMore = cached.hasMore;
        loading = false;
        _notify();
        return;
      }
    }
    loading = true;
    _notify();
    await _load(1, _generation);
  }

  void reset() {
    _generation++;
    items.clear();
    _page = 0;
    hasMore = true;
    error = null;
    loading = false;
    _notify();
  }

  Future<void> refresh() =>
      loadInitial(category: categoryId, search: keyword, forceRefresh: true);

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    loading = true;
    error = null;
    _notify();
    await _load(_page + 1, _generation);
  }

  Future<void> _load(int page, int generation) async {
    try {
      final result = await repository.fetchPage(
        source,
        page: page,
        categoryId: categoryId,
        keyword: keyword,
      );
      if (_disposed || generation != _generation) return;
      final known = items.map((item) => item.globalId).toSet();
      items.addAll(result.items.where((item) => known.add(item.globalId)));
      _page = result.page;
      hasMore = result.hasMore;
      if (page == 1) {
        _firstPageCache[_cacheKey] = _FirstPageSnapshot(
          items: List.of(items),
          page: _page,
          hasMore: hasMore,
          fetchedAt: DateTime.now(),
        );
      }
    } catch (e) {
      if (!_disposed && generation == _generation) error = e.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }
}

class _FirstPageSnapshot {
  const _FirstPageSnapshot({
    required this.items,
    required this.page,
    required this.hasMore,
    required this.fetchedAt,
  });

  final List<Video> items;
  final int page;
  final bool hasMore;
  final DateTime fetchedAt;
}
