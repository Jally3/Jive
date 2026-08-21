import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/playback_scrubber.dart';

void main() {
  group('mergeBufferedRanges', () {
    test('merges unordered overlapping and adjacent ranges', () {
      expect(
        mergeBufferedRanges(const [
          (start: Duration(seconds: 8), end: Duration(seconds: 15)),
          (start: Duration.zero, end: Duration(seconds: 5)),
          (start: Duration(seconds: 4), end: Duration(seconds: 10)),
          (start: Duration(seconds: 15), end: Duration(seconds: 20)),
        ]),
        const [(start: Duration.zero, end: Duration(seconds: 20))],
      );
    });

    test('keeps disjoint ranges after a seek gap', () {
      expect(
        mergeBufferedRanges(const [
          (start: Duration(seconds: 25), end: Duration(seconds: 30)),
          (start: Duration.zero, end: Duration(seconds: 10)),
          (start: Duration(seconds: 12), end: Duration(seconds: 20)),
        ]),
        const [
          (start: Duration.zero, end: Duration(seconds: 10)),
          (start: Duration(seconds: 12), end: Duration(seconds: 20)),
          (start: Duration(seconds: 25), end: Duration(seconds: 30)),
        ],
      );
    });

    test('drops inverted ranges and clamps to duration', () {
      expect(
        mergeBufferedRanges(const [
          (start: Duration(seconds: 2), end: Duration(seconds: 4)),
          (start: Duration(seconds: 8), end: Duration(seconds: 3)),
          (start: Duration(seconds: 9), end: Duration(seconds: 15)),
        ], duration: const Duration(seconds: 10)),
        const [
          (start: Duration(seconds: 2), end: Duration(seconds: 4)),
          (start: Duration(seconds: 9), end: Duration(seconds: 10)),
        ],
      );
    });
  });

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
              buffered: const [
                (start: Duration.zero, end: Duration(minutes: 4)),
              ],
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
              buffered: const [],
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
          buffered: const [(start: Duration.zero, end: Duration(minutes: 5))],
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
          buffered: const [],
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

  testWidgets('semantics increase and decrease each commit exactly once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final starts = <Duration>[];
    final updates = <Duration>[];
    final commits = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PlaybackScrubber(
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 10),
          buffered: const [(start: Duration.zero, end: Duration(minutes: 3))],
          enabled: true,
          onSeekStart: starts.add,
          onSeekUpdate: updates.add,
          onSeekEnd: commits.add,
          onSeekCancel: () {},
        ),
      ),
    );

    final node = tester.getSemantics(find.byType(PlaybackScrubber));
    final data = node.getSemanticsData();
    expect(data.flagsCollection.isSlider, isTrue);
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);

    final progress = find.semantics.byLabel('播放进度');
    tester.semantics.increase(progress);
    await tester.pump();
    tester.semantics.decrease(progress);
    await tester.pump();

    expect(starts, const [
      Duration(minutes: 2, seconds: 10),
      Duration(minutes: 1, seconds: 50),
    ]);
    expect(commits, starts);
    expect(updates, isEmpty);
    semantics.dispose();
  });

  testWidgets('paints disjoint buffered ranges instead of filling the gap', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            child: PlaybackScrubber(
              position: Duration(minutes: 6),
              duration: Duration(minutes: 10),
              buffered: [
                (start: Duration.zero, end: Duration(minutes: 2)),
                (start: Duration(minutes: 5), end: Duration(minutes: 7)),
              ],
              enabled: true,
              onSeekStart: _noopSeek,
              onSeekUpdate: _noopSeek,
              onSeekEnd: _noopSeek,
              onSeekCancel: _noop,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('buffered-range-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('buffered-range-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('buffered-range-2')), findsNothing);

    final track = tester.getRect(find.byKey(const ValueKey('playback-track')));
    final first = tester.getRect(
      find.byKey(const ValueKey('buffered-range-0')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('buffered-range-1')),
    );
    expect(first.left, closeTo(track.left, 1));
    expect(first.width, closeTo(track.width * 0.2, 1.5));
    expect(second.left, closeTo(track.left + track.width * 0.5, 1.5));
    expect(second.width, closeTo(track.width * 0.2, 1.5));
    expect(first.right, lessThan(second.left));
  });

  testWidgets('paints a buffered island that does not start at zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            child: PlaybackScrubber(
              position: Duration(minutes: 8),
              duration: Duration(minutes: 10),
              buffered: [
                (start: Duration(minutes: 7), end: Duration(minutes: 9)),
              ],
              enabled: true,
              onSeekStart: _noopSeek,
              onSeekUpdate: _noopSeek,
              onSeekEnd: _noopSeek,
              onSeekCancel: _noop,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('buffered-range-0')), findsOneWidget);
    final track = tester.getRect(find.byKey(const ValueKey('playback-track')));
    final island = tester.getRect(
      find.byKey(const ValueKey('buffered-range-0')),
    );
    expect(island.left, closeTo(track.left + track.width * 0.7, 1.5));
    expect(island.width, closeTo(track.width * 0.2, 1.5));
  });
}

void _noopSeek(Duration _) {}

void _noop() {}
