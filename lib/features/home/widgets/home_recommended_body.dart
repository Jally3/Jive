import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../domain/video.dart';
import '../../../domain/vod_source.dart';
import '../../../shared/app_states.dart';
import '../../../shared/source_selector.dart';
import '../../../shared/video_grid.dart';
import 'recommendation_unavailable_section.dart';
import '../controllers/recommended_feed_controller.dart';
import 'home_state_scroll_view.dart';

/// 首页「猜你喜欢」推荐流：状态视图、匹配进度横幅、加载更多控制与
/// 不可用候选列表。控制器与回调由首页持有。
class HomeRecommendedBody extends StatelessWidget {
  const HomeRecommendedBody({
    super.key,
    required this.controller,
    required this.source,
    required this.headerSlivers,
    required this.scrollController,
    required this.showBackToTop,
    required this.searchingIds,
    required this.onOpen,
    required this.onRefresh,
    required this.onSlotUnavailable,
  });

  final RecommendedFeedController controller;
  final VodSource source;
  final List<Widget> headerSlivers;
  final ScrollController scrollController;
  final ValueNotifier<bool> showBackToTop;

  /// 跨源查找进行中的候选 id，用于在不可用列表上显示搜索状态。
  final Set<String> searchingIds;
  final void Function(Video video) onOpen;
  final Future<void> Function() onRefresh;
  final void Function(RecommendedCandidateSlot slot) onSlotUnavailable;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.items.isEmpty && c.slots.isEmpty && c.loading) {
      return homeStateScrollView(
        headerSlivers: headerSlivers,
        controller: scrollController,
        state: AppLoadingView(
          label: c.generating
              ? '阶段 1/2 · AI 正在生成个性化推荐…'
              : '阶段 2/2 · 正在当前来源匹配可播资源…',
        ),
      );
    }
    if (c.coldStart) {
      return homeStateScrollView(
        headerSlivers: headerSlivers,
        controller: scrollController,
        state: const AppEmptyView(message: '看过或收藏几部影片后，这里会出现更懂你的推荐。'),
      );
    }
    if (c.items.isEmpty && c.unavailableSlots.isEmpty && c.error != null) {
      return homeStateScrollView(
        headerSlivers: headerSlivers,
        controller: scrollController,
        state: AppErrorView(
          message: c.error!,
          onRetry: onRefresh,
          secondaryLabel: '切换来源',
          secondaryAction: () => SourceSelectorSheet.show(context),
        ),
      );
    }
    if (c.items.isEmpty && c.unavailableSlots.isEmpty && !c.loading) {
      return homeStateScrollView(
        headerSlivers: headerSlivers,
        controller: scrollController,
        state: AppEmptyView(message: '当前来源暂未找到可播放的推荐内容'),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.depth != 0 || event.metrics.axis != Axis.vertical) {
          return false;
        }
        final showTop = event.metrics.pixels > 600;
        if (showTop != showBackToTop.value) showBackToTop.value = showTop;
        return false;
      },
      child: RefreshIndicator(
        onRefresh: onRefresh,
        child: VideoGrid(
          videos: c.items,
          onTap: onOpen,
          topPadding: 12,
          bottomPadding: 96,
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          headerSlivers: [
            ...headerSlivers,
            if (c.matching && !c.loadingMore)
              SliverToBoxAdapter(child: _matchingProgress(context, c)),
          ],
          footer: _footer(context, c),
        ),
      ),
    );
  }

  Widget _matchingProgress(BuildContext context, RecommendedFeedController c) {
    final total = c.candidates.length;
    final completed = c.searched.clamp(0, total);
    final progress = total == 0 ? null : completed / total;
    return Semantics(
      liveRegion: true,
      label:
          '正在${source.name}匹配可播资源，已检查 $completed 部，'
          '共 $total 部，已找到 ${c.items.length} 部',
      child: Container(
        key: const ValueKey('recommendation-matching-progress'),
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.appColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.appColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '阶段 2/2 · VOD 匹配',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '正在${source.name}搜索可播资源',
              style: TextStyle(
                color: context.appColors.secondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              '已检查 $completed/$total · 可播放 ${c.items.length}',
              style: TextStyle(
                color: context.appColors.secondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, RecommendedFeedController c) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _summary(context, c),
      _loadControl(context, c),
      if (c.unavailableSlots.isNotEmpty)
        RecommendationUnavailableSection(
          key: ValueKey(
            'recommendation-unavailable-'
            '${c.sessionId ?? identityHashCode(c)}',
          ),
          slots: c.unavailableSlots,
          playableCount: c.items.length,
          searchingIds: searchingIds,
          onTap: onSlotUnavailable,
        ),
    ],
  );

  Widget _loadControl(BuildContext context, RecommendedFeedController c) {
    if (c.matching && !c.loadingMore) {
      return const SizedBox.shrink();
    }
    if (c.fetchingMore) {
      return const Padding(
        key: ValueKey('recommendation-loading-more'),
        padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('正在获取下一页推荐…'),
          ],
        ),
      );
    }
    if (c.matchingMore) {
      return const Padding(
        key: ValueKey('recommendation-matching-more'),
        padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('正在当前来源匹配新推荐…'),
          ],
        ),
      );
    }
    if (c.error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: Column(
          children: [
            Text(
              c.error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appColors.error, fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('recommendation-retry-more'),
              onPressed: c.hasMore ? c.loadMore : null,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试加载'),
            ),
          ],
        ),
      );
    }
    if (c.hasMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: FilledButton.tonalIcon(
          key: const ValueKey('recommendation-load-more'),
          onPressed: c.loadMore,
          icon: const Icon(Icons.expand_more_rounded, size: 18),
          label: const Text('加载更多推荐'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Text(
        '没有更多推荐了',
        style: TextStyle(color: context.appColors.tertiary, fontSize: 12),
      ),
    );
  }

  Widget _summary(BuildContext context, RecommendedFeedController c) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
    child: Text(
      c.playableFromCache
          ? '本地缓存 · 可播放 ${c.items.length} 部'
          : [
              '模型 ${c.candidates.length} 部',
              '已搜索 ${c.searched}',
              '可播放 ${c.items.length}',
              '未找到 ${c.notFound}',
              '歧义 ${c.ambiguous}',
              '失败 ${c.failed}',
              if (c.fromCache) '模型缓存',
              if (c.matching && !c.loadingMore) '匹配中',
            ].join(' · '),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: context.appColors.secondary,
        fontSize: 12,
        height: 1.5,
      ),
    ),
  );
}
