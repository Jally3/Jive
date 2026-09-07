import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/double_back_exit_scope.dart';

void main() {
  test('second back press inside interval requests exit', () {
    var now = DateTime(2026);
    final controller = DoubleBackExitController(now: () => now);

    expect(controller.registerBackPress(), isFalse);
    now = now.add(const Duration(milliseconds: 1999));
    expect(controller.registerBackPress(), isTrue);
  });

  test('back press after interval starts a new window', () {
    var now = DateTime(2026);
    final controller = DoubleBackExitController(now: () => now);

    expect(controller.registerBackPress(), isFalse);
    now = now.add(const Duration(milliseconds: 2001));
    expect(controller.registerBackPress(), isFalse);
    now = now.add(const Duration(seconds: 1));
    expect(controller.registerBackPress(), isTrue);
  });

  testWidgets('first back shows toast and second back requests exit', (
    tester,
  ) async {
    var exitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DoubleBackExitScope(
          onExit: () async => exitCount++,
          child: const Scaffold(body: Text('首页')),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('再按一次退出应用'), findsOneWidget);
    expect(exitCount, 0);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exitCount, 1);

    await tester.pump(const Duration(seconds: 3));
  });
}
