import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../shared/playback_scrubber.dart';

class TvPlayerControls extends StatelessWidget {
  const TvPlayerControls({
    super.key,
    required this.visible,
    required this.playing,
    required this.position,
    required this.duration,
    required this.focusScopeNode,
    required this.progressFocusNode,
    required this.primaryActionFocusNode,
    required this.onSeekBackward,
    required this.onSeekForward,
    required this.onTogglePlayback,
    required this.onDismiss,
    required this.onOpenSpeed,
    required this.onOpenEpisodes,
    this.onPreviousEpisode,
    this.onNextEpisode,
  });

  final bool visible;
  final bool playing;
  final Duration position;
  final Duration duration;
  final FocusScopeNode focusScopeNode;
  final FocusNode progressFocusNode;
  final FocusNode primaryActionFocusNode;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;
  final VoidCallback onTogglePlayback;
  final VoidCallback onDismiss;
  final VoidCallback onOpenSpeed;
  final VoidCallback onOpenEpisodes;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final primary = FocusManager.instance.primaryFocus;
    final key = event.logicalKey;
    if (primary == progressFocusNode) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        onSeekBackward();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        onSeekForward();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        primaryActionFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        return KeyEventResult.handled;
      }
    } else if (primary != null) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        primary.focusInDirection(TraversalDirection.left);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        primary.focusInDirection(TraversalDirection.right);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        progressFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        onDismiss();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final progress = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return ExcludeFocus(
      excluding: !visible,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedOpacity(
          key: const ValueKey('tv-player-controls-opacity'),
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(
            ignoring: !visible,
            child: FocusScope(
              node: focusScopeNode,
              child: Focus(
                onKeyEvent: _handleKey,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xE6000000)],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(40, 36, 40, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TvProgress(
                          focusNode: progressFocusNode,
                          value: progress,
                          label:
                              '${formatPlaybackTime(position)} / ${formatPlaybackTime(duration)}',
                        ),
                        const SizedBox(height: 12),
                        FocusTraversalGroup(
                          policy: OrderedTraversalPolicy(),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (onPreviousEpisode != null)
                                _orderedAction(
                                  0,
                                  icon: Icons.skip_previous,
                                  label: '上一集',
                                  onPressed: onPreviousEpisode!,
                                ),
                              _orderedAction(
                                1,
                                focusNode: primaryActionFocusNode,
                                icon: playing ? Icons.pause : Icons.play_arrow,
                                label: playing ? '暂停' : '播放',
                                onPressed: onTogglePlayback,
                              ),
                              if (onNextEpisode != null)
                                _orderedAction(
                                  2,
                                  icon: Icons.skip_next,
                                  label: '下一集',
                                  onPressed: onNextEpisode!,
                                ),
                              _orderedAction(
                                3,
                                icon: Icons.speed,
                                label: '倍速',
                                onPressed: onOpenSpeed,
                              ),
                              _orderedAction(
                                4,
                                icon: Icons.video_library_outlined,
                                label: '选集',
                                onPressed: onOpenEpisodes,
                              ),
                            ],
                          ),
                        ),
                      ],
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

  Widget _orderedAction(
    double order, {
    FocusNode? focusNode,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => FocusTraversalOrder(
    order: NumericFocusOrder(order),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _TvPlayerAction(
        focusNode: focusNode,
        icon: icon,
        label: label,
        onPressed: onPressed,
      ),
    ),
  );
}

class _TvProgress extends StatefulWidget {
  const _TvProgress({
    required this.focusNode,
    required this.value,
    required this.label,
  });

  final FocusNode focusNode;
  final double value;
  final String label;

  @override
  State<_TvProgress> createState() => _TvProgressState();
}

class _TvProgressState extends State<_TvProgress> {
  bool focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => focused = value),
    child: AnimatedContainer(
      key: const ValueKey('tv-player-progress'),
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(12),
        border: focused ? Border.all(color: AppColors.accent, width: 3) : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(widget.label, style: const TextStyle(fontSize: 14)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: LinearProgressIndicator(
              value: widget.value,
              minHeight: focused ? 8 : 5,
              backgroundColor: Colors.white24,
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    ),
  );
}

class _TvPlayerAction extends StatefulWidget {
  const _TvPlayerAction({
    this.focusNode,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final FocusNode? focusNode;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_TvPlayerAction> createState() => _TvPlayerActionState();
}

class _TvPlayerActionState extends State<_TvPlayerAction> {
  bool focused = false;

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: focused ? 1.06 : 1,
    duration: const Duration(milliseconds: 120),
    child: Material(
      color: focused
          ? AppColors.accent.withValues(alpha: 0.28)
          : Colors.white10,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        focusNode: widget.focusNode,
        onFocusChange: (value) => setState(() => focused = value),
        onTap: widget.onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minWidth: 96, minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: focused
                ? Border.all(color: AppColors.accent, width: 3)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 26),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
