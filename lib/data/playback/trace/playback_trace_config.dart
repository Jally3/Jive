abstract final class PlaybackTraceConfig {
  const PlaybackTraceConfig._();

  /// Compile-time switch for startup tracing. It is intentionally disabled by
  /// default so production playback has no logging or allocation overhead.
  static const bool enabled = bool.fromEnvironment(
    'JIVE_PLAYBACK_TRACE',
    defaultValue: false,
  );
}
