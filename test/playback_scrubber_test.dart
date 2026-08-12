import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/playback_scrubber.dart';

void main() {
  test('formats time and clamps positions', () {
    expect(formatPlaybackTime(const Duration(seconds: 5)), '0:05');
    expect(
      formatPlaybackTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(
      positionFromFraction(-1, const Duration(minutes: 10)),
      Duration.zero,
    );
    expect(
      positionFromFraction(.5, const Duration(minutes: 10)),
      const Duration(minutes: 5),
    );
    expect(
      positionFromFraction(2, const Duration(minutes: 10)),
      const Duration(minutes: 10),
    );
  });

  test('screen drag uses relative movement and clamps positions', () {
    const duration = Duration(minutes: 10);
    expect(
      positionFromDragDelta(
        start: const Duration(minutes: 4),
        delta: 100,
        width: 500,
        duration: duration,
      ),
      const Duration(minutes: 6),
    );
    expect(
      positionFromDragDelta(
        start: const Duration(minutes: 4),
        delta: -500,
        width: 500,
        duration: duration,
      ),
      Duration.zero,
    );
    expect(
      positionFromDragDelta(
        start: const Duration(minutes: 9),
        delta: 500,
        width: 500,
        duration: duration,
      ),
      duration,
    );
  });

  testWidgets('drag previews but commits only once after release', (
    tester,
  ) async {
    final previews = <Duration>[];
    final commits = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: PlaybackScrubber(
              position: const Duration(minutes: 2),
              duration: const Duration(minutes: 10),
              buffered: const Duration(minutes: 4),
              enabled: true,
              onSeekStart: previews.add,
              onSeekUpdate: previews.add,
              onSeekEnd: commits.add,
              onSeekCancel: () {},
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PlaybackScrubber)),
    );
    await gesture.moveBy(const Offset(80, 0));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(previews.length, greaterThanOrEqualTo(2));
    expect(commits, isEmpty);
    expect(find.byKey(const ValueKey('seek-time-bubble')), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1));
    expect(find.byKey(const ValueKey('seek-time-bubble')), findsNothing);
  });

  testWidgets('tap commits once and clamps to the track bounds', (
    tester,
  ) async {
    final starts = <Duration>[];
    final commits = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            child: PlaybackScrubber(
              position: Duration.zero,
              duration: const Duration(minutes: 10),
              buffered: Duration.zero,
              enabled: true,
              onSeekStart: starts.add,
              onSeekUpdate: (_) {},
              onSeekEnd: commits.add,
              onSeekCancel: () {},
            ),
          ),
        ),
      ),
    );

    final detector = find.descendant(
      of: find.byType(PlaybackScrubber),
      matching: find.byType(GestureDetector),
    );
    await tester.tapAt(tester.getTopRight(detector) - const Offset(1, -24));

    expect(starts, hasLength(1));
    expect(commits, hasLength(1));
    expect(
      commits.single,
      greaterThanOrEqualTo(const Duration(minutes: 9, seconds: 55)),
    );
  });

  testWidgets('committing state disables interactions and shows progress', (
    tester,
  ) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PlaybackScrubber(
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 10),
          buffered: const Duration(minutes: 5),
          enabled: true,
          committing: true,
          onSeekStart: (_) => called = true,
          onSeekUpdate: (_) => called = true,
          onSeekEnd: (_) => called = true,
          onSeekCancel: () => called = true,
        ),
      ),
    );

    final detector = tester.widget<GestureDetector>(
      find.descendant(
        of: find.byType(PlaybackScrubber),
        matching: find.byType(GestureDetector),
      ),
    );
    expect(detector.onTapUp, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(called, isFalse);
  });

  testWidgets('zero duration disables interactions', (tester) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PlaybackScrubber(
          position: Duration.zero,
          duration: Duration.zero,
          buffered: Duration.zero,
          enabled: false,
          onSeekStart: (_) => called = true,
          onSeekUpdate: (_) => called = true,
          onSeekEnd: (_) => called = true,
          onSeekCancel: () => called = true,
        ),
      ),
    );
    expect(find.text('0:00 / 0:00'), findsOneWidget);
    expect(
      tester.widget<GestureDetector>(find.byType(GestureDetector)).onTapUp,
      isNull,
    );
    expect(called, isFalse);
  });
}
