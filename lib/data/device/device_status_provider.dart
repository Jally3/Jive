import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/device_status.dart';
import '../network/connectivity_provider.dart';

final deviceNowProvider = Provider<DateTime Function()>((ref) => DateTime.now);
const _deviceChannel = MethodChannel('jive/device_status');

class _DeviceLifecycleObserver with WidgetsBindingObserver {
  _DeviceLifecycleObserver(this.onChange);

  final void Function(AppLifecycleState) onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => onChange(state);
}

/// 只有顶栏状态区订阅，应用失去前台时停止状态区的轮询。
final deviceForegroundProvider =
    NotifierProvider.autoDispose<DeviceForegroundNotifier, bool>(
      DeviceForegroundNotifier.new,
    );

class DeviceForegroundNotifier extends Notifier<bool> {
  @override
  bool build() {
    final observer = _DeviceLifecycleObserver(
      (next) => state = next == AppLifecycleState.resumed,
    );
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
    final current = WidgetsBinding.instance.lifecycleState;
    return current == null || current == AppLifecycleState.resumed;
  }
}

String deviceClockLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// 每次根据真实时间重排到下一分钟，避免后台暂停/系统校时后的累计漂移。
final deviceClockProvider = StreamProvider.autoDispose.family<DateTime, bool>((
  ref,
  active,
) {
  final now = ref.watch(deviceNowProvider);
  if (!active) return Stream.value(now());
  final output = StreamController<DateTime>();
  Timer? timer;
  var observed = true;
  void tick() {
    final time = now();
    output.add(time);
    if (!observed || !ref.read(deviceForegroundProvider)) return;
    timer = Timer(
      Duration(
        microseconds:
            Duration.microsecondsPerMinute -
            time.second * Duration.microsecondsPerSecond -
            time.millisecond * Duration.microsecondsPerMillisecond -
            time.microsecond,
      ),
      tick,
    );
  }

  tick();
  void stop() {
    timer?.cancel();
    timer = null;
  }

  ref.listen(deviceForegroundProvider, (_, foreground) {
    stop();
    if (foreground && observed) tick();
  });
  ref.onCancel(() {
    observed = false;
    stop();
  });
  ref.onResume(() {
    observed = true;
    tick();
  });
  ref.onDispose(() {
    timer?.cancel();
    unawaited(output.close());
  });
  return output.stream;
});

abstract class DeviceBatterySource {
  DeviceBatteryStatus? get cached;
  Future<DeviceBatteryStatus?> read();
  Stream<void> get changes;
}

class _PluginBatterySource implements DeviceBatterySource {
  final Battery _battery = Battery();

  @override
  DeviceBatteryStatus? cached;

  @override
  Future<DeviceBatteryStatus?> read() async {
    try {
      // battery_plus 的 iOS 单次读取会开启监控；未知电量时没有事件订阅
      // 可以取消。原子快照读取在原生端恢复监控开关，迟到结果也不留资源。
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        final snapshot = await _deviceChannel.invokeMapMethod<String, Object?>(
          'batterySnapshot',
        );
        final level = snapshot?['level'] as int?;
        cached = level == null || level < 0 || level > 100
            ? null
            : DeviceBatteryStatus(
                level: level,
                charging: snapshot?['charging'] == true,
              );
        return cached;
      }
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      cached = level < 0 || level > 100
          ? null
          : DeviceBatteryStatus(
              level: level,
              charging: state == BatteryState.charging,
            );
    } catch (_) {
      cached = null;
    }
    return cached;
  }

  @override
  Stream<void> get changes => _battery.onBatteryStateChanged.map<void>((_) {});
}

final deviceBatterySourceProvider = Provider.autoDispose<DeviceBatterySource>(
  (ref) => _PluginBatterySource(),
);

/// 隐藏时只取缓存，不查询平台；显示/恢复前台立即读取，持续显示时 30 秒轮询。
final deviceBatteryProvider = StreamProvider.autoDispose
    .family<DeviceBatteryStatus?, bool>((ref, active) {
      final source = ref.watch(deviceBatterySourceProvider);
      if (!active) return Stream.value(source.cached);
      final output = StreamController<DeviceBatteryStatus?>();
      var disposed = false;
      var running = false;
      var observed = true;
      var refreshing = false;
      var refreshQueued = false;
      StreamSubscription<void>? subscription;
      Future<void> refresh() async {
        if (refreshing) {
          refreshQueued = true;
          return;
        }
        refreshing = true;
        do {
          refreshQueued = false;
          DeviceBatteryStatus? value;
          try {
            value = await source.read();
          } catch (_) {
            value = null;
          }
          if (!disposed && running) {
            output.add(value);
            if (value != null && subscription == null) {
              try {
                subscription = source.changes.listen(
                  (_) => unawaited(refresh()),
                  onError: (Object _) {},
                );
              } catch (_) {
                // 无事件通道的平台仍可以通过定时读取刷新电量。
              }
            }
          }
        } while (!disposed && running && refreshQueued);
        refreshing = false;
      }

      output.add(source.cached);
      Timer? timer;
      void start() {
        if (running || !observed || !ref.read(deviceForegroundProvider)) return;
        running = true;
        unawaited(refresh());
        timer = Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(refresh()),
        );
      }

      void stop() {
        running = false;
        timer?.cancel();
        timer = null;
        unawaited(subscription?.cancel());
        subscription = null;
      }

      start();
      ref.listen(deviceForegroundProvider, (_, foreground) {
        if (foreground) {
          start();
        } else {
          stop();
        }
      });
      ref.onCancel(() {
        observed = false;
        stop();
      });
      ref.onResume(() {
        observed = true;
        start();
      });
      ref.onDispose(() {
        disposed = true;
        stop();
        unawaited(output.close());
      });
      return output.stream;
    });

DeviceNetworkType deviceNetworkTypeFor(List<ConnectivityResult>? results) {
  if (results == null || results.isEmpty) return DeviceNetworkType.unknown;
  if (results.contains(ConnectivityResult.wifi)) return DeviceNetworkType.wifi;
  if (results.contains(ConnectivityResult.ethernet)) {
    return DeviceNetworkType.ethernet;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return DeviceNetworkType.cellular;
  }
  if (results.every((type) => type == ConnectivityResult.none)) {
    return DeviceNetworkType.offline;
  }
  return DeviceNetworkType.other;
}

final deviceNetworkTypeProvider = Provider.autoDispose<DeviceNetworkType>((
  ref,
) {
  return deviceNetworkTypeFor(ref.watch(connectivityResultsProvider).value);
});
