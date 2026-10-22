import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/device/device_status_provider.dart';
import 'package:jive/data/network/connectivity_provider.dart';
import 'package:jive/domain/device_status.dart';
import 'package:jive/features/player/widgets/player_top_bar.dart';
import 'package:jive/features/player/widgets/player_indicators.dart';
import 'package:video_player/video_player.dart';

class _BatterySource implements DeviceBatterySource {
  _BatterySource(this.cached);

  @override
  DeviceBatteryStatus? cached;
  int reads = 0;

  @override
  Future<DeviceBatteryStatus?> read() async {
    reads++;
    return cached;
  }

  @override
  Stream<void> get changes => const Stream.empty();
}

Future<void> _pumpTopBar(
  WidgetTester tester,
  ProviderContainer container, {
  double width = 844,
  double textScale = 1,
  bool visible = true,
  bool isTv = false,
  EdgeInsets padding = EdgeInsets.zero,
  VoidCallback? onShowControls,
  Widget? overlay,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 600);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: padding,
            viewPadding: padding,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              PlayerTopBar(
                visible: visible,
                fullScreen: true,
                title: '测试视频 · 很长的剧集标题应该自动省略',
                isTv: isTv,
                onBack: () {},
                onShowControls: onShowControls ?? () {},
              ),
              if (overlay != null) overlay,
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  container.dispose();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('status changes rebuild only their own item', (tester) async {
    final semantics = tester.ensureSemantics();
    final clock = StreamController<DateTime>();
    final battery = StreamController<DeviceBatteryStatus?>();
    final network = StreamController<List<ConnectivityResult>>();
    final container = ProviderContainer(
      overrides: [
        deviceClockProvider(true).overrideWith((ref) => clock.stream),
        deviceBatteryProvider(true).overrideWith((ref) => battery.stream),
        deviceBatterySourceProvider.overrideWithValue(
          _BatterySource(const DeviceBatteryStatus(level: 82, charging: false)),
        ),
        connectivityResultsProvider.overrideWith((ref) => network.stream),
        deviceNowProvider.overrideWithValue(
          () => DateTime(2026, 10, 6, 21, 36),
        ),
      ],
    );
    await _pumpTopBar(tester, container);
    clock.add(DateTime(2026, 10, 6, 21, 36));
    battery.add(const DeviceBatteryStatus(level: 82, charging: false));
    network.add([ConnectivityResult.wifi]);
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.wifi), findsOneWidget);
    expect(find.text('Wi-Fi'), findsNothing);
    expect(find.bySemanticsLabel('网络 Wi-Fi'), findsOneWidget);

    Widget item(String key) => tester.widget(find.byKey(ValueKey(key)));
    final title = item('player-top-title-row');
    final batteryBefore = item('player-device-battery');
    final networkBefore = item('player-device-network');
    clock.add(DateTime(2026, 10, 6, 21, 37));
    await tester.pump();
    await tester.pump();
    expect(find.text('21:37'), findsOneWidget);
    expect(item('player-top-title-row'), same(title));
    expect(item('player-device-battery'), same(batteryBefore));
    expect(item('player-device-network'), same(networkBefore));

    final clockBefore = item('player-device-clock');
    battery.add(const DeviceBatteryStatus(level: 20, charging: false));
    await tester.pump();
    await tester.pump();
    expect(find.text('20'), findsOneWidget);
    expect(find.text('20%'), findsNothing);
    expect(tester.widget<Text>(find.text('20')).style?.color, Colors.redAccent);
    expect(item('player-device-clock'), same(clockBefore));
    expect(item('player-device-network'), same(networkBefore));
    expect(item('player-top-title-row'), same(title));

    battery.add(const DeviceBatteryStatus(level: 20, charging: true));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.bolt), findsOneWidget);
    expect(tester.widget<Text>(find.text('20')).style?.color, Colors.white);
    final batteryAfter = item('player-device-battery');
    network.add([ConnectivityResult.mobile]);
    await tester.pump();
    await tester.pump();
    expect(find.text('蜂窝'), findsOneWidget);
    expect(item('player-device-clock'), same(clockBefore));
    expect(item('player-device-battery'), same(batteryAfter));
    expect(item('player-top-title-row'), same(title));
    await _finish(tester, container);
    unawaited(clock.close());
    unawaited(battery.close());
    unawaited(network.close());
    await tester.pump();
    semantics.dispose();
  });

  for (final layout in [
    (width: 844.0, scale: 1.0, twoRows: false),
    (width: 390.0, scale: 1.0, twoRows: true),
    (width: 320.0, scale: 2.0, twoRows: true),
  ]) {
    testWidgets('top bar fits ${layout.width} at text scale ${layout.scale}', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          deviceNowProvider.overrideWithValue(
            () => DateTime(2026, 10, 6, 21, 36),
          ),
          deviceBatterySourceProvider.overrideWithValue(
            _BatterySource(
              const DeviceBatteryStatus(level: 100, charging: true),
            ),
          ),
          connectivityResultsProvider.overrideWith(
            (ref) => Stream.value([ConnectivityResult.wifi]),
          ),
        ],
      );
      await _pumpTopBar(
        tester,
        container,
        width: layout.width,
        textScale: layout.scale,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      );
      expect(tester.takeException(), isNull);
      final status = tester.getRect(
        find.byKey(const ValueKey('player-device-status')),
      );
      final title = tester.getRect(
        find.byKey(const ValueKey('player-top-title-row')),
      );
      expect(status.left, greaterThanOrEqualTo(20));
      expect(status.right, lessThanOrEqualTo(layout.width - 20));
      expect(status.right, closeTo(layout.width - 20 - 8, 0.01));
      expect(title.left, closeTo(20 + 8, 0.01));
      expect(status.top, greaterThanOrEqualTo(24));
      final batteryBody = tester.getRect(
        find.byKey(const ValueKey('player-device-battery-body')),
      );
      final batteryLevel = tester.getRect(
        find.byKey(const ValueKey('player-device-battery-level')),
      );
      expect(find.text('100'), findsOneWidget);
      expect(batteryBody.contains(batteryLevel.topLeft), isTrue);
      expect(batteryBody.contains(batteryLevel.bottomRight), isTrue);
      if (layout.twoRows) expect(status.bottom, lessThanOrEqualTo(title.top));
      var taps = 0;
      await _pumpTopBar(
        tester,
        container,
        width: layout.width,
        textScale: layout.scale,
        onShowControls: () => taps++,
      );
      await tester.tap(find.byKey(const ValueKey('player-device-clock')));
      expect(taps, 1);
      await _finish(tester, container);
    });
  }

  testWidgets(
    'hidden and background status stops polling and refreshes on resume',
    (tester) async {
      final source = _BatterySource(
        const DeviceBatteryStatus(level: 82, charging: false),
      );
      final container = ProviderContainer(
        overrides: [
          deviceBatterySourceProvider.overrideWithValue(source),
          connectivityResultsProvider.overrideWith(
            (ref) => Stream.value([ConnectivityResult.wifi]),
          ),
        ],
      );
      await _pumpTopBar(tester, container);
      expect(source.reads, 1);
      await _pumpTopBar(tester, container, visible: false);
      await tester.pump(const Duration(seconds: 60));
      expect(source.reads, 1);
      await _pumpTopBar(tester, container);
      expect(source.reads, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 60));
      expect(source.reads, 2);
      source.cached = const DeviceBatteryStatus(level: 19, charging: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(source.reads, 3);
      expect(find.text('19'), findsOneWidget);
      await _finish(tester, container);
    },
  );

  testWidgets('repeated exit releases clock battery and lifecycle providers', (
    tester,
  ) async {
    final source = _BatterySource(
      const DeviceBatteryStatus(level: 82, charging: false),
    );
    var clockReads = 0;
    final container = ProviderContainer(
      overrides: [
        deviceNowProvider.overrideWithValue(() {
          clockReads++;
          return DateTime(2026, 10, 6, 21, 36);
        }),
        deviceBatterySourceProvider.overrideWith((ref) => source),
        connectivityResultsProvider.overrideWith(
          (ref) => Stream.value([ConnectivityResult.wifi]),
        ),
      ],
    );
    for (var visit = 1; visit <= 3; visit++) {
      await _pumpTopBar(tester, container);
      expect(source.reads, visit);
      // 应用级 ProviderScope 保持挂载，仅移除播放器顶栏。
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox.shrink()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(container.exists(deviceClockProvider(true)), isFalse);
      expect(container.exists(deviceBatteryProvider(true)), isFalse);
      expect(container.exists(deviceBatterySourceProvider), isFalse);
      expect(container.exists(deviceNetworkTypeProvider), isFalse);
      expect(container.exists(connectivityResultsProvider), isFalse);
      expect(container.exists(deviceForegroundProvider), isFalse);
      final reads = clockReads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(minutes: 2));
      expect(source.reads, visit);
      expect(clockReads, reads);
    }
    container.dispose();
  });

  testWidgets(
    'speed boost stays below the top bar with large text and a notch',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          deviceBatterySourceProvider.overrideWithValue(_BatterySource(null)),
          connectivityResultsProvider.overrideWith(
            (ref) => Stream.value([ConnectivityResult.wifi]),
          ),
        ],
      );
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.com/video.mp4'),
      );
      final preview = ValueNotifier<Duration?>(null);
      final seekClock = ValueNotifier<Duration?>(null);
      final committing = ValueNotifier(false);
      final seeking = ValueNotifier(false);
      final boosting = ValueNotifier(true);
      final fallback = ValueNotifier(false);
      final vertical = ValueNotifier<({bool isVolume, double value})?>(null);
      for (final scale in [1.0, 2.0, 3.0]) {
        await _pumpTopBar(
          tester,
          container,
          width: 390,
          textScale: scale,
          padding: const EdgeInsets.only(top: 24),
          overlay: PlayerGestureIndicator(
            controller: controller,
            previewPosition: preview,
            seekClock: seekClock,
            seekCommitting: committing,
            screenSeeking: seeking,
            speedBoosting: boosting,
            speedBoostFallback: fallback,
            verticalDrag: vertical,
            positionBeforeSeek: Duration.zero,
            topBarVisible: true,
          ),
        );
        final bar = tester.getRect(
          find.byKey(const ValueKey('player-top-scrim')),
        );
        final speed = tester.getRect(
          find.byKey(const ValueKey('speed-boost-indicator')),
        );
        expect(speed.top, greaterThanOrEqualTo(bar.bottom + 8));
        expect(tester.takeException(), isNull);
      }
      await _finish(tester, container);
      for (final notifier in [
        preview,
        seekClock,
        committing,
        seeking,
        boosting,
        fallback,
        vertical,
      ]) {
        notifier.dispose();
      }
      await controller.dispose();
    },
  );

  testWidgets('TV omits battery access and missing data stays readable', (
    tester,
  ) async {
    final source = _BatterySource(null);
    final container = ProviderContainer(
      overrides: [
        deviceBatterySourceProvider.overrideWithValue(source),
        connectivityResultsProvider.overrideWith(
          (ref) => Stream.error(StateError('unknown')),
        ),
      ],
    );
    await _pumpTopBar(tester, container, isTv: true);
    expect(find.byKey(const ValueKey('player-device-battery')), findsNothing);
    expect(source.reads, 0);
    expect(find.text('未知'), findsOneWidget);
    await _pumpTopBar(tester, container);
    expect(find.text('--'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });
}
