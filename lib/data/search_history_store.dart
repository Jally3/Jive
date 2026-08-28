import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索关键词本地历史：去重、最近优先，最多 [maxItems] 条。
abstract final class SearchHistoryStore {
  static const key = 'search_history_v1';
  static const maxItems = 20;

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key) ?? const [];
  }

  static Future<List<String>> add(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return load();
    final prefs = await SharedPreferences.getInstance();
    final current = [...?prefs.getStringList(key)];
    current.removeWhere((item) => item == trimmed);
    current.insert(0, trimmed);
    if (current.length > maxItems) {
      current.removeRange(maxItems, current.length);
    }
    await prefs.setStringList(key, current);
    return current;
  }

  static Future<List<String>> remove(String keyword) async {
    final prefs = await SharedPreferences.getInstance();
    final current = [...?prefs.getStringList(key)]..remove(keyword);
    await prefs.setStringList(key, current);
    return current;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

class SearchHistoryNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() => SearchHistoryStore.load();

  Future<void> add(String keyword) async {
    state = AsyncData(await SearchHistoryStore.add(keyword));
  }

  Future<void> remove(String keyword) async {
    state = AsyncData(await SearchHistoryStore.remove(keyword));
  }

  Future<void> clear() async {
    await SearchHistoryStore.clear();
    state = const AsyncData([]);
  }
}

final searchHistoryProvider =
    AsyncNotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );
