import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/app/widgets/floating_nav_bar.dart';
import 'package:jive/app/widgets/nav_reflection.dart';

import '../../support/navigation_frames.dart';

NavReflectionColors _colors(WidgetTester tester) =>
    (tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('nav-reflection')),
                )
                .painter!
            as NavReflectionPainter)
        .controller
        .colors;

Animation<double> _breath(WidgetTester tester) =>
    (tester
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('nav-backlight')),
                )
                .painter!
            as NavBacklightPainter)
        .breath;

Future<void> _pumpNav(
  WidgetTester tester, {
  required ValueNotifier<int> selected,
  required ValueNotifier<double> distance,
  bool showUpdateDot = false,
  bool reducedMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildDarkTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Scaffold(
        bottomNavigationBar: ValueListenableBuilder<int>(
          valueListenable: selected,
          builder: (context, index, _) => FloatingNavBar(
            selectedIndex: index,
            onSelect: (value) => selected.value = value,
            showUpdateDot: showUpdateDot,
            scrollDistance: distance,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('backlight breathes without changing the selected palette', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    final distance = ValueNotifier(0.0);
    addTearDown(selected.dispose);
    addTearDown(distance.dispose);
    await _pumpNav(tester, selected: selected, distance: distance);
    final backlight = find.byKey(const ValueKey('nav-backlight'));
    expect(backlight, findsOneWidget);
    final breath = _breath(tester);
    final initialPhase = breath.value;
    final initialColors = _colors(tester);
    await tester.pump(const Duration(milliseconds: 900));
    expect(breath.value, greaterThan(initialPhase));
    expect(_colors(tester), initialColors);
  });

  testWidgets('backlight pauses while the app is in the background', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    final distance = ValueNotifier(0.0);
    addTearDown(selected.dispose);
    addTearDown(distance.dispose);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await _pumpNav(tester, selected: selected, distance: distance);
    await tester.pump(const Duration(milliseconds: 450));
    final breath = _breath(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final paused = breath.value;
    await tester.pump(const Duration(seconds: 2));
    expect(breath.value, paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(breath.value, isNot(paused));
  });

  testWidgets('a covering route pauses backlight until navigation returns', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    final distance = ValueNotifier(0.0);
    addTearDown(selected.dispose);
    addTearDown(distance.dispose);
    await _pumpNav(tester, selected: selected, distance: distance);
    final breath = _breath(tester);
    final navigator = Navigator.of(tester.element(find.text('首页')));
    navigator.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('覆盖页面'))),
    );
    await pumpNavigationFrames(tester);
    final covered = breath.value;
    await tester.pump(const Duration(seconds: 1));
    expect(breath.value, covered);
    expect((breath as AnimationController).isAnimating, isFalse);
    navigator.pop();
    await pumpNavigationFrames(tester);
    final returned = breath.value;
    await tester.pump(const Duration(milliseconds: 450));
    expect(breath.value, isNot(returned));
  });

  testWidgets('a modal dialog pauses breathing until it closes', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    final distance = ValueNotifier(0.0);
    addTearDown(selected.dispose);
    addTearDown(distance.dispose);
    await _pumpNav(tester, selected: selected, distance: distance);
    final breath = _breath(tester) as AnimationController;
    final context = tester.element(find.text('首页'));
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(content: Text('确认操作')),
    );
    await pumpNavigationFrames(tester);
    expect(breath.isAnimating, isFalse);
    final paused = breath.value;
    await tester.pump(const Duration(seconds: 1));
    expect(breath.value, paused);
    Navigator.of(context).pop();
    await pumpNavigationFrames(tester);
    expect(breath.isAnimating, isTrue);
  });

  testWidgets('rebuilds and tapping the active tab preserve the reflection', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    final distance = ValueNotifier(0.0);
    addTearDown(selected.dispose);
    addTearDown(distance.dispose);
    await _pumpNav(tester, selected: selected, distance: distance);
    final initial = _colors(tester);
    await _pumpNav(
      tester,
      selected: selected,
      distance: distance,
      showUpdateDot: true,
    );
    expect(find.byKey(const ValueKey('bottom-nav-update-dot')), findsOneWidget);
    expect(_colors(tester), initial);
    await tester.tap(find.text('首页'));
    await pumpNavigationFrames(tester);
    expect(_colors(tester), initial);

    await tester.tap(find.text('我的'));
    await pumpNavigationFrames(tester);
    expect(selected.value, 2);
    expect(_colors(tester), isNot(initial));
    final inProfile = _colors(tester);
    distance.value = 120;
    await tester.pump();
    expect(_colors(tester), inProfile);
  });

  testWidgets(
    'reduced motion keeps scrolling static and switches tabs at once',
    (tester) async {
      final selected = ValueNotifier(0);
      final distance = ValueNotifier(0.0);
      addTearDown(selected.dispose);
      addTearDown(distance.dispose);
      await _pumpNav(
        tester,
        selected: selected,
        distance: distance,
        reducedMotion: true,
      );
      final initial = _colors(tester);
      final breath = _breath(tester);
      expect((breath as AnimationController).isAnimating, isFalse);
      distance.value = 120;
      await tester.pump();
      expect(_colors(tester), initial);
      await tester.tap(find.text('我的'));
      await tester.pump();
      final switched = _colors(tester);
      expect(switched, isNot(initial));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_colors(tester), switched);
      await pumpNavigationFrames(tester);
      expect(_colors(tester), switched);
      expect(breath.value, 0);
    },
  );
}
