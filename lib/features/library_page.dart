import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/library_repository.dart';
import '../domain/library.dart';
import '../domain/video.dart';
import '../shared/video_grid.dart';
import 'detail_page.dart';

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
            child: Text(
              '我的收藏',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: '收藏'),
              Tab(text: '播放列表'),
            ],
          ),
          const Expanded(
            child: TabBarView(children: [_FavoritesTab(), _PlaylistsTab()]),
          ),
        ],
      ),
    ),
  );
}

class _FavoritesTab extends ConsumerWidget {
  const _FavoritesTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(favoriteControllerProvider)
      .when(
        loading: () => const AppLoadingView(),
        error: (error, _) => AppErrorView(
          message: '收藏加载失败',
          onRetry: () => ref.invalidate(favoriteControllerProvider),
        ),
        data: (records) => records.isEmpty
            ? const AppEmptyView(
                icon: Icons.favorite_outline,
                message: '还没有收藏\n去首页或搜索页收藏喜欢的视频',
              )
            : VideoGrid(
                videos: records.map((record) => record.video).toList(),
                onTap: (video) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => VideoDetailPage(video: video),
                  ),
                ),
              ),
      );
}

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(playlistControllerProvider)
      .when(
        loading: () => const AppLoadingView(),
        error: (error, _) => AppErrorView(
          message: '播放列表加载失败',
          onRetry: () => ref.invalidate(playlistControllerProvider),
        ),
        data: (playlists) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton.icon(
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('新建播放列表'),
            ),
            const SizedBox(height: 12),
            if (playlists.isEmpty)
              const SizedBox(
                height: 280,
                child: AppEmptyView(
                  icon: Icons.playlist_play,
                  message: '还没有播放列表',
                ),
              ),
            ...playlists.map(
              (playlist) => Card(
                child: ListTile(
                  leading: _Cover(video: playlist.videos.firstOrNull),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.videos.length} 个视频'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PlaylistDetailPage(playlistId: playlist.id),
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, ref, playlist),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await askPlaylistName(context);
    if (name != null) {
      await ref.read(playlistControllerProvider.notifier).create(name);
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    VideoPlaylist playlist,
  ) async {
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除播放列表？'),
            content: Text('“${playlist.name}”中的视频不会被删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (accepted) {
      await ref.read(playlistControllerProvider.notifier).delete(playlist.id);
    }
  }
}

class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});
  final String playlistId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref
        .watch(playlistControllerProvider)
        .value
        ?.where((item) => item.id == playlistId)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(playlist?.name ?? '播放列表')),
      body: playlist == null
          ? const AppLoadingView()
          : playlist.videos.isEmpty
          ? const AppEmptyView(
              icon: Icons.playlist_remove,
              message: '播放列表中还没有视频',
            )
          : Column(
              children: [
                Expanded(
                  child: VideoGrid(
                    videos: playlist.videos,
                    onTap: (video) => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VideoDetailPage(video: video),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: playlist.videos
                        .map(
                          (video) => TextButton.icon(
                            onPressed: () => ref
                                .read(playlistControllerProvider.notifier)
                                .remove(playlist.id, video.id),
                            icon: const Icon(Icons.remove_circle_outline),
                            label: Text('移除 ${video.title}'),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({this.video});
  final Video? video;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    height: 64,
    child: video == null || video!.posterUrl.isEmpty
        ? const Icon(Icons.playlist_play)
        : CachedNetworkImage(
            imageUrl: video!.posterUrl,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => const Icon(Icons.playlist_play),
          ),
  );
}

Future<String?> askPlaylistName(BuildContext context) async {
  final controller = TextEditingController();
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('新建播放列表'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(labelText: '名称', errorText: error),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) {
                setState(() => error = '名称不能为空');
              } else {
                Navigator.pop(dialogContext, name);
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result;
}

Future<void> showPlaylistPicker(
  BuildContext context,
  WidgetRef ref,
  Video video,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final playlists = await ref.read(playlistControllerProvider.future);
  if (!context.mounted) return;
  final selected = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text(
              '加入播放列表',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('新建播放列表'),
            onTap: () => Navigator.pop(sheetContext, '__new__'),
          ),
          ...playlists.map(
            (item) => ListTile(
              leading: const Icon(Icons.playlist_play),
              title: Text(item.name),
              subtitle: Text('${item.videos.length} 个视频'),
              trailing: item.videos.any((v) => v.id == video.id)
                  ? const Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(sheetContext, item.id),
            ),
          ),
        ],
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  try {
    var id = selected;
    if (id == '__new__') {
      final name = await askPlaylistName(context);
      if (name == null || !context.mounted) return;
      id =
          (await ref.read(playlistControllerProvider.notifier).create(name)).id;
    }
    await ref.read(playlistControllerProvider.notifier).add(id, video);
    messenger.showSnackBar(const SnackBar(content: Text('已加入播放列表')));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('播放列表保存失败，请重试')));
  }
}
