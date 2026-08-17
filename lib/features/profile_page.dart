import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/cache/cache_controller.dart';
import '../data/cache/download_providers.dart';
import '../data/cache/download_task_manager.dart';
import '../data/cache/prefetch_policy.dart';
import '../data/history_repository.dart';
import '../data/library_repository.dart';
import '../data/video_repository.dart';
import '../data/vod_source_registry.dart';
import '../data/vod_source_preferences.dart';
import '../domain/playback_progress.dart';
import '../domain/video.dart';
import '../domain/watch_record.dart';
import '../shared/app_snack_bar.dart';
import '../shared/video_card.dart';
import '../shared/video_grid.dart';
import 'cache_management_page.dart';
import 'detail_page.dart';
import 'download_management_page.dart';
import 'player_page.dart';
import 'source_management_page.dart';

String _cacheBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final precision = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: SafeArea(
      // bottom: false：让收藏/历史网格延伸到底部毛玻璃导航栏下方透出。
      bottom: false,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              color: AppColors.elevated,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.source_outlined),
                    title: const Text('来源管理'),
                    subtitle: Text(
                      ref
                          .watch(selectedVodSourceProvider)
                          .maybeWhen(data: (s) => s.name, orElse: () => '加载中'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: AppColors.tertiary,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SourceManagementPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.divider),
                  Consumer(
                    builder: (context, ref, _) {
                      final stats = ref.watch(cacheControllerProvider);
                      final subtitle = stats.value == null
                          ? '正在统计…'
                          : '已用 ${_cacheBytes(stats.value!.usedBytes)} / 配额 ${_cacheBytes(stats.value!.quotaBytes)} · ${stats.value!.entryCount} 个缓存剧集';
                      return ListTile(
                        leading: const Icon(Icons.cleaning_services_outlined),
                        title: const Text('缓存管理'),
                        subtitle: Text(
                          subtitle,
                          style: const TextStyle(fontSize: 13),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: AppColors.tertiary,
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const CacheManagementPage(),
                          ),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1, color: AppColors.divider),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('下载管理'),
                    subtitle: const Text(
                      '查看下载进度、速度和已完成剧集',
                      style: TextStyle(fontSize: 13),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: AppColors.tertiary,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DownloadManagementPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.divider),
                  Consumer(
                    builder: (context, ref, _) {
                      final mode = ref.watch(prefetchModeProvider).value;
                      final enabled = mode != PrefetchMode.off;
                      return SwitchListTile(
                        secondary: const Icon(Icons.speed_outlined),
                        title: const Text('预加载'),
                        subtitle: Text(
                          enabled
                              ? '播放时提前缓存后续分片（Wi-Fi 30 片 / 蜂窝 5 片）'
                              : '已关闭，播放时只缓存当前观看的分片',
                          style: const TextStyle(fontSize: 13),
                        ),
                        value: enabled,
                        onChanged: (value) => ref
                            .read(prefetchModeProvider.notifier)
                            .setMode(
                              value ? PrefetchMode.auto : PrefetchMode.off,
                            ),
                      );
                    },
                  ),
                ],
              ),
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
                bottomPadding: 96,
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
      final downloadManager = await ref.read(downloadManagerProvider.future);
      final downloadedTask = downloadManager.tasks
          .where(
            (task) =>
                task.status == DownloadTaskStatus.completed &&
                task.sourceId == record.video.sourceId &&
                task.sourceVideoId == record.video.sourceVideoId &&
                (record.episodeIdentity.isNotEmpty
                    ? task.episodeIdentity == record.episodeIdentity
                    : task.episodeId == record.episodeId ||
                          task.episodeName == record.episodeName),
          )
          .firstOrNull;
      if (downloadedTask != null) {
        final selection = await downloadManager.selectionForTask(
          downloadedTask,
        );
        if (selection != null && mounted) {
          Navigator.pop(context);
          dialogOpen = false;
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerPage(
                video: record.video,
                episode: selection.episode,
                selection: selection,
                resumePosition: PlaybackProgress(
                  positionMs: record.positionMs,
                  durationMs: record.durationMs,
                  completed: record.completed,
                ).resumePosition(),
              ),
            ),
          );
          await _load();
          return;
        }
      }
      final source = ref
          .read(vodSourceRegistryProvider)
          .maybeWhen(
            data: (r) => r.findById(record.video.sourceId),
            orElse: () => null,
          );
      if (source == null) throw const VideoDataException('未知来源');
      final detail = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, record.video.ref);
      if (!mounted) return;
      Navigator.pop(context);
      dialogOpen = false;
      if (detail.episodes.isEmpty) {
        throw const VideoDataException('播放地址已失效且无法重新获取');
      }
      // 优先按稳定线路/剧集 identity 定位，再退回默认线路内 name/id，不跨线路。
      Episode episode;
      final line = record.playbackLineIdentity.isEmpty
          ? null
          : detail.playbackLines
                .where((l) => l.identity == record.playbackLineIdentity)
                .toList()
                .firstOrNull;
      final candidates = line?.episodes ?? detail.episodes;
      if (record.episodeIdentity.isNotEmpty) {
        final byIdentity = candidates.where(
          (item) => item.identity == record.episodeIdentity,
        );
        if (byIdentity.isNotEmpty) {
          episode = byIdentity.first;
        } else {
          episode = _fallbackEpisode(candidates, record);
        }
      } else {
        episode = _fallbackEpisode(candidates, record);
      }
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
        showAppSnackBarVia(messenger, e.toString());
      }
    }
  }

  Episode _fallbackEpisode(List<Episode> candidates, WatchRecord record) {
    final matched = candidates.where(
      (item) => item.name == record.episodeName || item.id == record.episodeId,
    );
    return matched.isEmpty ? candidates.first : matched.first;
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            itemCount: records!.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: MediaQuery.sizeOf(context).width >= 700 ? 4 : 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 20,
              childAspectRatio: .49,
            ),
            itemBuilder: (_, i) => _HistoryCard(
              record: records![i],
              onTap: () => _resume(records![i]),
            ),
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
