import 'package:flutter/material.dart';

import '../app/theme.dart';

typedef PlaybackBufferedRange = ({Duration start, Duration end});

/// Merges native player buffered ranges for painting.
///
/// Ranges may be unordered, overlapping, or separated by gaps after a seek.
/// Overlapping and touching ranges are combined; gaps are kept so the scrubber
/// does not look loaded across unbuffered holes.
List<PlaybackBufferedRange> mergeBufferedRanges(
  Iterable<PlaybackBufferedRange> ranges, {
  Duration duration = Duration.zero,
}) {
  final hasLimit = duration > Duration.zero;
  final cleaned = <PlaybackBufferedRange>[];
  for (final range in ranges) {
    var start = range.start < Duration.zero ? Duration.zero : range.start;
    var end = range.end;
    if (hasLimit && end > duration) end = duration;
    if (hasLimit && start >= duration) continue;
    if (end <= start) continue;
    cleaned.add((start: start, end: end));
  }
  cleaned.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  });
  if (cleaned.isEmpty) return const [];
  final merged = <PlaybackBufferedRange>[cleaned.first];
  for (var i = 1; i < cleaned.length; i++) {
    final range = cleaned[i];
    final last = merged.last;
    if (range.start <= last.end) {
      if (range.end > last.end) {
        merged[merged.length - 1] = (start: last.start, end: range.end);
      }
    } else {
      merged.add(range);
    }
  }
  return merged;
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

  final Duration position, duration;
  final List<PlaybackBufferedRange> buffered;
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
    final merged = mergeBufferedRanges(
      widget.buffered,
      duration: widget.duration,
    );
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
              final bufferedLayout = [
                for (final range in merged)
                  (
                    left:
                        width *
                        (range.start.inMilliseconds / maximum).clamp(0.0, 1.0),
                    right:
                        width *
                        (range.end.inMilliseconds / maximum).clamp(0.0, 1.0),
                  ),
              ];
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
                          key: const ValueKey('playback-track'),
                          duration: const Duration(milliseconds: 120),
                          height: active ? 6 : 4,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              for (var i = 0; i < bufferedLayout.length; i++)
                                if (bufferedLayout[i].right >
                                    bufferedLayout[i].left)
                                  Positioned(
                                    key: ValueKey('buffered-range-$i'),
                                    left: bufferedLayout[i].left,
                                    width:
                                        bufferedLayout[i].right -
                                        bufferedLayout[i].left,
                                    top: 0,
                                    bottom: 0,
                                    child: const ColoredBox(
                                      color: Colors.white54,
                                    ),
                                  ),
                              Positioned(
                                left: 0,
                                width: width * played,
                                top: 0,
                                bottom: 0,
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
