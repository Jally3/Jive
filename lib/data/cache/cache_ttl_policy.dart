import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CacheTtlOption { off, days1, days3, days5, days7, days30 }

extension CacheTtlOptionMaxAge on CacheTtlOption {
  Duration? get maxAge => switch (this) {
    CacheTtlOption.off => null,
    CacheTtlOption.days1 => const Duration(days: 1),
    CacheTtlOption.days3 => const Duration(days: 3),
    CacheTtlOption.days5 => const Duration(days: 5),
    CacheTtlOption.days7 => const Duration(days: 7),
    CacheTtlOption.days30 => const Duration(days: 30),
  };
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
    return CacheTtlOption.values
            .where((option) => option.name == raw)
            .firstOrNull ??
        CacheTtlOption.days3;
  }

  Future<void> setOption(CacheTtlOption option) async {
    state = AsyncData(option);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheTtlOptionKey, option.name);
  }
}
