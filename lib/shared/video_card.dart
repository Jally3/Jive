import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../domain/video.dart';

@immutable
class VideoCardOverlay {
  const VideoCardOverlay({this.bottomLabel, this.badgeLabel});

  final String? bottomLabel;
  final String? badgeLabel;
}

class VideoCard extends StatefulWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onLongPress,
    this.progress,
    this.overlay,
  });
  final Video video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double? progress;
  final VideoCardOverlay? overlay;

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  /// 遥控器/D-pad 聚焦标记。FocusableActionDetector 只在 traditional
  /// 高亮模式（键盘/方向键）下回调 true，手机触摸永远为 false。
  bool _focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (value) => setState(() => _focused = value),
    actions: {
      // 焦点态下 OK/Enter 触发点击（遥控器 select 键映射为 ActivateIntent）。
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onTap();
          return null;
        },
      ),
    },
    child: Semantics(
      button: true,
      label: [
        '查看 ${widget.video.title}',
        widget.overlay?.bottomLabel,
        widget.overlay?.badgeLabel,
      ].whereType<String>().where((item) => item.isNotEmpty).join('，'),
      child: Container(
        // foregroundDecoration 不影响布局，仅在聚焦时叠一层描边。
        foregroundDecoration: _focused
            ? BoxDecoration(
                border: Border.all(
                  color: context.appColors.accentForeground,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(12),
              )
            : null,
        child: InkWell(
          key: ValueKey('video-${widget.video.globalId}'),
          borderRadius: BorderRadius.circular(12),
          // 焦点由外层 FocusableActionDetector 管理，避免双重焦点节点。
          canRequestFocus: false,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: _cardContent(),
        ),
      ),
    ),
  );

  Widget _cardContent() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(
        aspectRatio: 4 / 5,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: context.appColors.elevated,
                child: widget.video.posterUrl.isEmpty
                    ? Icon(
                        Icons.movie_outlined,
                        size: 44,
                        color: context.appColors.tertiary,
                      )
                    : CachedNetworkImage(
                        imageUrl: widget.video.posterUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            ColoredBox(color: context.appColors.surface),
                        errorWidget: (_, _, _) => Icon(
                          Icons.movie_outlined,
                          size: 44,
                          color: context.appColors.tertiary,
                        ),
                      ),
              ),
              if (widget.overlay?.bottomLabel case final label?)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    key: const ValueKey('video-card-bottom-label'),
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (widget.overlay?.badgeLabel case final label?)
                Positioned(
                  top: 0,
                  right: 0,
                  child: CustomPaint(
                    key: const ValueKey('video-card-badge'),
                    painter: const _RoundedTrapezoidBadgePainter(),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 62),
                      height: 26,
                      padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
                      alignment: Alignment.center,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.progress != null && widget.progress! > 0)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: LinearProgressIndicator(
                    value: widget.progress!.clamp(0, 1),
                    minHeight: 3,
                    backgroundColor: context.appColors.divider,
                    color: context.appColors.accent,
                  ),
                ),
            ],
          ),
        ),
      ),
      SizedBox(height: 8),
      Text(
        widget.video.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 16,
          height: 1.3,
          fontWeight: FontWeight.w600,
        ),
      ),
      SizedBox(height: 4),
      Text(
        _meta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          height: 1.3,
          color: context.appColors.secondary,
        ),
      ),
    ],
  );

  String get _meta => [
    widget.video.category,
    widget.video.remarks,
  ].where((e) => e.isNotEmpty).join(' · ');
}

class _RoundedTrapezoidBadgePainter extends CustomPainter {
  const _RoundedTrapezoidBadgePainter();

  Path _path(Size size) {
    final width = size.width;
    final height = size.height;
    return Path()
      ..moveTo(12, 0)
      ..lineTo(width - 12, 0)
      // The parent poster clips this arc to the same 12px outer radius, so the
      // badge and poster meet without a gap at the top-right corner.
      ..quadraticBezierTo(width, 0, width, 12)
      ..lineTo(width, height - 6)
      ..quadraticBezierTo(width, height, width - 6, height)
      ..lineTo(12, height)
      ..quadraticBezierTo(0, height, 0, height - 12)
      ..lineTo(0, 6)
      ..quadraticBezierTo(0, 0, 6, 0)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    canvas.drawShadow(path, const Color(0x73000000), 4, true);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.redAccent
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xE0FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _RoundedTrapezoidBadgePainter oldDelegate) =>
      false;
}
