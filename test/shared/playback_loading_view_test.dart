import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jive/shared/playback_loading_controller.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/shared/playback_loading_view.dart';

Widget _view(PlaybackLoadingPhase phase, {double textScale = 1}) => MaterialApp(
  theme: buildDarkTheme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: ColoredBox(
      color: Colors.black,
      child: PlaybackLoadingView(phase: phase),
    ),
  ),
);

void main() {
  testWidgets(
    'initial delay spans phase changes and announces only the latest phase',
    (tester) async {
      await tester.pumpWidget(_view(PlaybackLoadingPhase.playbackInfo));
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.byKey(const ValueKey('playback-loading-label')),
        findsNothing,
      );
      await tester.pumpWidget(_view(PlaybackLoadingPhase.preparingVideo));
      await tester.pump(const Duration(milliseconds: 49));
      expect(
        find.byKey(const ValueKey('playback-loading-label')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('正在准备视频…'), findsOneWidget);
      expect(find.text('正在获取播放信息…'), findsNothing);
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('playback-loading-label')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.liveRegion, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('visible phases keep text, steps and spinner geometry stable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 220);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_view(PlaybackLoadingPhase.preparingVideo));
    final spinner = find.byType(CircularProgressIndicator);
    final element = tester.element(spinner);
    final center = tester.getCenter(spinner);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getCenter(spinner), center);
    for (final phase in PlaybackLoadingPhase.values) {
      await tester.pumpWidget(_view(phase));
      expect(find.text(phase.label), findsOneWidget);
      expect(find.text('播放信息'), findsOneWidget);
      expect(tester.element(spinner), same(element));
      expect(tester.getCenter(spinner), center);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Riverpod phase updates do not rebuild the outer view or page', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final owner = Object();
    final provider = playbackLoadingProvider(owner);
    // Like PlayerPage, retain phase state even while no loading view is mounted.
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    var pageBuilds = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: Builder(
            builder: (_) {
              pageBuilds++;
              return PlaybackLoadingView(session: owner);
            },
          ),
        ),
      ),
    );
    final spinner = find.byType(CircularProgressIndicator);
    final spinnerElement = tester.element(spinner);
    final spinnerWidget = tester.widget(spinner);
    final center = tester.getCenter(spinner);
    await tester.pump(const Duration(milliseconds: 200));
    final originalBuilds = pageBuilds;
    for (final phase in PlaybackLoadingPhase.values) {
      container.read(provider.notifier).setPhase(phase);
      await tester.pump();
      expect(find.text(phase.label), findsOneWidget);
      expect(pageBuilds, originalBuilds);
      expect(tester.element(spinner), same(spinnerElement));
      expect(tester.widget(spinner), same(spinnerWidget));
      expect(tester.getCenter(spinner), center);
    }
    // Visibility changes do not rebuild the phase-only listener either.
    final labelWidget = tester.widget(
      find.text(PlaybackLoadingPhase.reconnecting.label),
    );
    container.read(provider.notifier).show(PlaybackLoadingPhase.reconnecting);
    await tester.pump();
    expect(
      tester.widget(find.text(PlaybackLoadingPhase.reconnecting.label)),
      same(labelWidget),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detail overlay changes preserve the underlying content child', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final owner = Object();
    final provider = playbackLoadingProvider(owner);
    var contentBuilds = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PlaybackLoadingOverlay(
            session: owner,
            child: Builder(
              builder: (_) {
                contentBuilds++;
                return const Text('详情内容');
              },
            ),
          ),
        ),
      ),
    );
    final contentElement = tester.element(find.text('详情内容'));
    final originalBuilds = contentBuilds;
    final controller = container.read(provider.notifier);
    controller.show(PlaybackLoadingPhase.playbackInfo);
    await tester.pump();
    expect(find.text('正在获取播放信息…'), findsOneWidget);
    expect(contentBuilds, originalBuilds);
    expect(tester.element(find.text('详情内容')), same(contentElement));
    final semantics = find.ancestor(
      of: find.text('详情内容'),
      matching: find.byType(ExcludeSemantics),
    );
    expect(tester.widget<ExcludeSemantics>(semantics.first).excluding, isTrue);
    controller.hide();
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-playback-loading')), findsNothing);
    expect(contentBuilds, originalBuilds);
    expect(tester.widget<ExcludeSemantics>(semantics.first).excluding, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large text on a short narrow video surface does not overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 180);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      _view(PlaybackLoadingPhase.reconnecting, textScale: 2),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('视频加载较慢，正在尝试重新连接…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving a short phase cancels its deferred update', (
    tester,
  ) async {
    await tester.pumpWidget(_view(PlaybackLoadingPhase.loadingPicture));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(find.byType(PlaybackLoadingView), findsNothing);
  });
}
