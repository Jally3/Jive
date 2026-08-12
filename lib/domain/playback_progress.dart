class PlaybackProgress {
  const PlaybackProgress({
    required this.positionMs,
    required this.durationMs,
    required this.completed,
  });

  final int positionMs;
  final int durationMs;
  final bool completed;

  factory PlaybackProgress.normalize({
    required int positionMs,
    required int durationMs,
    double completionThreshold = .95,
  }) {
    final duration = durationMs.clamp(0, 1 << 53);
    final position = positionMs.clamp(0, duration);
    return PlaybackProgress(
      positionMs: position,
      durationMs: duration,
      completed: duration > 0 && position / duration >= completionThreshold,
    );
  }

  Duration resumePosition() =>
      completed ? Duration.zero : Duration(milliseconds: positionMs);
}
