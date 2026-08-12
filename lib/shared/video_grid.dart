import 'package:flutter/material.dart';
import '../domain/video.dart';
import 'video_card.dart';

class VideoGrid extends StatelessWidget {
  const VideoGrid({
    super.key,
    required this.videos,
    required this.onTap,
    this.bottomPadding = 24,
  });
  final List<Video> videos;
  final ValueChanged<Video> onTap;
  final double bottomPadding;
  @override
  Widget build(BuildContext context) => GridView.builder(
    padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: MediaQuery.sizeOf(context).width >= 700 ? 4 : 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 20,
      childAspectRatio: .52,
    ),
    itemCount: videos.length,
    itemBuilder: (_, index) =>
        VideoCard(video: videos[index], onTap: () => onTap(videos[index])),
  );
}
