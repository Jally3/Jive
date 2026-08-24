import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../shared/playback_scrubber.dart';

/// 缓冲指示：播放中缓冲且不在滑屏/提交 seek 时，画面中央显示菊花。
class PlayerBufferingIndicator extends StatelessWidget {
  const PlayerBufferingIndicator({
    super.key,
    required this.controller,
    required this.screenSeeking,
    required this.seekCommitting,
  });

  final VideoPlayerController controller;
  final ValueNotifier<bool> screenSeeking;
  final ValueNotifier<bool> seekCommitting;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, screenSeeking, seekCommitting]),
      builder: (_, _) {
        if (!controller.value.isBuffering ||
            screenSeeking.value ||
            seekCommitting.value) {
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('player-buffering-indicator'),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 手势指示：纵向滑动亮度/音量、长按 2 倍速、滑屏 seek
/// 三种状态共用的画面中央浮层，按优先级只展示一种。
class PlayerGestureIndicator extends StatelessWidget {
  const PlayerGestureIndicator({
    super.key,
    required this.controller,
    required this.previewPosition,
    required this.seekCommitting,
    required this.screenSeeking,
    required this.speedBoosting,
    required this.verticalDrag,
    required this.positionBeforeSeek,
  });

  final VideoPlayerController controller;
  final ValueNotifier<Duration?> previewPosition;
  final ValueNotifier<bool> seekCommitting;
  final ValueNotifier<bool> screenSeeking;
  final ValueNotifier<bool> speedBoosting;
  final ValueNotifier<({bool isVolume, double value})?> verticalDrag;
  final Duration positionBeforeSeek;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        previewPosition,
        seekCommitting,
        screenSeeking,
        speedBoosting,
        verticalDrag,
      ]),
      builder: (_, _) {
        final drag = verticalDrag.value;
        if (drag != null) {
          return IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('vertical-drag-indicator'),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      drag.isVolume
                          ? (drag.value <= 0
                                ? Icons.volume_off
                                : drag.value < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up)
                          : Icons.brightness_6,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${(drag.value * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (speedBoosting.value && !screenSeeking.value) {
          return IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('speed-boost-indicator'),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fast_forward, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      '2× 播放中',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (!screenSeeking.value) {
          return const SizedBox.shrink();
        }
        final target = previewPosition.value ?? controller.value.position;
        final delta = target - positionBeforeSeek;
        final forward = !delta.isNegative;
        return IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('screen-seek-indicator'),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  seekCommitting.value
                      ? const SizedBox.square(
                          dimension: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          forward ? Icons.fast_forward : Icons.fast_rewind,
                          color: Colors.white,
                          size: 30,
                        ),
                  const SizedBox(height: 4),
                  Text(
                    formatPlaybackTime(target),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '/ ${formatPlaybackTime(controller.value.duration)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
