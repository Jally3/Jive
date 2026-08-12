import 'package:flutter/foundation.dart';
import '../data/video_repository.dart';
import '../domain/video.dart';

class PagedVideoController extends ChangeNotifier {
  PagedVideoController(this.repository, {this.categoryId, this.keyword});
  final VideoRepository repository;
  int? categoryId;
  String? keyword;
  final List<Video> items = [];
  int _page = 0;
  bool hasMore = true;
  bool loading = false;
  String? error;
  int _generation = 0;

  Future<void> loadInitial({int? category, String? search}) async {
    categoryId = category;
    keyword = search;
    _generation++;
    items.clear();
    _page = 0;
    hasMore = true;
    error = null;
    loading = true;
    notifyListeners();
    await _load(1, _generation);
  }

  void reset() {
    _generation++;
    items.clear();
    _page = 0;
    hasMore = true;
    error = null;
    loading = false;
    notifyListeners();
  }

  Future<void> refresh() => loadInitial(category: categoryId, search: keyword);

  Future<void> loadMore() async {
    if (loading || !hasMore) return;
    loading = true;
    error = null;
    notifyListeners();
    await _load(_page + 1, _generation);
  }

  Future<void> _load(int page, int generation) async {
    try {
      final result = await repository.fetchPage(
        page: page,
        categoryId: categoryId,
        keyword: keyword,
      );
      if (generation != _generation) return;
      final known = items.map((item) => item.id).toSet();
      items.addAll(result.items.where((item) => known.add(item.id)));
      _page = result.page;
      hasMore = result.hasMore;
    } catch (e) {
      if (generation == _generation) error = e.toString();
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }
}
