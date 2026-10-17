import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/widgets/nav_reflection.dart';

void main() {
  testWidgets('backlight fades before reaching the edge of its paint layer', (
    tester,
  ) async {
    final controller = NavReflectionController(
      vsync: tester,
      random: Random(2),
    );
    addTearDown(controller.dispose);
    for (final isTablet in [false, true]) {
      await tester.runAsync(() async {
        final padding = NavBacklightPainter.padding;
        final size = ui.Size(350 + padding * 2, 72 + padding * 2);
        final recorder = ui.PictureRecorder();
        NavBacklightPainter(
          controller: controller,
          breath: const AlwaysStoppedAnimation(1),
          isDark: true,
          isTablet: isTablet,
        ).paint(ui.Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect(
          pixels.getUint8(size.width.toInt() ~/ 2 * 4 + 3),
          lessThanOrEqualTo(1),
          reason: 'no visible rectangular cutoff, tablet=$isTablet',
        );
        image.dispose();
        picture.dispose();
      });
    }
  });

  testWidgets('breathing diffuses colored light outside the capsule', (
    tester,
  ) async {
    final controller = NavReflectionController(
      vsync: tester,
      random: Random(2),
    );
    addTearDown(controller.dispose);
    for (final isDark in [true, false]) {
      final alpha = <int>[];
      for (final phase in [0.0, 1.0]) {
        await tester.runAsync(() async {
          final padding = NavBacklightPainter.padding;
          final size = ui.Size(350 + padding * 2, 60 + padding * 2);
          final recorder = ui.PictureRecorder();
          NavBacklightPainter(
            controller: controller,
            breath: AlwaysStoppedAnimation(phase),
            isDark: isDark,
            isTablet: false,
          ).paint(ui.Canvas(recorder), size);
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          // 采样点位于栏体上沿外 12px。
          final offset =
              ((padding.toInt() - 12) * size.width.toInt() +
                  size.width.toInt() ~/ 2) *
              4;
          alpha.add(pixels.getUint8(offset + 3));
          image.dispose();
          picture.dispose();
        });
      }
      expect(alpha.last, greaterThan(alpha.first), reason: 'dark=$isDark');
      expect(alpha.last, greaterThan(2));
    }
  });

  testWidgets('colored border surrounds all four sides in both themes', (
    tester,
  ) async {
    final controller = NavReflectionController(
      vsync: tester,
      random: Random(2),
    );
    addTearDown(controller.dispose);
    for (final isDark in [true, false]) {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)..scale(2);
        NavReflectionPainter(
          controller: controller,
          isDark: isDark,
          isTablet: false,
        ).paint(canvas, const ui.Size(350, 60));
        final picture = recorder.endRecording();
        final image = await picture.toImage(700, 120);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (final (side, x, y) in [
          ('top', 350, 1),
          ('bottom', 350, 118),
          ('left', 1, 60),
          ('right', 698, 60),
        ]) {
          final offset = (y * 700 + x) * 4;
          expect(
            pixels.getUint8(offset + 3),
            greaterThan(20),
            reason: '$side edge must remain visible, dark=$isDark',
          );
        }
        image.dispose();
        picture.dispose();
      });
    }
  });

  testWidgets('scroll color depends on distance rather than event frequency', (
    tester,
  ) async {
    final single = NavReflectionController(vsync: tester, random: Random(7));
    final many = NavReflectionController(vsync: tester, random: Random(7));
    addTearDown(single.dispose);
    addTearDown(many.dispose);
    final initial = single.colors;

    single.advanceScroll(600);
    for (var i = 0; i < 30; i++) {
      many.advanceScroll(20);
    }
    expect(single.colors, many.colors);
    expect(single.colors, isNot(initial));

    final stopped = single.colors;
    await tester.pump(const Duration(seconds: 1));
    expect(single.colors, stopped);
  });

  testWidgets('reflection stays continuous across a scroll segment boundary', (
    tester,
  ) async {
    final controller = NavReflectionController(
      vsync: tester,
      random: Random(3),
    );
    addTearDown(controller.dispose);
    controller.advanceScroll(239.9);
    final before = controller.colors;
    controller.advanceScroll(0.2);
    _expectColorsClose(controller.colors, before);
  });

  testWidgets(
    'rapid tab changes continue from the visible intermediate color',
    (tester) async {
      final controller = NavReflectionController(
        vsync: tester,
        random: Random(1),
      );
      addTearDown(controller.dispose);
      final initial = controller.colors;
      controller.changePalette();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final intermediate = controller.colors;
      expect(intermediate, isNot(initial));

      controller.changePalette();
      expect(controller.colors, intermediate);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final settled = controller.colors;
      expect(settled, isNot(intermediate));
      await tester.pump(const Duration(seconds: 1));
      expect(controller.colors, settled);
    },
  );

  testWidgets('scrolling takes over a tab transition without a color jump', (
    tester,
  ) async {
    final controller = NavReflectionController(
      vsync: tester,
      random: Random(2),
    );
    addTearDown(controller.dispose);
    controller.changePalette();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final intermediate = controller.colors;
    controller.advanceScroll(0.01);
    _expectColorsClose(controller.colors, intermediate);
    final stopped = controller.colors;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.colors, stopped);
  });

  testWidgets('immediate changes settle and never repeat adjacent palettes', (
    tester,
  ) async {
    final controller = NavReflectionController(
      vsync: tester,
      random: Random(4),
    );
    addTearDown(controller.dispose);
    for (var i = 0; i < 20; i++) {
      final previous = controller.colors;
      controller.changePalette(animate: false);
      expect(controller.colors, isNot(previous));
    }
    final settled = controller.colors;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.colors, settled);
  });

  testWidgets(
    'tab targets differ from the visible palette at scroll boundaries',
    (tester) async {
      for (var seed = 0; seed < 20; seed++) {
        final controller = NavReflectionController(
          vsync: tester,
          random: Random(seed),
        );
        controller.advanceScroll(240);
        final visible = controller.colors;
        controller.changePalette(animate: false);
        expect(controller.colors, isNot(visible), reason: 'seed $seed');
        controller.dispose();
      }
    },
  );

  testWidgets('a tab interrupted before its first frame still changes color', (
    tester,
  ) async {
    for (var seed = 0; seed < 20; seed++) {
      final controller = NavReflectionController(
        vsync: tester,
        random: Random(seed),
      );
      final visible = controller.colors;
      controller.changePalette();
      controller.changePalette(animate: false);
      expect(controller.colors, isNot(visible), reason: 'seed $seed');
      controller.dispose();
    }
  });
}

void _expectColorsClose(
  NavReflectionColors actual,
  NavReflectionColors expected,
) {
  for (final (a, b) in [
    (actual.left, expected.left),
    (actual.middle, expected.middle),
    (actual.right, expected.right),
  ]) {
    expect(a.r, closeTo(b.r, 1 / 255));
    expect(a.g, closeTo(b.g, 1 / 255));
    expect(a.b, closeTo(b.b, 1 / 255));
  }
}
