import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/download/download_providers.dart';
import '../../data/download/download_task_manager.dart';
import '../../data/history_repository.dart';
import '../../data/library_repository.dart';
import '../../data/vod_source/vod_source_preferences.dart';
import '../../domain/watch_record.dart';
import '../../shared/video_card.dart';
import '../../shared/video_grid.dart';
import '../detail/detail_page.dart';
import '../download/download_management_page.dart';
import '../settings/more_settings_page.dart';
import '../player/resume_watch.dart';
import '../settings/source_management_page.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = MediaQuery.sizeOf(context).width > 600;
    return DefaultTabController(
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _QuickActions(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: expanded ? 360 : double.infinity,
                ),
                child: const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: EdgeInsets.only(left: 16),
                  labelColor: AppColors.text,
                  unselectedLabelColor: AppColors.tertiary,
                  labelStyle: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: TextStyle(fontSize: 15),
                  labelPadding: EdgeInsets.only(right: 28),
                  indicatorColor: AppColors.accent,
                  indicatorSize: TabBarIndicatorSize.label,
                  indicatorWeight: 3,
                  dividerColor: Colors.transparent,
                  tabs: [
                    Tab(text: '收藏'),
                    Tab(text: '最近观看'),
                  ],
                ),
              ),
            ),
            const Expanded(
              child: TabBarView(children: [_FavoritesTab(), _HistoryTab()]),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 360;
    final expanded = width > 600;
    final tasks = ref.watch(downloadTasksProvider);
    final source = ref.watch(selectedVodSourceProvider);
    final downloadSubtitle = tasks.maybeWhen(
      data: (items) =>
          _downloadSubtitle(items, compact: compact, expanded: expanded),
      orElse: () => '加载中',
    );
    final sourceSubtitle = source.when(
      data: (item) => item.name,
      loading: () => '加载中',
      error: (_, _) => '来源异常',
    );
    return Align(
      alignment: expanded ? Alignment.centerLeft : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: expanded ? 720 : double.infinity),
        child: Row(
          children: [
            Expanded(
              child: _QuickActionCard(
                icon: Icons.download_outlined,
                title: expanded ? '离线下载' : '下载',
                subtitle: downloadSubtitle,
                compact: compact,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DownloadManagementPage(),
                  ),
                ),
              ),
            ),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: _QuickActionCard(
                icon: Icons.source_outlined,
                title: '播放源',
                subtitle: sourceSubtitle,
                compact: compact,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SourceManagementPage(),
                  ),
                ),
              ),
            ),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: _QuickActionCard(
                icon: Icons.settings_outlined,
                title: expanded ? '更多设置' : '更多',
                subtitle: expanded ? '播放与存储' : '播放设置',
                compact: compact,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MoreSettingsPage()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _downloadSubtitle(
    List<DownloadTask> tasks, {
    required bool compact,
    required bool expanded,
  }) {
    final active = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.queued ||
              task.status == DownloadTaskStatus.downloading,
        )
        .toList();
    final completed = tasks
        .where((task) => task.status == DownloadTaskStatus.completed)
        .length;
    if (active.isNotEmpty) {
      if (compact) return '${active.length}个进行中';
      final progress = _overallProgress(active);
      return progress == null
          ? '${active.length} 个下载中'
          : '${active.length} 个下载中 · $progress%';
    }
    if (completed > 0) return '已下载 $completed 部';
    return expanded ? '暂无下载' : '无下载';
  }

  int? _overallProgress(List<DownloadTask> active) {
    final measurable = active.where((task) => task.progress > 0).toList();
    if (measurable.isEmpty) return null;
    final total = measurable.fold<double>(
      0,
      (sum, task) => sum + task.progress,
    );
    return (total / measurable.length * 100).round();
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.compact,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: compact ? 56 : 60,
    child: Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.divider.withValues(alpha: 0.8)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
          child: Row(
            children: [
              Icon(icon, size: compact ? 18 : 20, color: AppColors.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 12 : 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 10 : 11,
                        color: AppColors.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('此操作只会清除本机记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await ref.read(watchHistoryProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(watchHistoryProvider)
        .when(
          loading: () => const AppLoadingView(),
          error: (error, _) => AppErrorView(
            message: '$error',
            onRetry: () => ref.invalidate(watchHistoryProvider),
          ),
          data: (records) {
            if (records.isEmpty) {
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
                    child: TextButton(
                      onPressed: () => _clear(context, ref),
                      child: const Text('清空'),
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = constraints.maxWidth >= 700
                          ? 4
                          : 2;
                      const horizontalPadding = 32.0;
                      const crossAxisSpacing = 12.0;
                      // 海报为 4:5；其下为 VideoCard 信息区约 52，观看进度行约 20。
                      // 按实际卡宽计算单元格高度，避免固定比例把两段信息撑开。
                      const infoHeight = 72.0;
                      final cardWidth =
                          (constraints.maxWidth -
                              horizontalPadding -
                              crossAxisSpacing * (crossAxisCount - 1)) /
                          crossAxisCount;
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                        itemCount: records.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: crossAxisSpacing,
                          mainAxisSpacing: 20,
                          childAspectRatio:
                              cardWidth / (cardWidth * 5 / 4 + infoHeight),
                        ),
                        itemBuilder: (_, index) => _HistoryCard(
                          record: records[index],
                          onTap: () => resumeWatchRecord(
                            context: context,
                            ref: ref,
                            record: records[index],
                          ),
                          onDelete: () => deleteWatchRecord(
                            context: context,
                            ref: ref,
                            record: records[index],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });
  final WatchRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Stack(
          children: [
            VideoCard(
              video: record.video,
              progress: record.progress,
              onTap: onTap,
              onLongPress: onDelete,
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: AppColors.scrim,
                shape: const CircleBorder(),
                child: InkWell(
                  key: ValueKey('history-delete-${record.video.globalId}'),
                  customBorder: const CircleBorder(),
                  onTap: onDelete,
                  child: const SizedBox.square(
                    dimension: 28,
                    child: Icon(Icons.close, size: 16, color: AppColors.text),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Text(
        record.resumeLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.secondary, fontSize: 12),
      ),
    ],
  );
}
