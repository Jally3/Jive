import 'package:shared_preferences/shared_preferences.dart';

/// 首页「我的频道」（主 tab 行展示的根分类集合与顺序）存取：
/// 按源持久化，key 为 `home_my_channels_<sourceId>`。
/// 无记录（load 返回 null）表示未定制，展示该源的全部根分类。
abstract final class MyChannelsStore {
  static String _key(String sourceId) => 'home_my_channels_$sourceId';

  static Future<List<int>?> load(String sourceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key(sourceId));
    if (raw == null) return null;
    return [for (final item in raw) int.parse(item)];
  }

  static Future<void> save(String sourceId, List<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key(sourceId), [for (final id in ids) '$id']);
  }

  static Future<void> reset(String sourceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(sourceId));
  }
}
