import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../domain/video.dart';

class VideoCard extends StatefulWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onLongPress,
    this.progress,
  });
  final Video video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double? progress;

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
      label: '查看 ${widget.video.title}',
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
                        placeholder: (_, _) => _posterPlaceholder(),
                        errorWidget: (_, _, _) => _posterFallback(),
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
              if (widget.video.rank != null && widget.video.rank! > 0)
                Positioned(
                  left: 8,
                  top: 8,
                  child: _PosterBadge(label: '#${widget.video.rank}'),
                ),
              if (widget.video.rating != null && widget.video.rating! > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: _PosterBadge(
                    label: widget.video.rating!.toStringAsFixed(1),
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

  Widget _posterPlaceholder() => ColoredBox(color: context.appColors.surface);

  Widget _posterFallback() {
    final backup = widget.video.backupPosterUrl;
    if (backup.isEmpty || backup == widget.video.posterUrl) {
      return _posterErrorIcon();
    }
    return CachedNetworkImage(
      imageUrl: backup,
      fit: BoxFit.cover,
      placeholder: (_, _) => _posterPlaceholder(),
      errorWidget: (_, _, _) => _posterErrorIcon(),
    );
  }

  Widget _posterErrorIcon() =>
      Icon(Icons.movie_outlined, size: 44, color: context.appColors.tertiary);
}

class _PosterBadge extends StatelessWidget {
  const _PosterBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
