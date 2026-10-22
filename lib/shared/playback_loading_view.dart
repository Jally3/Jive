import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import 'playback_loading_controller.dart';

export 'playback_loading_controller.dart' show PlaybackLoadingPhase;

/// Shows real playback preparation steps without estimated percentages/times.
/// Delays labels once per wait, then keeps their layout stable across phases.
class PlaybackLoadingView extends StatefulWidget {
  const PlaybackLoadingView({
    super.key,
    this.phase,
    this.session,
    this.onDarkSurface = true,
    this.labelDelay = const Duration(milliseconds: 200),
  }) : assert((phase == null) != (session == null));

  final PlaybackLoadingPhase? phase;
  final Object? session;
  final bool onDarkSurface;
  final Duration labelDelay;

  @override
  State<PlaybackLoadingView> createState() => _PlaybackLoadingViewState();
}

class _PlaybackLoadingViewState extends State<PlaybackLoadingView> {
  Timer? _labelTimer;
  bool _showLabel = false;

  @override
  void initState() {
    super.initState();
    _scheduleLabel();
  }

  @override
  void didUpdateWidget(PlaybackLoadingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_showLabel && oldWidget.labelDelay != widget.labelDelay) {
      _scheduleLabel();
    }
  }

  void _scheduleLabel() {
    _labelTimer?.cancel();
    if (widget.labelDelay == Duration.zero) {
      _showLabel = true;
      return;
    }
    _labelTimer = Timer(widget.labelDelay, () {
      if (mounted) setState(() => _showLabel = true);
    });
  }

  @override
  void dispose() {
    _labelTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foreground = widget.onDarkSurface
        ? Colors.white
        : context.appColors.text;
    final secondary = widget.onDarkSurface
        ? Colors.white70
        : context.appColors.secondary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final compact =
            constraints.hasBoundedHeight &&
            constraints.maxHeight < 160 * scaler.scale(14) / 14;
        final padding = compact ? 12.0 : 16.0;
        final width = constraints.hasBoundedWidth
            ? math.min(440.0, math.max(0.0, constraints.maxWidth - padding * 2))
            : 440.0;
        final labelStyle = DefaultTextStyle.of(
          context,
        ).style.merge(TextStyle(color: foreground, height: 1.4, fontSize: 14));
        final stepStyle = labelStyle.copyWith(fontSize: 12);
        final direction = Directionality.of(context);
        Size measure(String text, TextStyle style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
          )..layout(maxWidth: width);
          final size = painter.size;
          painter.dispose();
          return size;
        }

        // Measure all messages, including exceptional paths, so changing to a
        // longer line cannot move the spinner. Respect width and text scaling.
        final labelHeight = PlaybackLoadingPhase.values
            .map((phase) => measure(phase.label, labelStyle).height)
            .reduce(math.max);
        var rows = 1;
        var rowWidth = 0.0;
        var rowHeight = 14.0;
        for (final title in _stepTitles) {
          final size = measure(title, stepStyle);
          final itemWidth = size.width + 18;
          final nextWidth = rowWidth == 0
              ? itemWidth
              : rowWidth + 14 + itemWidth;
          if (rowWidth > 0 && nextWidth > width) {
            rows++;
            rowWidth = itemWidth;
          } else {
            rowWidth = nextWidth;
          }
          rowHeight = math.max(rowHeight, size.height);
        }
        final stepsHeight = rows * rowHeight + (rows - 1) * 8;
        final contentHeight = labelHeight + (compact ? 0 : 16 + stepsHeight);
        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(padding),
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: compact ? 24 : 32,
                    child: const CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(height: compact ? 12 : 16),
                  SizedBox(
                    height: contentHeight,
                    child: _showLabel
                        ? _PlaybackLoadingContent(
                            phase: widget.phase,
                            session: widget.session,
                            compact: compact,
                            labelHeight: labelHeight,
                            labelStyle: labelStyle,
                            stepStyle: stepStyle,
                            foreground: foreground,
                            secondary: secondary,
                            accent: context.appColors.accent,
                          )
                        : null,
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

const _stepTitles = ['播放信息', '准备视频', '加载画面'];

/// Only the label and step indicators subscribe to phase changes.
class _PlaybackLoadingContent extends StatelessWidget {
  const _PlaybackLoadingContent({
    required this.phase,
    required this.session,
    required this.compact,
    required this.labelHeight,
    required this.labelStyle,
    required this.stepStyle,
    required this.foreground,
    required this.secondary,
    required this.accent,
  });

  final PlaybackLoadingPhase? phase;
  final Object? session;
  final bool compact;
  final double labelHeight;
  final TextStyle labelStyle;
  final TextStyle stepStyle;
  final Color foreground;
  final Color secondary;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (session == null) return _content(phase!);
    return Consumer(
      builder: (context, ref, _) => _content(
        ref.watch(playbackLoadingProvider(session!).select((s) => s.phase)),
      ),
    );
  }

  Widget _content(PlaybackLoadingPhase current) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: labelHeight,
        child: Center(
          child: Semantics(
            liveRegion: true,
            child: Text(
              current.label,
              key: const ValueKey('playback-loading-label'),
              textAlign: TextAlign.center,
              style: labelStyle,
            ),
          ),
        ),
      ),
      if (!compact) ...[
        const SizedBox(height: 16),
        ExcludeSemantics(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            runSpacing: 8,
            children: [
              for (final (index, title) in _stepTitles.indexed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      index < current.step
                          ? Icons.check_circle_outline
                          : index == current.step
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 14,
                      color: index == current.step ? accent : secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      title,
                      style: stepStyle.copyWith(
                        color: index == current.step ? foreground : secondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    ],
  );
}

/// The detail content remains the same child when its wait overlay changes.
class PlaybackLoadingOverlay extends ConsumerWidget {
  const PlaybackLoadingOverlay({
    super.key,
    required this.session,
    required this.child,
  });

  final Object session;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(
      playbackLoadingProvider(session).select((s) => s.visible),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(excluding: visible, child: child),
        if (visible)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                key: const ValueKey('detail-playback-loading'),
                color: Colors.black.withValues(alpha: 0.88),
                child: PlaybackLoadingView(
                  session: session,
                  labelDelay: Duration.zero,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
