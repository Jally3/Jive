import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

import 'package:jive/features/detail/detail_page.dart';
import 'package:jive/features/home/home_page.dart';
import 'package:jive/features/player/player_page.dart';
import 'package:jive/features/player/widgets/player_error_view.dart';
import 'package:jive/main.dart' as app_main;
import 'package:jive/shared/video_card.dart';

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<bool> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

Future<void> _goBack(WidgetTester tester) async {
  final customBack = find.byTooltip('返回');
  final materialBack = find.byType(BackButton);
  final cupertinoBack = find.byType(CupertinoNavigationBarBackButton);
  if (customBack.evaluate().isNotEmpty) {
    await tester.tap(customBack.first, warnIfMissed: false);
  } else if (materialBack.evaluate().isNotEmpty) {
    await tester.tap(materialBack.first, warnIfMissed: false);
  } else if (cupertinoBack.evaluate().isNotEmpty) {
    await tester.tap(cupertinoBack.first, warnIfMissed: false);
  } else {
    await tester.pageBack();
  }
  await _pumpFor(tester, const Duration(milliseconds: 800));
}

VideoCard? _nextVisibleCard(Set<String> tested) {
  for (final element in find.byType(VideoCard).evaluate()) {
    final card = element.widget as VideoCard;
    if (!tested.contains(card.video.globalId)) return card;
  }
  return null;
}

Future<VideoCard?> _findNextCard(
  WidgetTester tester,
  Set<String> tested,
) async {
  for (var scroll = 0; scroll < 12; scroll++) {
    final card = _nextVisibleCard(tested);
    if (card != null) return card;
    final homeScroll = find.byWidgetPredicate(
      (widget) => widget is CustomScrollView && widget.controller != null,
    );
    if (homeScroll.evaluate().isEmpty) return null;
    await tester.drag(
      homeScroll.first,
      const Offset(0, -520),
      warnIfMissed: false,
    );
    await _pumpFor(tester, const Duration(seconds: 1));
  }
  return null;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'generate startup traces for the first ten home videos',
    (tester) async {
      app_main.main();
      await tester.pump();
      final homeReady = await _waitUntil(
        tester,
        () =>
            find.byType(HomePage).evaluate().isNotEmpty &&
            find.byType(VideoCard).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 40),
      );
      expect(homeReady, isTrue, reason: '首页视频列表未在 40 秒内加载完成');

      final tested = <String>{};
      for (var index = 0; index < 10; index++) {
        final card = await _findNextCard(tester, tested);
        if (card == null) break;
        tested.add(card.video.globalId);
        debugPrint(
          'PLAYBACK_TRACE_BATCH item=${index + 1}/10 '
          'video=${card.video.globalId} title=${card.video.title}',
        );

        final cardFinder = find.byKey(ValueKey('video-${card.video.globalId}'));
        await tester.ensureVisible(cardFinder);
        await tester.tap(cardFinder, warnIfMissed: false);

        final detailReady = await _waitUntil(
          tester,
          () =>
              find.byType(VideoDetailPage).evaluate().isNotEmpty &&
              find
                  .byKey(const ValueKey('detail-play-button'))
                  .evaluate()
                  .isNotEmpty,
          timeout: const Duration(seconds: 30),
        );
        if (!detailReady) {
          debugPrint('PLAYBACK_TRACE_BATCH detail_failed item=${index + 1}');
          await _goBack(tester);
          continue;
        }

        final playButton = find.byKey(const ValueKey('detail-play-button'));
        final button = tester.widget<FilledButton>(playButton);
        if (button.onPressed == null) {
          debugPrint('PLAYBACK_TRACE_BATCH unplayable item=${index + 1}');
          await _goBack(tester);
          continue;
        }
        await tester.tap(playButton, warnIfMissed: false);

        final playerOpened = await _waitUntil(
          tester,
          () => find.byType(PlayerPage).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 15),
        );
        if (playerOpened) {
          await _waitUntil(
            tester,
            () =>
                find.byType(VideoPlayer).evaluate().isNotEmpty ||
                find.byType(PlayerErrorView).evaluate().isNotEmpty,
            timeout: const Duration(seconds: 60),
          );
          // Let the terminal logger flush the completed/failed trace before
          // navigating away and starting the next attempt.
          await _pumpFor(tester, const Duration(seconds: 1));
          await _goBack(tester);
        } else {
          debugPrint('PLAYBACK_TRACE_BATCH player_failed item=${index + 1}');
        }

        if (find.byType(VideoDetailPage).evaluate().isNotEmpty) {
          await _goBack(tester);
        }
        await _waitUntil(
          tester,
          () => find.byType(HomePage).evaluate().isNotEmpty,
          timeout: const Duration(seconds: 10),
        );
      }

      expect(tested, hasLength(10), reason: '首页未能提供 10 个不同的视频卡片');
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
