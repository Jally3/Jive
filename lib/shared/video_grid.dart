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
  });
  final List<Video> videos;
  final ValueChanged<Video> onTap;
  final double topPadding;
  final double bottomPadding;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final crossAxisCount = width >= 700 ? 4 : 2;
    // 卡片信息区固定高度：海报→标题 8 + 标题(16×1.3) + 间距 4 + meta(12×1.3) ≈ 48.4。
    // 海报 4:5，按实际卡宽动态算比例，避免固定比例在窄屏溢出、宽屏留白。
    const infoHeight = 52.0;
    final cardWidth = (width - 32 - 12 * (crossAxisCount - 1)) / crossAxisCount;
    return GridView.builder(
      controller: controller,
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 12,
        mainAxisSpacing: 24,
        childAspectRatio: cardWidth / (cardWidth * 5 / 4 + infoHeight),
      ),
      itemCount: videos.length,
      itemBuilder: (_, index) =>
          VideoCard(video: videos[index], onTap: () => onTap(videos[index])),
    );
  }
}
