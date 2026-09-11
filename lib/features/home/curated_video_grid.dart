import 'package:flutter/material.dart';

import 'curated_feed_controller.dart';
import 'curated_video_card.dart';

class CuratedVideoGrid extends StatelessWidget {
  const CuratedVideoGrid({
    super.key,
    required this.slots,
    required this.onTap,
    this.topPadding = 8,
    this.bottomPadding = 24,
    this.controller,
    this.footer,
    this.headerSlivers = const [],
    this.physics,
  });

  final List<CuratedSearchSlot> slots;
  final ValueChanged<CuratedSearchSlot> onTap;
  final double topPadding;
  final double bottomPadding;
  final ScrollController? controller;
  final Widget? footer;
  final List<Widget> headerSlivers;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final crossAxisCount = width >= 700 ? 4 : 2;
    const infoHeight = 56.0;
    final cardWidth = (width - 32 - 12 * (crossAxisCount - 1)) / crossAxisCount;
    return CustomScrollView(
      key: const ValueKey('curated-video-grid'),
      controller: controller,
      physics: physics,
      slivers: [
        ...headerSlivers,
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            topPadding,
            16,
            footer == null ? bottomPadding : 0,
          ),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (context, index) => CuratedVideoCard(
                slot: slots[index],
                onTap: () => onTap(slots[index]),
              ),
              childCount: slots.length,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 12,
              mainAxisSpacing: 24,
              childAspectRatio: cardWidth / (cardWidth * 5 / 4 + infoHeight),
            ),
          ),
        ),
        if (footer != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPadding),
              child: footer,
            ),
          ),
      ],
    );
  }
}
