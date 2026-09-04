import 'package:flutter/material.dart';
import '../domain/video.dart';
import 'video_card.dart';

class VideoGrid extends StatelessWidget {
  const VideoGrid({
    super.key,
    required this.videos,
    required this.onTap,
    this.topPadding = 8,
    this.bottomPadding = 24,
    this.controller,
    this.footer,
    this.headerSlivers = const [],
    this.physics,
  });
  final List<Video> videos;
  final ValueChanged<Video> onTap;
  final double topPadding;
  final double bottomPadding;
  final ScrollController? controller;
  final Widget? footer;
  final List<Widget> headerSlivers;
  final ScrollPhysics? physics;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // TV 左侧导航会收窄内容区，必须使用网格自身约束而非全屏宽度。
      final width = constraints.maxWidth;
      final crossAxisCount = width >= 700 ? 4 : 2;
      // 卡片信息区固定高度：海报→标题 8 + 标题(16×1.3) + 间距 4 + meta(12×1.3) ≈ 48.4。
      // CJK 回退字体行高略大于理论值（实测溢出 1.2px），预留约 4px 余量。
      // 海报 4:5，按实际卡宽动态算比例，避免固定比例在窄屏溢出、宽屏留白。
      const infoHeight = 56.0;
      final cardWidth =
          (width - 32 - 12 * (crossAxisCount - 1)) / crossAxisCount;
      return CustomScrollView(
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
                (context, index) => VideoCard(
                  video: videos[index],
                  onTap: () => onTap(videos[index]),
                ),
                childCount: videos.length,
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
    },
  );
}
