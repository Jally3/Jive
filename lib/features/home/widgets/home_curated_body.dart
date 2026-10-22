import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../domain/video.dart';
import '../../../domain/vod_source.dart';
import '../../../shared/app_states.dart';
import '../../../shared/source_selector.dart';
import '../controllers/curated_feed_controller.dart';
import 'curated_video_grid.dart';
import 'home_state_scroll_view.dart';

/// 首页 TMDB 策展榜单流：状态视图、匹配摘要、失败重试与继续加载。
class HomeCuratedBody extends StatelessWidget {
  const HomeCuratedBody({
    super.key,
    required this.controller,
    required this.source,
    required this.headerSlivers,
    required this.scrollController,
    required this.showBackToTop,
    required this.onOpen,
    required this.onRefresh,
    required this.onSlotTap,
  });

  final CuratedFeedController controller;
  final VodSource source;
  final List<Widget> headerSlivers;
  final ScrollController scrollController;
  final ValueNotifier<bool> showBackToTop;
  final void Function(Video video) onOpen;
  final Future<void> Function() onRefresh;
  final void Function(CuratedSearchSlot slot) onSlotTap;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.slots.isEmpty && c.catalogLoading) {
      return homeStateScrollView(
        headerSlivers: headerSlivers,
        controller: scrollController,
        state: AppLoadingView(label: '正在获取榜单…'),
      );
    }
    if (c.slots.isEmpty && c.error != null) {
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
    if (c.slots.isEmpty) {
      return homeStateScrollView(
        headerSlivers: headerSlivers,
        controller: scrollController,
        state: AppEmptyView(message: '当前榜单暂无影片'),
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
        child: CuratedVideoGrid(
          slots: c.slots,
          onTap: onSlotTap,
          topPadding: 12,
          bottomPadding: 96,
          controller: scrollController,
          physics: AlwaysScrollableScrollPhysics(),
          headerSlivers: headerSlivers,
          footer: _footer(context, c),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, CuratedFeedController c) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _summary(context, c),
      if (c.hasMore || c.failedEntries.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (c.failedEntries.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: c.retryFailed,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试失败项'),
                ),
              if (c.hasMore)
                FilledButton.tonalIcon(
                  key: const ValueKey('curated-load-more'),
                  onPressed: c.loadMore,
                  icon: const Icon(Icons.expand_more_rounded, size: 18),
                  label: const Text('继续加载榜单'),
                ),
            ],
          ),
        )
      else
        Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              '没有更多了',
              style: TextStyle(color: context.appColors.tertiary, fontSize: 12),
            ),
          ),
        ),
    ],
  );

  Widget _summary(BuildContext context, CuratedFeedController c) {
    int count(CuratedSlotStatus status) =>
        c.slots.where((slot) => slot.status == status).length;
    final pending =
        count(CuratedSlotStatus.queued) + count(CuratedSlotStatus.searching);
    final unavailable =
        count(CuratedSlotStatus.unavailable) +
        count(CuratedSlotStatus.duplicate);
    final parts = <String>[
      '当前 ${c.slots.length} 部：可播放 ${count(CuratedSlotStatus.available)}',
      '当前源暂无 $unavailable',
      '多候选 ${count(CuratedSlotStatus.ambiguous)}',
      '请求失败 ${count(CuratedSlotStatus.failed)}',
      if (pending > 0) '搜索中 $pending',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Text(
        c.sourceUnavailable
            ? '${parts.join(' · ')}\n当前来源暂不可用，已暂停后续搜索'
            : parts.join(' · '),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: context.appColors.secondary,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}
