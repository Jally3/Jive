import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放缓存的自动清理时机：不自动清理、退出后保留 1 小时（默认）、
/// 5 小时、1 天、3 天、7 天，或退出播放器立即清理。
enum CacheTtlOption { never, hours1, hours5, days1, days3, days7, onExit }

extension CacheTtlOptionMaxAge on CacheTtlOption {
  /// 全局兜底过期时间。onExit 在正常退出播放器时已主动删除对应条目，
  /// 这里保留 1 天兜底：覆盖进程被杀（没走到退出清理）和播放中途
  /// 切换剧集留下的旧条目。
  Duration? get maxAge => switch (this) {
    CacheTtlOption.never => null,
    CacheTtlOption.onExit => const Duration(days: 1),
    CacheTtlOption.hours1 => const Duration(hours: 1),
    CacheTtlOption.hours5 => const Duration(hours: 5),
    CacheTtlOption.days1 => const Duration(days: 1),
    CacheTtlOption.days3 => const Duration(days: 3),
    CacheTtlOption.days7 => const Duration(days: 7),
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
    final current = CacheTtlOption.values
        .where((option) => option.name == raw)
        .firstOrNull;
    if (current != null) return current;

    // 旧版本曾提供 off/5 天/30 天。迁移时不缩短原保留期，
    // 避免覆盖安装后首次启动意外清理用户的已有缓存。
    return switch (raw) {
      'off' || 'days30' => CacheTtlOption.never,
      'days5' => CacheTtlOption.days7,
      _ => CacheTtlOption.hours1,
    };
  }

  Future<void> setOption(CacheTtlOption option) async {
    state = AsyncData(option);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheTtlOptionKey, option.name);
  }
}
