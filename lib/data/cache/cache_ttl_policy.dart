import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放缓存的自动清理时机：退出后保留 1 小时（默认）、5 小时、1 天，
/// 或退出播放器立即清理。
enum CacheTtlOption { hours1, hours5, days1, onExit }

extension CacheTtlOptionMaxAge on CacheTtlOption {
  /// 全局兜底过期时间。onExit 在正常退出播放器时已主动删除对应条目，
  /// 这里保留 1 天兜底：覆盖进程被杀（没走到退出清理）和播放中途
  /// 切换剧集留下的旧条目。
  Duration get maxAge => switch (this) {
    CacheTtlOption.onExit => const Duration(days: 1),
    CacheTtlOption.hours1 => const Duration(hours: 1),
    CacheTtlOption.hours5 => const Duration(hours: 5),
    CacheTtlOption.days1 => const Duration(days: 1),
  };

  /// 是否需要在退出播放器时主动删除本次播放的缓存条目。
  bool get cleanOnExit => this == CacheTtlOption.onExit;
}

const _cacheTtlOptionKey = 'cache_ttl_option';

final cacheTtlProvider =
    AsyncNotifierProvider<CacheTtlNotifier, CacheTtlOption>(
      CacheTtlNotifier.new,
    );

class CacheTtlNotifier extends AsyncNotifier<CacheTtlOption> {
  @override
  Future<CacheTtlOption> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheTtlOptionKey);
    // 旧版本存的是 off/days1~days30，匹配不到时回落到默认的 1 小时。
    return CacheTtlOption.values
            .where((option) => option.name == raw)
            .firstOrNull ??
        CacheTtlOption.hours1;
  }

  Future<void> setOption(CacheTtlOption option) async {
    state = AsyncData(option);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheTtlOptionKey, option.name);
  }
}
