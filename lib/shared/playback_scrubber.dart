import 'package:flutter/material.dart';

import '../app/theme.dart';

typedef PlaybackBufferedRange = ({Duration start, Duration end});

/// Returns the end of the buffered region that can be played continuously
/// from the beginning of the video.
///
/// Buffered ranges may be unordered, overlapping, or separated by gaps after
/// a seek. A gap stops the continuous region, so later ranges are ignored.
Duration continuousBufferedEnd(Iterable<PlaybackBufferedRange> ranges) {
  final sorted =
      ranges
          .where(
            (range) => range.end > Duration.zero && range.end >= range.start,
          )
          .map(
            (range) => (
              start: range.start < Duration.zero ? Duration.zero : range.start,
              end: range.end,
            ),
          )
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  var continuousEnd = Duration.zero;
  for (final range in sorted) {
    if (range.start > continuousEnd) break;
    if (range.end > continuousEnd) continuousEnd = range.end;
  }
  return continuousEnd;
}

Duration positionFromFraction(double fraction, Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  return Duration(
    milliseconds: (duration.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
  );
}

Duration positionFromDragDelta({
  required Duration start,
  required double delta,
  required double width,
  required Duration duration,
}) {
  if (width <= 0 || duration <= Duration.zero) return Duration.zero;
  final target =
      start.inMilliseconds + (duration.inMilliseconds * delta / width).round();
  return Duration(milliseconds: target.clamp(0, duration.inMilliseconds));
}

String formatPlaybackTime(Duration value) {
  final total = value.isNegative ? 0 : value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
      : '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class PlaybackScrubber extends StatefulWidget {
  const PlaybackScrubber({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.enabled,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onSeekCancel,
    this.committing = false,
    this.showTime = true,
  });

  final Duration position, duration, buffered;
  final bool enabled;
  final bool committing;
  final bool showTime;
  final ValueChanged<Duration> onSeekStart, onSeekUpdate, onSeekEnd;
  final VoidCallback onSeekCancel;

  @override
  State<PlaybackScrubber> createState() => _PlaybackScrubberState();
}

class _PlaybackScrubberState extends State<PlaybackScrubber> {
  static const _hitHeight = 48.0;
  static const _thumbRadius = 6.0;
  static const _activeThumbRadius = 9.0;
  static const _bubbleWidth = 86.0;

  Duration? _dragPosition;
  bool _dragging = false;

  bool get _interactive => widget.enabled && !widget.committing;

  Duration _target(double dx, double width) =>
      positionFromFraction(width <= 0 ? 0 : dx / width, widget.duration);

  void _start(DragStartDetails details, double width) {
    final target = _target(details.localPosition.dx, width);
    setState(() {
      _dragging = true;
      _dragPosition = target;
    });
    widget.onSeekStart(target);
  }

  void _update(DragUpdateDetails details, double width) {
    final target = _target(details.localPosition.dx, width);
    setState(() => _dragPosition = target);
    widget.onSeekUpdate(target);
  }

  void _end() {
    final target = _dragPosition ?? widget.position;
    setState(() {
      _dragging = false;
      _dragPosition = null;
    });
    widget.onSeekEnd(target);
  }

  void _cancel() {
    setState(() {
      _dragging = false;
      _dragPosition = null;
    });
    widget.onSeekCancel();
  }

  void _tap(TapUpDetails details, double width) {
    final target = _target(details.localPosition.dx, width);
    widget.onSeekStart(target);
    widget.onSeekEnd(target);
  }

  Duration _semanticTarget(Duration position, {required bool increase}) {
    final durationMs = widget.duration.inMilliseconds;
    if (durationMs <= 0) return Duration.zero;
    final proportionalStep = durationMs ~/ 10;
    final stepMs = proportionalStep.clamp(1000, 10000);
    final delta = increase ? stepMs : -stepMs;
    return Duration(
      milliseconds: (position.inMilliseconds + delta).clamp(0, durationMs),
    );
  }

  void _semanticSeek({required bool increase}) {
    if (!_interactive) return;
    final target = _semanticTarget(
      _dragPosition ?? widget.position,
      increase: increase,
    );
    widget.onSeekStart(target);
    widget.onSeekEnd(target);
  }

  @override
  Widget build(BuildContext context) {
    final displayPosition = _dragPosition ?? widget.position;
    final maximum = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;
    final played = (displayPosition.inMilliseconds / maximum).clamp(0.0, 1.0);
    final loaded = (widget.buffered.inMilliseconds / maximum).clamp(0.0, 1.0);
    final active = _dragging || widget.committing;
    final increasedPosition = _semanticTarget(displayPosition, increase: true);
    final decreasedPosition = _semanticTarget(displayPosition, increase: false);

    return Semantics(
      container: true,
      excludeSemantics: true,
      slider: true,
      label: '播放进度',
      value:
          '${formatPlaybackTime(displayPosition)} / ${formatPlaybackTime(widget.duration)}',
      increasedValue:
          '${formatPlaybackTime(increasedPosition)} / ${formatPlaybackTime(widget.duration)}',
      decreasedValue:
          '${formatPlaybackTime(decreasedPosition)} / ${formatPlaybackTime(widget.duration)}',
      enabled: _interactive,
      onIncrease: _interactive ? () => _semanticSeek(increase: true) : null,
      onDecrease: _interactive ? () => _semanticSeek(increase: false) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showTime)
            Text(
              '${formatPlaybackTime(displayPosition)} / ${formatPlaybackTime(widget.duration)}',
              key: const ValueKey('playback-time'),
              style: const TextStyle(fontSize: 12),
            ),
          LayoutBuilder(
            builder: (_, constraints) {
              final width = constraints.maxWidth;
              final thumbX = width * played;
              final bubbleLeft = (thumbX - _bubbleWidth / 2).clamp(
                0.0,
                (width - _bubbleWidth).clamp(0.0, double.infinity),
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: _interactive
                    ? (details) => _start(details, width)
                    : null,
                onHorizontalDragUpdate: _interactive
                    ? (details) => _update(details, width)
                    : null,
                onHorizontalDragEnd: _interactive ? (_) => _end() : null,
                onHorizontalDragCancel: _interactive ? _cancel : null,
                onTapUp: _interactive
                    ? (details) => _tap(details, width)
                    : null,
                child: SizedBox(
                  height: _hitHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (_dragging)
                        Positioned(
                          key: const ValueKey('seek-time-bubble'),
                          left: bubbleLeft,
                          top: -42,
                          width: _bubbleWidth,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                formatPlaybackTime(displayPosition),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Align(
                        alignment: Alignment.center,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          height: active ? 6 : 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: loaded,
                                child: const ColoredBox(color: Colors.white54),
                              ),
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: played,
                                child: const ColoredBox(
                                  color: AppColors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment(played * 2 - 1, 0),
                        child: AnimatedContainer(
                          key: const ValueKey('playback-thumb'),
                          duration: const Duration(milliseconds: 120),
                          width:
                              2 * (active ? _activeThumbRadius : _thumbRadius),
                          height:
                              2 * (active ? _activeThumbRadius : _thumbRadius),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.enabled
                                ? AppColors.accent
                                : Colors.grey,
                            boxShadow: active
                                ? const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 4,
                                    ),
                                  ]
                                : null,
                          ),
                          child: widget.committing
                              ? const Padding(
                                  padding: EdgeInsets.all(3),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
