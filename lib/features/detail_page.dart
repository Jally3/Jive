import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../data/library_repository.dart';
import '../domain/video.dart';
import 'player_page.dart';
import 'library_page.dart';

class VideoDetailPage extends ConsumerStatefulWidget {
  const VideoDetailPage({super.key, required this.video});
  final Video video;
  @override
  ConsumerState<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> {
  Video? detail;
  String? error;
  bool loading = true, resolving = false, expanded = false;
  int selected = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await ref
          .read(videoRepositoryProvider)
          .fetchDetail(widget.video.id);
      if (mounted) setState(() => detail = value);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _play({int? episodeIndex}) async {
    if (resolving) return;
    setState(() {
      resolving = true;
      if (episodeIndex != null) selected = episodeIndex;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(widget.video.id);
      await ref
          .read(favoriteControllerProvider.notifier)
          .refreshSnapshot(fresh);
      if (fresh.episodes.isEmpty) {
        throw const VideoDataException('该视频暂时没有可用播放地址');
      }
      final priorName = detail != null && detail!.episodes.length > selected
          ? detail!.episodes[selected].name
          : '';
      final index = fresh.episodes.indexWhere((item) => item.name == priorName);
      final chosen =
          fresh.episodes[index >= 0
              ? index
              : selected.clamp(0, fresh.episodes.length - 1)];
      if (!mounted) return;
      setState(() => detail = fresh);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerPage(video: fresh, episode: chosen),
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('视频详情')),
    body: loading
        ? const AppLoadingView(label: '正在加载详情…')
        : error != null
        ? AppErrorView(message: error!, onRetry: _load)
        : _content(detail!),
  );

  Widget _content(Video video) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 128,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ColoredBox(
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
                          errorWidget: (_, _, _) => const Icon(
                            Icons.movie_outlined,
                            color: AppColors.tertiary,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  style: const TextStyle(
                    fontSize: 22,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                _Meta(
                  icon: Icons.category_outlined,
                  text: video.category.isEmpty ? '类型未知' : video.category,
                ),
                if (video.remarks.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _Meta(icon: Icons.update, text: video.remarks),
                ],
                if (video.updatedAt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _Meta(icon: Icons.schedule, text: video.updatedAt),
                ],
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      SizedBox(
        height: 48,
        child: FilledButton.icon(
          onPressed: video.episodes.isEmpty || resolving ? null : _play,
          icon: resolving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(
            video.episodes.isEmpty
                ? '暂无可播放剧集'
                : '播放 ${video.episodes[selected].name}',
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Consumer(
              builder: (context, ref, _) {
                final favorites = ref.watch(favoriteControllerProvider);
                final favorite =
                    favorites.value?.any((item) => item.video.id == video.id) ??
                    false;
                return OutlinedButton.icon(
                  onPressed: favorites.isLoading
                      ? null
                      : () async {
                          try {
                            await ref
                                .read(favoriteControllerProvider.notifier)
                                .toggle(video);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(favorite ? '已取消收藏' : '已收藏'),
                                ),
                              );
                            }
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('收藏保存失败，请重试')),
                              );
                            }
                          }
                        },
                  icon: Icon(
                    favorite ? Icons.favorite : Icons.favorite_outline,
                  ),
                  label: Text(favorite ? '取消收藏' : '收藏'),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Consumer(
              builder: (context, ref, _) => OutlinedButton.icon(
                onPressed: () => showPlaylistPicker(context, ref, video),
                icon: const Icon(Icons.playlist_add),
                label: const Text('加入播放列表'),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const Text(
        '简介',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        video.description.isEmpty ? '暂无简介' : video.description,
        maxLines: expanded ? null : 4,
        overflow: expanded ? null : TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 15,
          height: 1.55,
        ),
      ),
      if (video.description.length > 100)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => expanded = !expanded),
            child: Text(expanded ? '收起' : '展开'),
          ),
        ),
      const SizedBox(height: 16),
      Row(
        children: [
          const Expanded(
            child: Text(
              '剧集',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '${video.episodes.length} 集',
            style: const TextStyle(color: AppColors.secondary),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (video.episodes.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: AppEmptyView(message: '暂时没有可用剧集'),
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(
            video.episodes.length,
            (index) => ChoiceChip(
              label: Text(video.episodes[index].name),
              selected: selected == index,
              onSelected: (_) {
                setState(() => selected = index);
                _play(episodeIndex: index);
              },
            ),
          ),
        ),
    ],
  );
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: AppColors.tertiary),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.secondary, fontSize: 13),
        ),
      ),
    ],
  );
}
