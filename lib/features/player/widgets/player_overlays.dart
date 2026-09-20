import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 沉浸式播放器左侧中部的操作锁。
class PlayerScreenLockButton extends StatelessWidget {
  const PlayerScreenLockButton({
    super.key,
    required this.locked,
    required this.visible,
    required this.onPressed,
  });

  final bool locked;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      excluding: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: IgnorePointer(
          ignoring: !visible,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SafeArea(
              top: false,
              right: false,
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 24),
                child: IconButton.filledTonal(
                  key: const ValueKey('player-screen-lock-button'),
                  onPressed: onPressed,
                  tooltip: locked ? '解除锁定' : '锁定操作',
                  iconSize: 22,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(48),
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.black.withValues(alpha: 0.45),
                  ),
                  icon: Icon(locked ? Icons.lock : Icons.lock_open),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放完成后的中央重播入口。暂停状态不会构建此按钮。
class PlayerCenterReplayButton extends StatelessWidget {
  const PlayerCenterReplayButton({
    super.key,
    required this.controller,
    required this.controlsVisible,
    required this.onReplay,
  });

  final VideoPlayerController controller;
  final bool controlsVisible;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) => AnimatedOpacity(
        opacity: controlsVisible && controller.value.isCompleted ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !controlsVisible || !controller.value.isCompleted,
          child: Center(
            child: controller.value.isCompleted
                ? IconButton.filled(
                    key: const ValueKey('player-center-replay-button'),
                    onPressed: onReplay,
                    tooltip: '重新播放',
                    iconSize: 38,
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(60),
                      backgroundColor: const Color(0x99F2F2F2),
                      foregroundColor: const Color(0xFF242424),
                    ),
                    icon: const Icon(Icons.replay),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
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
