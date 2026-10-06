import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/playback/playback_startup_watchdog.dart';

void main() {
  testWidgets('no bytes triggers fallback after eight seconds', (tester) async {
    final pending = Completer<void>();
    final watchdog = PlaybackStartupWatchdog();
    Object? failure;
    final result = watchdog.waitFor(pending.future).catchError((Object error) {
      failure = error;
    });
    await tester.pump(const Duration(seconds: 7));
    expect(failure, isNull);
    watchdog.recordBytes(0);
    await tester.pump(const Duration(seconds: 1));
    await result;
    expect(
      (failure as PlaybackStartupTimeout).reason,
      PlaybackStartupTimeoutReason.noProgress,
    );
    pending.complete();
    await tester.pump();
  });

  testWidgets(
    'useful bytes extend the idle window until initialization succeeds',
    (tester) async {
      final pending = Completer<void>();
      final watchdog = PlaybackStartupWatchdog();
      var completed = false;
      final result = watchdog
          .waitFor(pending.future)
          .then((_) => completed = true);
      await tester.pump(const Duration(seconds: 7));
      watchdog.recordBytes(1024);
      await tester.pump(const Duration(seconds: 7));
      expect(completed, isFalse);
      expect(watchdog.receivedBytes, 1024);
      pending.complete();
      await tester.pump();
      await result;
      expect(completed, isTrue);
      await tester.pump(const Duration(seconds: 20));
    },
  );

  testWidgets(
    'continued traffic cannot extend the hard twenty second deadline',
    (tester) async {
      final pending = Completer<void>();
      final watchdog = PlaybackStartupWatchdog();
      Object? failure;
      final result = watchdog.waitFor(pending.future).catchError((
        Object error,
      ) {
        failure = error;
      });
      for (var index = 0; index < 4; index++) {
        await tester.pump(const Duration(seconds: 5));
        watchdog.recordBytes(1024);
      }
      await result;
      expect(
        (failure as PlaybackStartupTimeout).reason,
        PlaybackStartupTimeoutReason.deadline,
      );
      // A late native failure must still be consumed after fallback has started.
      pending.completeError(StateError('late initialization failure'));
      await tester.pump();
    },
  );

  testWidgets(
    'a stalled transfer times out eight seconds after its last bytes',
    (tester) async {
      final pending = Completer<void>();
      final watchdog = PlaybackStartupWatchdog();
      Object? failure;
      final result = watchdog.waitFor(pending.future).catchError((
        Object error,
      ) {
        failure = error;
      });
      await tester.pump(const Duration(seconds: 3));
      watchdog.recordBytes(64);
      await tester.pump(const Duration(seconds: 7));
      expect(failure, isNull);
      await tester.pump(const Duration(seconds: 1));
      await result;
      expect(
        (failure as PlaybackStartupTimeout).reason,
        PlaybackStartupTimeoutReason.noProgress,
      );
      pending.complete();
      await tester.pump();
    },
  );

  testWidgets('native errors stop both timers', (tester) async {
    final pending = Completer<void>();
    final watchdog = PlaybackStartupWatchdog();
    final failure = StateError('native failure');
    Object? observed;
    final result = watchdog.waitFor(pending.future).catchError((Object error) {
      observed = error;
    });
    pending.completeError(failure);
    await tester.pump();
    await result;
    expect(observed, same(failure));
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('page cancellation releases the pending watchdog', (
    tester,
  ) async {
    final pending = Completer<void>();
    final watchdog = PlaybackStartupWatchdog();
    Object? failure;
    final result = watchdog.waitFor(pending.future).catchError((Object error) {
      failure = error;
    });
    watchdog.cancel();
    await tester.pump();
    await result;
    expect(failure, isA<StateError>());
    pending.complete();
    await tester.pump();
  });
}
