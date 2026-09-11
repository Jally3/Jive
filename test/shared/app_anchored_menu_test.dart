import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/app_anchored_menu.dart';

void main() {
  testWidgets('menu is rounded, centered on its anchor and slides downward', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 48,
              child: Builder(
                builder: (anchorContext) => OutlinedButton(
                  key: const ValueKey('anchor'),
                  onPressed: () => showAppAnchoredMenu<void>(
                    anchorContext: anchorContext,
                    width: 220,
                    builder: (_) => const SizedBox(height: 120),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('anchor')));
    await tester.pump();
    final surface = find.byKey(const ValueKey('app-anchored-menu-surface'));
    final startTop = tester.getTopLeft(surface).dy;
    await tester.pump(const Duration(milliseconds: 180));
    final endTop = tester.getTopLeft(surface).dy;

    final material = tester.widget<Material>(surface);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(16));
    expect(endTop, greaterThan(startTop));
    expect(
      tester.getCenter(surface).dx,
      closeTo(tester.getCenter(find.byKey(const ValueKey('anchor'))).dx, 0.1),
    );
  });

  testWidgets('menu can follow the anchor width and respect a maximum', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 48,
              child: Builder(
                builder: (anchorContext) => OutlinedButton(
                  key: const ValueKey('wide-anchor'),
                  onPressed: () => showAppAnchoredMenu<void>(
                    anchorContext: anchorContext,
                    matchAnchorWidth: true,
                    maxWidth: 200,
                    builder: (_) => const SizedBox(height: 120),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('wide-anchor')));
    await tester.pumpAndSettle();

    expect(
      tester
          .getSize(find.byKey(const ValueKey('app-anchored-menu-surface')))
          .width,
      200,
    );
  });
}
