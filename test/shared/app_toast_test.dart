import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/app_toast.dart';

void main() {
  testWidgets('toast shows centered message and auto-dismisses', (
    tester,
  ) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showAppToast(hostContext, '测试提示');
    await tester.pump();
    expect(find.text('测试提示'), findsOneWidget);

    // 无 action 时指针事件穿透，不拦截下层手势。
    final barrier = tester.widget<IgnorePointer>(
      find.ancestor(
        of: find.text('测试提示'),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(barrier.ignoring, isTrue);

    // 2 秒停留 + 150ms 退出动画后移除。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('测试提示'), findsNothing);
  });

  testWidgets('new toast replaces the current one', (tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showAppToast(hostContext, '第一条');
    await tester.pump();
    showAppToast(hostContext, '第二条');
    await tester.pump();
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
  });

  testWidgets('action label invokes callback and dismisses', (tester) async {
    late BuildContext hostContext;
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showAppToast(
      hostContext,
      '带操作',
      actionLabel: '查看',
      onAction: () => tapped = true,
    );
    await tester.pump();
    expect(find.text('查看'), findsOneWidget);

    // 有 action 时 toast 本身可点击。
    final barrier = tester.widget<IgnorePointer>(
      find.ancestor(of: find.text('带操作'), matching: find.byType(IgnorePointer)),
    );
    expect(barrier.ignoring, isFalse);

    await tester.tap(find.text('查看'));
    await tester.pump();
    expect(tapped, isTrue);
    expect(find.text('带操作'), findsNothing);
  });
}
