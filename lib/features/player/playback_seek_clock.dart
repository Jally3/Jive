// 拖动/seek 用的稳定时钟：广告 period 可能把 `duration` 收成十几秒，
// 这里记住本段播放见过的最大可播时长，避免手势中途换尺子。

Duration rememberPlaybackDuration({
  required Duration playerDuration,
  required Duration observedDuration,
  Duration? sessionPlayableDuration,
}) {
  var best = observedDuration;
  if (playerDuration > best) best = playerDuration;
  if (sessionPlayableDuration != null && sessionPlayableDuration > best) {
    best = sessionPlayableDuration;
  }
  return best;
}

/// 会话可播时长：有过滤时用去掉广告后的长度，切勿退回含广告的原始轴。
Duration? sessionPlayableDuration({
  required int originalDurationMs,
  required int removedMs,
}) {
  final ms = originalDurationMs - removedMs;
  if (ms <= 0) return null;
  return Duration(milliseconds: ms);
}

/// 起手冻结：只取「当前播放器时长」与「本段已信任的更长时长」的较大值，
/// 不在手势中途把尺子突然加长或缩短。
Duration freezeSeekClock({
  required Duration playerDuration,
  required Duration observedDuration,
}) {
  if (observedDuration > playerDuration) return observedDuration;
  return playerDuration;
}

/// HLS 关键帧对齐常见 2–4 秒；超过此阈值视为断点吸附，不能信 native 回读。
const Duration seekLandTolerance = Duration(seconds: 4);

bool seekLandedNear(Duration landed, Duration target) =>
    (landed - target).abs() <= seekLandTolerance;
