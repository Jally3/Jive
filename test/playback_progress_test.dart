import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/playback_progress.dart';

void main() {
  test('normalizes invalid playback bounds', () {
    final negative = PlaybackProgress.normalize(
      positionMs: -10,
      durationMs: 1000,
    );
    expect(negative.positionMs, 0);
    expect(negative.completed, isFalse);

    final overflow = PlaybackProgress.normalize(
      positionMs: 2000,
      durationMs: 1000,
    );
    expect(overflow.positionMs, 1000);
    expect(overflow.completed, isTrue);

    final invalidDuration = PlaybackProgress.normalize(
      positionMs: 100,
      durationMs: -1,
    );
    expect(invalidDuration.durationMs, 0);
    expect(invalidDuration.positionMs, 0);
    expect(invalidDuration.completed, isFalse);
  });

  test('uses 95 percent completion threshold and resumes correctly', () {
    final inProgress = PlaybackProgress.normalize(
      positionMs: 949,
      durationMs: 1000,
    );
    expect(inProgress.completed, isFalse);
    expect(inProgress.resumePosition(), const Duration(milliseconds: 949));

    final completed = PlaybackProgress.normalize(
      positionMs: 950,
      durationMs: 1000,
    );
    expect(completed.completed, isTrue);
    expect(completed.resumePosition(), Duration.zero);
  });
}
