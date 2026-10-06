import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/device/device_status_provider.dart';
import 'package:jive/domain/device_status.dart';

class _BatterySource implements DeviceBatterySource {
  final events = StreamController<void>.broadcast();
  int reads = 0;
  bool fail = false;
  Completer<DeviceBatteryStatus?>? pending;
  DeviceBatteryStatus? next = const DeviceBatteryStatus(
    level: 82,
    charging: false,
  );

  @override
  DeviceBatteryStatus? cached;

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<DeviceBatteryStatus?> read() async {
    reads++;
    if (fail) throw StateError('battery unavailable');
    return cached = pending == null ? next : await pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  test('network types prefer Wi-Fi and distinguish unavailable data', () {
    expect(deviceNetworkTypeFor(null), DeviceNetworkType.unknown);
    expect(deviceNetworkTypeFor([]), DeviceNetworkType.unknown);
    expect(
      deviceNetworkTypeFor([ConnectivityResult.none]),
      DeviceNetworkType.offline,
    );
    expect(
      deviceNetworkTypeFor([ConnectivityResult.mobile]),
      DeviceNetworkType.cellular,
    );
    expect(
      deviceNetworkTypeFor([
        ConnectivityResult.mobile,
        ConnectivityResult.wifi,
      ]),
      DeviceNetworkType.wifi,
    );
    expect(
      deviceNetworkTypeFor([ConnectivityResult.ethernet]),
      DeviceNetworkType.ethernet,
    );
    expect(
      deviceNetworkTypeFor([ConnectivityResult.vpn]),
      DeviceNetworkType.other,
    );
  });

  testWidgets('clock aligns to minute boundaries and stops without listeners', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 6, 21, 36, 59, 500);
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        deviceNowProvider.overrideWithValue(() {
          reads++;
          return now;
        }),
      ],
    );
    final labels = <String>[];
    final listener = container.listen(deviceClockProvider(true), (_, value) {
      if (value.value != null) labels.add(deviceClockLabel(value.value!));
    });
    await tester.pump();
    expect(labels.last, '21:36');
    now = DateTime(2026, 10, 6, 21, 37);
    await tester.pump(const Duration(milliseconds: 500));
    expect(labels.last, '21:37');
    now = DateTime(2026, 10, 6, 22);
    await tester.pump(const Duration(seconds: 60));
    expect(labels.last, '22:00');
    listener.close();
    final previousReads = reads;
    await tester.pump(const Duration(minutes: 2));
    expect(reads, previousReads);
    container.dispose();
  });

  testWidgets('battery refreshes on changes and polls only while observed', (
    tester,
  ) async {
    final source = _BatterySource();
    final container = ProviderContainer(
      overrides: [deviceBatterySourceProvider.overrideWithValue(source)],
    );
    final listener = container.listen(deviceBatteryProvider(true), (_, _) {});
    await tester.pump();
    expect(source.reads, 1);
    expect(container.read(deviceBatteryProvider(true)).value?.level, 82);

    source.next = const DeviceBatteryStatus(level: 20, charging: true);
    source.events.add(null);
    await tester.pump();
    expect(source.reads, 2);
    expect(container.read(deviceBatteryProvider(true)).value?.charging, isTrue);
    await tester.pump(const Duration(seconds: 30));
    expect(source.reads, 3);

    listener.close();
    await tester.pump(const Duration(seconds: 60));
    expect(source.reads, 3);
    expect(source.events.hasListener, isFalse);
    final hidden = container.listen(deviceBatteryProvider(false), (_, _) {});
    await tester.pump();
    expect(container.read(deviceBatteryProvider(false)).value, source.cached);
    expect(source.reads, 3);
    hidden.close();
    container.dispose();
    await source.events.close();
  });

  testWidgets('missing battery data degrades to an unknown snapshot', (
    tester,
  ) async {
    final source = _BatterySource()..fail = true;
    final container = ProviderContainer(
      overrides: [deviceBatterySourceProvider.overrideWithValue(source)],
    );
    final listener = container.listen(deviceBatteryProvider(true), (_, _) {});
    await tester.pump();
    expect(
      container.read(deviceBatteryProvider(true)),
      const AsyncData<DeviceBatteryStatus?>(null),
    );
    listener.close();
    container.dispose();
    await source.events.close();
  });

  testWidgets('late battery read cannot restart listeners after exit', (
    tester,
  ) async {
    final source = _BatterySource()
      ..pending = Completer<DeviceBatteryStatus?>();
    final container = ProviderContainer(
      overrides: [deviceBatterySourceProvider.overrideWith((ref) => source)],
    );
    final listener = container.listen(deviceBatteryProvider(true), (_, _) {});
    await tester.pump();
    listener.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.exists(deviceBatteryProvider(true)), isFalse);
    expect(container.exists(deviceBatterySourceProvider), isFalse);
    expect(container.exists(deviceForegroundProvider), isFalse);
    source.pending!.complete(source.next);
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(source.events.hasListener, isFalse);
    expect(source.reads, 1);
    container.dispose();
    await source.events.close();
  });

  testWidgets('foreground state follows app lifecycle', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final container = ProviderContainer();
    final listener = container.listen(deviceForegroundProvider, (_, _) {});
    expect(container.read(deviceForegroundProvider), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(container.read(deviceForegroundProvider), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(container.read(deviceForegroundProvider), isTrue);
    listener.close();
    container.dispose();
  });

  testWidgets('iOS uses atomic snapshots and cancels native battery events', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const device = MethodChannel('jive/device_status');
    const battery = MethodChannel('dev.fluttercommunity.plus/battery');
    const events = MethodChannel('dev.fluttercommunity.plus/charging');
    final messenger = tester.binding.defaultBinaryMessenger;
    var snapshot = <String, Object>{'level': 82, 'charging': true};
    var pluginReads = 0;
    final eventCalls = <String>[];
    messenger.setMockMethodCallHandler(device, (call) async {
      expect(call.method, 'batterySnapshot');
      return snapshot;
    });
    messenger.setMockMethodCallHandler(battery, (call) async {
      pluginReads++;
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(device, null);
      messenger.setMockMethodCallHandler(battery, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final container = ProviderContainer();
    var listener = container.listen(deviceBatteryProvider(true), (_, _) {});
    await tester.pump();
    expect(
      container.read(deviceBatteryProvider(true)).value,
      const DeviceBatteryStatus(level: 82, charging: true),
    );
    expect(pluginReads, 0);
    expect(eventCalls, ['listen']);
    listener.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(eventCalls, ['listen', 'cancel']);
    snapshot = {'level': -1, 'charging': false};
    listener = container.listen(deviceBatteryProvider(true), (_, _) {});
    await tester.pump();
    expect(container.read(deviceBatteryProvider(true)).value, isNull);
    expect(eventCalls, ['listen', 'cancel']);
    listener.close();
    await tester.pump(const Duration(milliseconds: 1));
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
}
