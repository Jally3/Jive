import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SearchLaunchMode { normal, reviewCurrentSource }

class SearchLaunchRequest {
  const SearchLaunchRequest({
    required this.id,
    required this.keyword,
    required this.sourceId,
    required this.mode,
  });

  final int id;
  final String keyword;
  final String sourceId;
  final SearchLaunchMode mode;
}

class SearchLaunchRequestNotifier extends Notifier<SearchLaunchRequest?> {
  var _nextId = 0;

  @override
  SearchLaunchRequest? build() => null;

  void launch({
    required String keyword,
    required String sourceId,
    SearchLaunchMode mode = SearchLaunchMode.normal,
  }) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    state = SearchLaunchRequest(
      id: ++_nextId,
      keyword: trimmed,
      sourceId: sourceId,
      mode: mode,
    );
  }
}

final searchLaunchRequestProvider =
    NotifierProvider<SearchLaunchRequestNotifier, SearchLaunchRequest?>(
      SearchLaunchRequestNotifier.new,
    );
