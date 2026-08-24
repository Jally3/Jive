import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _contentFilterEnabledKey = 'content_filter_enabled';

/// 敏感内容过滤开关：默认开启，长按首页「Jive」标题可切换，选择持久化。
final contentFilterEnabledProvider =
    AsyncNotifierProvider<ContentFilterEnabledNotifier, bool>(
      ContentFilterEnabledNotifier.new,
    );

class ContentFilterEnabledNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_contentFilterEnabledKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = AsyncData(enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_contentFilterEnabledKey, enabled);
  }
}
