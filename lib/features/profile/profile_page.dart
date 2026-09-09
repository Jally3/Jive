import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/download/download_providers.dart';
import '../../data/download/download_task_manager.dart';
import '../../data/history_repository.dart';
import '../../data/library_repository.dart';
import '../../data/vod_source/vod_source_preferences.dart';
import '../../domain/library.dart';
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
    final unreadFollowCount = ref.watch(unreadFollowUpdateCountProvider);
    return DefaultTabController(
      length: 3,
      child: SafeArea(
        // bottom: false：让收藏/历史网格延伸到底部毛玻璃导航栏下方透出。
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
              child: Text(
                '我的',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _QuickActions(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: expanded ? 360 : double.infinity,
                ),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: EdgeInsets.only(left: 16),
                  labelColor: context.appColors.text,
                  unselectedLabelColor: context.appColors.tertiary,
                  labelStyle: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: TextStyle(fontSize: 15),
                  labelPadding: EdgeInsets.only(right: 28),
                  indicatorColor: context.appColors.accentForeground,
                  indicatorSize: TabBarIndicatorSize.label,
                  indicatorWeight: 3,
                  dividerColor: Colors.transparent,
                  tabs: [
                    Tab(
                      child: _TabLabelWithBadge(
                        label: '追更',
                        badgeCount: unreadFollowCount,
                      ),
                    ),
                    Tab(text: '收藏'),
                    Tab(text: '最近观看'),
                  ],
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _LibraryTab(mode: _LibraryMode.following),
                  _LibraryTab(mode: _LibraryMode.favorite),
                  _HistoryTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabLabelWithBadge extends StatelessWidget {
  const _TabLabelWithBadge({required this.label, required this.badgeCount});

  final String label;
  final int badgeCount;

  @override
  Widget build(BuildContext context) => Semantics(
    label: badgeCount > 0 ? '$label，$badgeCount 部内容有更新' : label,
    excludeSemantics: true,
    child: Padding(
      padding: EdgeInsets.only(right: badgeCount > 0 ? 10 : 0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Text(label),
          if (badgeCount > 0)
            Positioned(
              right: -16,
              top: -7,
              child: Container(
                key: const ValueKey('follow-tab-update-badge'),
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
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
                leading: _DownloadStatusIcon(
                  tasks: tasks.value ?? const <DownloadTask>[],
                ),
                title: expanded ? '离线下载' : '下载',
                subtitle: downloadSubtitle,
                compact: compact,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => DownloadManagementPage()),
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
                  MaterialPageRoute(builder: (_) => SourceManagementPage()),
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
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => MoreSettingsPage())),
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
    final paused = tasks
        .where((task) => task.status == DownloadTaskStatus.paused)
        .length;
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
    if (paused > 0) {
      return compact ? '$paused个已暂停' : '$paused 个下载已暂停';
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
    this.leading,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool compact;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: compact ? 56 : 60,
    child: Material(
      color: context.appColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: context.appColors.divider.withValues(alpha: 0.8),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
          child: Row(
            children: [
              leading ??
                  Icon(
                    icon,
                    size: compact ? 18 : 20,
                    color: context.appColors.secondary,
                  ),
              SizedBox(width: 8),
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
                    SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 10 : 11,
                        color: context.appColors.tertiary,
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

class _DownloadStatusIcon extends StatefulWidget {
  const _DownloadStatusIcon({required this.tasks});

  final List<DownloadTask> tasks;

  @override
  State<_DownloadStatusIcon> createState() => _DownloadStatusIconState();
}

class _DownloadStatusIconState extends State<_DownloadStatusIcon>
    with TickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  late final AnimationController _completion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  int _previousActive = 0;
  int _previousCompleted = 0;

  @override
  void initState() {
    super.initState();
    _previousActive = _activeCount(widget.tasks);
    _previousCompleted = _completedCount(widget.tasks);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop();
  }

  @override
  void didUpdateWidget(covariant _DownloadStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = _activeCount(widget.tasks);
    final completed = _completedCount(widget.tasks);
    if (_previousActive > active && completed > _previousCompleted) {
      _completion.forward(from: 0);
    }
    _previousActive = active;
    _previousCompleted = completed;
    _syncLoop();
  }

  void _syncLoop() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shouldAnimate =
        !reduceMotion &&
        widget.tasks.any(
          (item) =>
              item.status == DownloadTaskStatus.queued ||
              item.status == DownloadTaskStatus.downloading,
        );
    if (shouldAnimate && !_loop.isAnimating) {
      _loop.repeat();
    } else if (!shouldAnimate) {
      _loop.stop();
      _loop.value = 0;
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    _completion.dispose();
    super.dispose();
  }

  static int _activeCount(List<DownloadTask> tasks) => tasks
      .where(
        (item) =>
            item.status == DownloadTaskStatus.queued ||
            item.status == DownloadTaskStatus.downloading,
      )
      .length;

  static int _completedCount(List<DownloadTask> tasks) =>
      tasks.where((item) => item.status == DownloadTaskStatus.completed).length;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final downloading = widget.tasks
        .where((item) => item.status == DownloadTaskStatus.downloading)
        .toList();
    final hasQueued = widget.tasks.any(
      (item) => item.status == DownloadTaskStatus.queued,
    );
    final hasPaused = widget.tasks.any(
      (item) => item.status == DownloadTaskStatus.paused,
    );
    final hasFailed = widget.tasks.any(
      (item) => item.status == DownloadTaskStatus.failed,
    );
    final hasCompleted = widget.tasks.any(
      (item) => item.status == DownloadTaskStatus.completed,
    );
    final progress = downloading.isEmpty
        ? 0.0
        : downloading.fold<double>(0, (sum, item) => sum + item.progress) /
              downloading.length;

    return SizedBox.square(
      dimension: 24,
      child: AnimatedBuilder(
        animation: Listenable.merge([_loop, _completion]),
        builder: (context, _) {
          final completing = _completion.isAnimating;
          final loopValue = _loop.value;
          final fall = reduceMotion || downloading.isEmpty
              ? 0.0
              : -11 + Curves.easeIn.transform(loopValue) * 22;
          final fallingOpacity = reduceMotion || downloading.isEmpty
              ? 1.0
              : loopValue < 0.15
              ? loopValue / 0.15
              : loopValue < 0.75
              ? 1.0
              : (1 - loopValue) / 0.25;
          final queuedOpacity = reduceMotion || !hasQueued
              ? 1.0
              : 0.72 + (0.28 * (1 - (loopValue * 2 - 1).abs()));
          final completionScale = completing
              ? 1 + 0.18 * Curves.easeOutBack.transform(_completion.value)
              : 1.0;
          final icon = completing
              ? Icons.check
              : hasPaused && downloading.isEmpty && !hasQueued
              ? Icons.play_arrow_rounded
              : hasFailed && downloading.isEmpty
              ? Icons.download_outlined
              : hasCompleted && downloading.isEmpty && !hasQueued
              ? Icons.download_done_outlined
              : Icons.arrow_downward;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (downloading.isNotEmpty)
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: progress.clamp(0, 1)),
                    duration: const Duration(milliseconds: 250),
                    builder: (_, value, __) => CircularProgressIndicator(
                      value: value,
                      strokeWidth: 2,
                      color: context.appColors.accentForeground,
                      backgroundColor: context.appColors.divider,
                    ),
                  ),
                ),
              Center(
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: 19,
                    child: Center(
                      child: Transform.translate(
                        key: const ValueKey('profile-download-falling-icon'),
                        offset: Offset(0, fall),
                        child: Transform.scale(
                          scale: completionScale,
                          child: Opacity(
                            opacity: downloading.isNotEmpty
                                ? fallingOpacity
                                : queuedOpacity,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: animation,
                                      child: child,
                                    ),
                                  ),
                              child: Icon(
                                widget.tasks.isEmpty
                                    ? Icons.download_outlined
                                    : icon,
                                key: ValueKey(icon),
                                size: 17,
                                color: context.appColors.secondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (hasFailed)
                const Positioned(
                  right: -1,
                  top: -1,
                  child: Icon(Icons.error, size: 9, color: Colors.redAccent),
                ),
            ],
          );
        },
      ),
    );
  }
}

enum _LibraryMode { following, favorite }

class _LibraryTab extends ConsumerWidget {
  const _LibraryTab({required this.mode});

  final _LibraryMode mode;

  bool get _isFollowing => mode == _LibraryMode.following;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(favoriteControllerProvider)
      .when(
        loading: () => AppLoadingView(),
        error: (error, _) => AppErrorView(
          message: '${_isFollowing ? '追更' : '收藏'}加载失败',
          onRetry: () => ref.invalidate(favoriteControllerProvider),
        ),
        data: (records) {
          final visible = records
              .where(
                (record) => _isFollowing
                    ? record.isFollowing
                    : record.isFavorite && !record.isFollowing,
              )
              .toList();
          return visible.isEmpty
              ? AppEmptyView(
                  icon: _isFollowing
                      ? Icons.notifications_none
                      : Icons.favorite_outline,
                  message: _isFollowing
                      ? '还没有追更内容\n可在剧集详情页开启追更'
                      : '还没有收藏内容\n可在详情页收藏喜欢的视频',
                )
              : _libraryGrid(context, ref, visible);
        },
      );

  Widget _libraryGrid(
    BuildContext context,
    WidgetRef ref,
    List<FavoriteRecord> records,
  ) {
    final sorted = [...records]
      ..sort((a, b) {
        if (_isFollowing) {
          final unread =
              (b.hasUnreadUpdate ? 1 : 0) - (a.hasUnreadUpdate ? 1 : 0);
          if (unread != 0) return unread;
        }
        return b.updatedAt.compareTo(a.updatedAt);
      });
    final videos = [
      for (final record in sorted)
        record.video.copyWith(remarks: _followSummary(record)),
    ];
    final recordsById = {
      for (final record in sorted) record.video.globalId: record,
    };
    final unreadCount = sorted.where((item) => item.hasUnreadUpdate).length;
    final grid = VideoGrid(
      videos: videos,
      bottomPadding: 96,
      overlayBuilder: _isFollowing
          ? (video) => _followOverlay(recordsById[video.globalId])
          : null,
      headerSlivers: _isFollowing
          ? [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          unreadCount > 0 ? '$unreadCount 部内容有更新' : '下拉可检查追更更新',
                          style: TextStyle(color: context.appColors.secondary),
                        ),
                      ),
                      if (unreadCount > 0)
                        TextButton(
                          onPressed: () => ref
                              .read(favoriteControllerProvider.notifier)
                              .markAllViewed(),
                          child: const Text('全部标为已读'),
                        ),
                    ],
                  ),
                ),
              ),
            ]
          : const [],
      onTap: (video) async {
        if (_isFollowing) {
          await ref
              .read(favoriteControllerProvider.notifier)
              .markViewed(video.globalId);
        }
        if (!context.mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)),
        );
      },
    );
    if (!_isFollowing) return grid;
    return RefreshIndicator(
      onRefresh: () => ref
          .read(favoriteControllerProvider.notifier)
          .checkForUpdates(force: true),
      child: grid,
    );
  }

  String _followSummary(FavoriteRecord record) {
    if (!record.isFollowing) return record.video.remarks;
    if (record.sourceUnavailable) return '追更 · 来源异常';
    if (record.checkError != null) return '追更 · 检查失败';
    return record.latestEpisodeLabel.isEmpty ? '追更 · 等待检查' : '追更';
  }

  VideoCardOverlay? _followOverlay(FavoriteRecord? record) {
    if (record == null || record.latestEpisodeLabel.trim().isEmpty) return null;
    final latest = record.latestEpisodeLabel.trim();
    final canShowUnreadBadge =
        !record.sourceUnavailable && record.checkError == null;
    return VideoCardOverlay(
      bottomLabel: latest.startsWith('更新至') ? latest : '更新至 $latest',
      badgeLabel: canShowUnreadBadge && record.hasUnreadUpdate
          ? '新增${record.unreadAddedCount}集'
          : null,
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('清空观看记录？'),
        content: Text('此操作只会清除本机记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('清空'),
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
          loading: () => AppLoadingView(),
          error: (error, _) => AppErrorView(
            message: '$error',
            onRetry: () => ref.invalidate(watchHistoryProvider),
          ),
          data: (records) {
            if (records.isEmpty) {
              return AppEmptyView(
                icon: Icons.history,
                message: '还没有观看记录\n播放视频后可以从这里继续',
              );
            }
            return Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: TextButton(
                      onPressed: () => _clear(context, ref),
                      child: Text('清空'),
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
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 96),
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
                color: context.appColors.scrim,
                shape: CircleBorder(),
                child: InkWell(
                  key: ValueKey('history-delete-${record.video.globalId}'),
                  customBorder: CircleBorder(),
                  onTap: onDelete,
                  child: SizedBox.square(
                    dimension: 28,
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: context.appColors.text,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: 4),
      Text(
        record.resumeLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: context.appColors.secondary, fontSize: 12),
      ),
    ],
  );
}
