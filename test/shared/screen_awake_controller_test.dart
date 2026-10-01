import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/screen_awake_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one owner cannot turn off another owner’s screen request', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final applied = <bool>[];
    final controller = ScreenAwakeController(
      setEnabled: (enabled) async => applied.add(enabled),
    );
    final download = Object();
    final player = Object();

    await controller.setRequested(download, true);
    expect(applied.last, isTrue);
    await controller.setRequested(player, true);
    await controller.release(player);
    expect(applied.last, isTrue);
    await controller.release(download);
    expect(applied.last, isFalse);
    await controller.dispose();
  });

  testWidgets('background hides requests and foreground restores them', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final applied = <bool>[];
    final controller = ScreenAwakeController(
      setEnabled: (enabled) async => applied.add(enabled),
    );
    final owner = Object();

    await controller.setRequested(owner, true);
    expect(applied.last, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(applied.last, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(applied.last, isTrue);

    await controller.dispose();
  });

  testWidgets('a late platform enable cannot override the latest release', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final firstEnable = Completer<void>();
    final applied = <bool>[];
    final controller = ScreenAwakeController(
      setEnabled: (enabled) async {
        applied.add(enabled);
        if (enabled && applied.length == 1) await firstEnable.future;
      },
    );
    final owner = Object();

    final requested = controller.setRequested(owner, true);
    await tester.pump();
    final released = controller.release(owner);
    firstEnable.complete();
    await Future.wait([requested, released]);
    expect(applied.last, isFalse);
    await controller.dispose();
  });
}
