import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 预加载模式：auto 按网络类型自适应窗口，off 完全关闭预取。
enum PrefetchMode { auto, off }

const _prefetchModeKey = 'prefetch_mode';

/// Wi-Fi 下的预取窗口（片数）。
const int prefetchWindowWifi = 30;

/// 蜂窝网络下的预取窗口（片数）。
const int prefetchWindowCellular = 5;

/// 当前网络类型；抽出为 provider 便于测试覆盖。
final connectivityResultsProvider = StreamProvider<List<ConnectivityResult>>(
  (ref) => Connectivity().onConnectivityChanged,
);

final prefetchModeProvider =
    AsyncNotifierProvider<PrefetchModeNotifier, PrefetchMode>(
      PrefetchModeNotifier.new,
    );

class PrefetchModeNotifier extends AsyncNotifier<PrefetchMode> {
  @override
  Future<PrefetchMode> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefetchModeKey);
    return raw == PrefetchMode.off.name ? PrefetchMode.off : PrefetchMode.auto;
  }

  Future<void> setMode(PrefetchMode mode) async {
    state = AsyncData(mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefetchModeKey, mode.name);
  }
}

/// 计算当前预取窗口：模式关闭、蜂窝网络或网络类型未知时返回 0（不预取）。
int prefetchWindowFor(PrefetchMode mode, List<ConnectivityResult>? results) {
  if (mode != PrefetchMode.auto) return 0;
  if (results == null || results.isEmpty) return 0;
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return prefetchWindowWifi;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return prefetchWindowCellular;
  }
  return 0;
}

/// 当前预取窗口大小（片数）。0 表示不预取：模式关闭、蜂窝网络、
/// 或网络类型未知（保守起见不偷跑流量）。
final prefetchWindowProvider = Provider<int>((ref) {
  final mode = ref.watch(prefetchModeProvider).value;
  if (mode == null) return 0;
  final results = ref.watch(connectivityResultsProvider).value;
  return prefetchWindowFor(mode, results);
});
