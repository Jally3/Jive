import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../app/theme.dart';

/// 暂停状态下的画面中央大播放按钮。
/// 绘制在底部控制条之后，非全屏播放器中也保持可见。
class PlayerCenterPlayButton extends StatelessWidget {
  const PlayerCenterPlayButton({
    super.key,
    required this.controller,
    required this.screenSeeking,
    required this.controlsVisible,
    required this.onResume,
  });

  final VideoPlayerController controller;
  final ValueNotifier<bool> screenSeeking;
  final bool controlsVisible;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, screenSeeking]),
      builder: (_, _) {
        final paused = !controller.value.isPlaying && !screenSeeking.value;
        return AnimatedOpacity(
          opacity: controlsVisible || paused ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !controlsVisible && !paused,
            child: Center(
              child: paused
                  ? IconButton.filled(
                      onPressed: onResume,
                      tooltip: controller.value.isCompleted ? '重新播放' : '播放',
                      iconSize: 38,
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(60),
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.onAccent,
                      ),
                      icon: const Icon(Icons.play_arrow),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}

/// 左下角的纵向音量滑条（非紧凑控制布局下由音量按钮唤出）。
class PlayerVolumeSlider extends StatelessWidget {
  const PlayerVolumeSlider({
    super.key,
    required this.controller,
    required this.overlayLayout,
    required this.onShowControls,
    required this.onVolumeChanged,
  });

  final VideoPlayerController controller;
  final bool overlayLayout;
  final VoidCallback onShowControls;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: EdgeInsets.only(
          left:
              46 + (overlayLayout ? MediaQuery.viewPaddingOf(context).left : 0),
          bottom:
              60 +
              (overlayLayout ? MediaQuery.viewPaddingOf(context).bottom : 0),
        ),
        child: Listener(
          onPointerDown: (_) => onShowControls(),
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: SizedBox(
                  height: 140,
                  width: 48,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      value: controller.value.volume.clamp(0.0, 1.0),
                      onChangeStart: (_) => onShowControls(),
                      onChanged: onVolumeChanged,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
