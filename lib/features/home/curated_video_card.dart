import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/tmdb_catalog.dart';
import 'curated_feed_controller.dart';

class CuratedVideoCard extends StatefulWidget {
  const CuratedVideoCard({super.key, required this.slot, required this.onTap});

  final CuratedSearchSlot slot;
  final VoidCallback onTap;

  @override
  State<CuratedVideoCard> createState() => _CuratedVideoCardState();
}

class _CuratedVideoCardState extends State<CuratedVideoCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (value) => setState(() => _focused = value),
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onTap();
          return null;
        },
      ),
    },
    child: Semantics(
      button: true,
      label:
          '${widget.slot.catalogItem.localizedTitle}，${_statusLabel(widget.slot)}',
      child: Container(
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
          key: ValueKey('curated-${widget.slot.slotId}'),
          borderRadius: BorderRadius.circular(12),
          canRequestFocus: false,
          onTap: widget.onTap,
          child: _content(context),
        ),
      ),
    ),
  );

  Widget _content(BuildContext context) {
    final slot = widget.slot;
    final item = slot.catalogItem;
    final poster = item.posterUrl.isNotEmpty
        ? item.posterUrl
        : slot.matchedVideo?.posterUrl ?? '';
    return Column(
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
                  child: poster.isEmpty
                      ? Icon(
                          Icons.movie_outlined,
                          size: 44,
                          color: context.appColors.tertiary,
                        )
                      : CachedNetworkImage(
                          imageUrl: poster,
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
                Positioned(
                  left: 8,
                  top: 8,
                  child: _Badge(label: '#${item.rank}'),
                ),
                if (item.rating > 0)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: _Badge(label: item.rating.toStringAsFixed(1)),
                  ),
                if (slot.status != CuratedSlotStatus.available)
                  Positioned(
                    left: 7,
                    right: 7,
                    bottom: 7,
                    child: _StatusPill(slot: slot),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          item.localizedTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          [
            item.mediaType == TmdbMediaType.movie ? '电影' : '剧集',
            if (item.releaseDate.length >= 4) item.releaseDate.substring(0, 4),
            slot.sourceName,
          ].join(' · '),
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
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.slot});
  final CuratedSearchSlot slot;

  @override
  Widget build(BuildContext context) {
    final busy =
        slot.status == CuratedSlotStatus.queued ||
        slot.status == CuratedSlotStatus.searching;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy) ...[
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                _statusLabel(slot),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(CuratedSearchSlot slot) => switch (slot.status) {
  CuratedSlotStatus.queued => '等待搜索',
  CuratedSlotStatus.searching => '正在 ${slot.sourceName} 搜索',
  CuratedSlotStatus.available => '${slot.sourceName} 可播放',
  CuratedSlotStatus.unavailable => '${slot.sourceName} 暂无',
  CuratedSlotStatus.ambiguous => '多个候选，点击确认',
  CuratedSlotStatus.duplicate => '资源重复，点击换源',
  CuratedSlotStatus.failed => '搜索失败，点击重试',
};

class _Badge extends StatelessWidget {
  const _Badge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}
