import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/playback_status.dart';

void main() {
  test('playback modes expose the expected labels and descriptions', () {
    expect(
      const PlaybackStatus(mode: PlaybackMode.streamingAndCaching).label,
      '边下边播',
    );
    expect(
      const PlaybackStatus(mode: PlaybackMode.cachePlayback).label,
      '缓存播放',
    );
    expect(
      const PlaybackStatus(mode: PlaybackMode.proxyWithoutCaching).label,
      '在线播放',
    );
    expect(const PlaybackStatus(mode: PlaybackMode.direct).label, '直连播放');
    expect(
      const PlaybackStatus(mode: PlaybackMode.streamingAndCaching).description,
      contains('写入本地缓存'),
    );
  });

  test('fallback reasons use fixed safe Chinese text', () {
    const status = PlaybackStatus(
      mode: PlaybackMode.direct,
      reason: PlaybackFallbackReason.manifestRequestFailed,
    );
    expect(status.reasonText, '播放清单请求失败，已回退直连。');
    expect(status.reasonText, isNot(contains('http')));
  });
}
