import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 预加载模式：auto 按网络类型自适应窗口，off 完全关闭预取。
enum PrefetchMode { auto, off }

const _prefetchModeKey = 'prefetch_mode';

/// Wi-Fi 下的预取目标：领先播放位置的时长。按时间而非片数开窗，
/// 自动适配不同源站 0.5s~10s 不等的分片时长。
const Duration prefetchAheadWifi = Duration(seconds: 300);

/// 蜂窝网络下的预取目标：领先播放位置的时长。
const Duration prefetchAheadCellular = Duration(seconds: 120);

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

/// 计算当前预取目标时长：模式关闭或网络类型未知时返回 0（不预取）。
Duration prefetchAheadFor(
  PrefetchMode mode,
  List<ConnectivityResult>? results,
) {
  if (mode != PrefetchMode.auto) return Duration.zero;
  if (results == null || results.isEmpty) return Duration.zero;
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return prefetchAheadWifi;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return prefetchAheadCellular;
  }
  return Duration.zero;
}

/// 当前预取目标（领先播放位置的时长）。Duration.zero 表示不预取：
/// 模式关闭、无网络，或网络类型未知（保守起见不偷跑流量）。
final prefetchAheadProvider = Provider<Duration>((ref) {
  final mode = ref.watch(prefetchModeProvider).value;
  if (mode == null) return Duration.zero;
  final results = ref.watch(connectivityResultsProvider).value;
  return prefetchAheadFor(mode, results);
});
