import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../domain/video.dart';

class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.progress,
  });
  final Video video;
  final VoidCallback onTap;
  final double? progress;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '查看 ${video.title}',
    child: InkWell(
      key: ValueKey('video-${video.globalId}'),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: AppColors.elevated,
                    child: video.posterUrl.isEmpty
                        ? const Icon(
                            Icons.movie_outlined,
                            size: 44,
                            color: AppColors.tertiary,
                          )
                        : CachedNetworkImage(
                            imageUrl: video.posterUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, _) =>
                                const ColoredBox(color: AppColors.surface),
                            errorWidget: (_, _, _) => const Icon(
                              Icons.movie_outlined,
                              size: 44,
                              color: AppColors.tertiary,
                            ),
                          ),
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: AppColors.onAccent,
                        ),
                      ),
                    ),
                  ),
                  if (progress != null && progress! > 0)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: LinearProgressIndicator(
                        value: progress!.clamp(0, 1),
                        minHeight: 3,
                        backgroundColor: AppColors.divider,
                        color: AppColors.accent,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              height: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.secondary),
          ),
        ],
      ),
    ),
  );

  String get _meta =>
      [video.category, video.remarks].where((e) => e.isNotEmpty).join(' · ');
}
