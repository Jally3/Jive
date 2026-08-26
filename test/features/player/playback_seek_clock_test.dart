import 'package:flutter_test/flutter_test.dart';
import 'package:jive/features/player/playback_seek_clock.dart';

void main() {
  group('rememberPlaybackDuration', () {
    test('keeps the longest duration seen this playback', () {
      const tenMinutes = Duration(minutes: 10);
      expect(
        rememberPlaybackDuration(
          playerDuration: const Duration(seconds: 15),
          observedDuration: tenMinutes,
        ),
        tenMinutes,
      );
    });

    test('promotes a newly reported longer player duration', () {
      expect(
        rememberPlaybackDuration(
          playerDuration: const Duration(minutes: 10),
          observedDuration: const Duration(seconds: 15),
        ),
        const Duration(minutes: 10),
      );
    });

    test('filtered session duration is the playable floor, not original', () {
      expect(
        sessionPlayableDuration(originalDurationMs: 600_000, removedMs: 90_000),
        const Duration(seconds: 510),
      );
      expect(
        rememberPlaybackDuration(
          playerDuration: const Duration(seconds: 15),
          observedDuration: Duration.zero,
          sessionPlayableDuration: sessionPlayableDuration(
            originalDurationMs: 600_000,
            removedMs: 90_000,
          ),
        ),
        const Duration(seconds: 510),
      );
    });
  });

  test(
    'freezeSeekClock does not shrink after a longer duration was trusted',
    () {
      expect(
        freezeSeekClock(
          playerDuration: const Duration(seconds: 15),
          observedDuration: const Duration(minutes: 10),
        ),
        const Duration(minutes: 10),
      );
      expect(
        freezeSeekClock(
          playerDuration: const Duration(minutes: 10),
          observedDuration: Duration.zero,
        ),
        const Duration(minutes: 10),
      );
    },
  );

  test(
    'seekLandedNear treats keyframe snap as success and ad-sized jumps as miss',
    () {
      const target = Duration(minutes: 5);
      expect(
        seekLandedNear(target + const Duration(seconds: 3), target),
        isTrue,
      );
      expect(
        seekLandedNear(target + const Duration(seconds: 12), target),
        isFalse,
      );
    },
  );
}
