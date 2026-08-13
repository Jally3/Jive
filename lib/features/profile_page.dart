import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/history_repository.dart';
import '../data/library_repository.dart';
import '../data/video_repository.dart';
import '../domain/playback_progress.dart';
import '../domain/watch_record.dart';
import '../shared/video_card.dart';
import '../shared/video_grid.dart';
import 'detail_page.dart';
import 'player_page.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
            child: Text(
              '我的',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
          const TabBar(
            tabs: [
              Tab(text: '收藏'),
              Tab(text: '最近观看'),
            ],
          ),
          const Expanded(
            child: TabBarView(children: [_FavoritesTab(), _HistoryTab()]),
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

class _HistoryTab extends ConsumerStatefulWidget {
  const _HistoryTab();
  @override
  ConsumerState<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<_HistoryTab> {
  List<WatchRecord>? records;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await ref.read(historyRepositoryProvider).load();
      if (mounted) {
        setState(() {
          records = value;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _clear() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('此操作只会清除本机记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await ref.read(historyRepositoryProvider).clear();
      await _load();
    }
  }

  Future<void> _resume(WatchRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final detail = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(record.video.id);
      if (!mounted) return;
      Navigator.pop(context);
      dialogOpen = false;
      if (detail.episodes.isEmpty) {
        throw const VideoDataException('播放地址已失效且无法重新获取');
      }
      final matched = detail.episodes.where(
        (item) =>
            item.name == record.episodeName || item.id == record.episodeId,
      );
      final episode = matched.isEmpty ? detail.episodes.first : matched.first;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            video: detail,
            episode: episode,
            resumePosition: PlaybackProgress(
              positionMs: record.positionMs,
              durationMs: record.durationMs,
              completed: record.completed,
            ).resumePosition(),
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (mounted && dialogOpen && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return AppErrorView(message: error!, onRetry: _load);
    if (records == null) return const AppLoadingView();
    if (records!.isEmpty) {
      return const AppEmptyView(
        icon: Icons.history,
        message: '还没有观看记录\n播放视频后可以从这里继续',
      );
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(onPressed: _clear, child: const Text('清空')),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: records!.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: MediaQuery.sizeOf(context).width >= 700 ? 4 : 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 20,
              childAspectRatio: .49,
            ),
            itemBuilder: (_, i) =>
                _HistoryCard(record: records![i], onTap: () => _resume(records![i])),
          ),
        ),
      ],
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.record, required this.onTap});
  final WatchRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: VideoCard(
          video: record.video,
          progress: record.progress,
          onTap: onTap,
        ),
      ),
      Text(
        record.completed
            ? '${record.episodeName} · 已播完'
            : '继续 ${record.episodeName} · ${_duration(record.positionMs)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.secondary, fontSize: 12),
      ),
    ],
  );

  String _duration(int ms) {
    final d = Duration(milliseconds: ms);
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}
