import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../domain/tmdb_catalog.dart';
import '../../../domain/video.dart';
import '../../../domain/video_feed.dart';
import '../../../domain/vod_source.dart';
import '../category_channels_page.dart';

/// 首页固定分类栏：主 Feed tab 行、TMDB 榜单范围行 / VOD 两级分类行、
/// 子分类行。挂在 SliverPersistentHeader 上与网格共享滚动位置。
/// 纯展示组件；选中状态与点击处理由首页持有，经回调上抛。
class HomeCategoryHeader extends StatelessWidget {
  const HomeCategoryHeader({
    super.key,
    required this.source,
    required this.metrics,
    required this.expandedOverlay,
    required this.collapsed,
    required this.leafTabKeys,
    required this.visibleFeeds,
    required this.selectedFeed,
    required this.catalogScope,
    required this.selectedRootId,
    required this.selectedCategoryId,
    required this.children,
    required this.visibleRoots,
    required this.categoryError,
    required this.feedTabKeys,
    required this.onSelectFeed,
    required this.onSelectCatalogScope,
    required this.onSelectRoot,
    required this.onSelectRootLeaf,
    required this.onLoadCategories,
    required this.onOpenChannelsPage,
    required this.onExpandPanel,
    required this.onCollapsePanel,
  });

  static const double _categoryToggleWidth = 44;

  final VodSource source;
  final HomeCategoryHeaderMetrics metrics;
  final bool expandedOverlay;
  final ValueListenable<bool> collapsed;
  final Map<int, GlobalKey> leafTabKeys;
  final List<VideoFeed> visibleFeeds;
  final VideoFeed selectedFeed;
  final TmdbCatalogScope catalogScope;
  final int? selectedRootId;
  final int? selectedCategoryId;
  final Map<int, List<VideoCategory>> children;
  final List<VideoCategory>? visibleRoots;
  final String? categoryError;
  final Map<VideoFeed, GlobalKey> feedTabKeys;
  final void Function(VideoFeed feed) onSelectFeed;
  final void Function(TmdbCatalogScope scope) onSelectCatalogScope;
  final void Function(int? rootId) onSelectRoot;
  final void Function(int rootId, int leafId) onSelectRootLeaf;
  final VoidCallback onLoadCategories;
  final VoidCallback onOpenChannelsPage;
  final VoidCallback onExpandPanel;
  final VoidCallback onCollapsePanel;

  static double mainRowHeight(BuildContext context) =>
      math.max(56, MediaQuery.textScalerOf(context).scale(14) + 28);

  static double subRowHeight(BuildContext context) =>
      math.max(48, MediaQuery.textScalerOf(context).scale(13) + 24);

  static double leafRowHeight(BuildContext context) =>
      math.max(42, MediaQuery.textScalerOf(context).scale(12) + 22);

  static HomeCategoryHeaderMetrics metricsOf({
    required BuildContext context,
    required VideoFeed selectedFeed,
    required int? selectedRootId,
    required Map<int, List<VideoCategory>> children,
    required List<VideoFeed> visibleFeeds,
  }) {
    final mainRow = mainRowHeight(context);
    final subRow = subRowHeight(context);
    final leafRow = leafRowHeight(context);
    final showFeedRow = visibleFeeds.length > 1;
    final showSecondaryRow = selectedFeed != VideoFeed.recommended;
    final showLeafRow =
        selectedFeed == VideoFeed.updated &&
        selectedRootId != null &&
        (children[selectedRootId]?.isNotEmpty ?? false);
    final expandedHeight =
        (showSecondaryRow ? subRow : 0.0) +
        (showFeedRow ? mainRow : 0.0) +
        (showLeafRow ? leafRow : 0.0) +
        1.0;
    final collapsedHeight =
        (showLeafRow
            ? leafRow
            : showSecondaryRow
            ? subRow
            : showFeedRow
            ? mainRow
            : 0.0) +
        1.0;
    return HomeCategoryHeaderMetrics(
      mainRowHeight: mainRow,
      subRowHeight: subRow,
      leafRowHeight: leafRow,
      visibleFeeds: visibleFeeds,
      showFeedRow: showFeedRow,
      showSecondaryRow: showSecondaryRow,
      showLeafRow: showLeafRow,
      expandedHeight: expandedHeight,
      collapsedHeight: collapsedHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mainRowHeight = metrics.mainRowHeight;
    final subRowHeight = metrics.subRowHeight;
    final leafRowHeight = metrics.leafRowHeight;
    final selectedChildren = selectedFeed == VideoFeed.updated
        ? (children[selectedRootId] ?? const <VideoCategory>[])
        : const <VideoCategory>[];
    return ClipRect(
      key: ValueKey(
        expandedOverlay
            ? 'home-category-expanded-panel'
            : 'home-category-header',
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: ColoredBox(
          color: context.appColors.background.withValues(alpha: 0.72),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (visibleFeeds.length > 1)
                    SizedBox(
                      height: mainRowHeight,
                      child: _pinnedRowChrome(
                        context,
                        active:
                            !metrics.showSecondaryRow && !metrics.showLeafRow,
                        child: ChipTheme(
                          data: categoryChipTheme(context).copyWith(
                            padding: EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 7,
                            ),
                          ),
                          child: ListView(
                            key: PageStorageKey<String>(
                              'home-feed-tabs-${source.id}',
                            ),
                            padding: EdgeInsets.fromLTRB(16, 4, 8, 4),
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(
                              parent: AlwaysScrollableScrollPhysics(),
                            ),
                            children: [
                              for (
                                var index = 0;
                                index < visibleFeeds.length;
                                index++
                              )
                                Padding(
                                  key: expandedOverlay
                                      ? null
                                      : feedTabKeys[visibleFeeds[index]],
                                  padding: EdgeInsets.only(
                                    right: index == visibleFeeds.length - 1
                                        ? 0
                                        : 8,
                                  ),
                                  child: ChoiceChip(
                                    key: ValueKey(
                                      'home-feed-${visibleFeeds[index].name}',
                                    ),
                                    label: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: Text(visibleFeeds[index].label),
                                    ),
                                    selected:
                                        selectedFeed == visibleFeeds[index],
                                    showCheckmark: false,
                                    onSelected: (_) =>
                                        onSelectFeed(visibleFeeds[index]),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (selectedFeed != VideoFeed.updated &&
                      selectedFeed != VideoFeed.recommended)
                    SizedBox(
                      height: subRowHeight,
                      child: _pinnedRowChrome(
                        context,
                        active: !metrics.showLeafRow,
                        parentContextLabel: selectedFeed.label,
                        child: ChipTheme(
                          data: _secondaryCategoryChipTheme(context),
                          child: ListView(
                            key: PageStorageKey<String>(
                              'home-tmdb-scope-tabs-${source.id}',
                            ),
                            padding: EdgeInsets.fromLTRB(16, 2, 16, 2),
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final scope in TmdbCatalogScope.values)
                                Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    key: ValueKey(
                                      'home-tmdb-scope-${scope.name}',
                                    ),
                                    label: Text(scope.label),
                                    selected: catalogScope == scope,
                                    showCheckmark: false,
                                    onSelected: (_) =>
                                        onSelectCatalogScope(scope),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else if (selectedFeed == VideoFeed.updated)
                    SizedBox(
                      height: subRowHeight,
                      child: _pinnedRowChrome(
                        context,
                        active: !metrics.showLeafRow,
                        parentContextLabel: selectedFeed.label,
                        child: Row(
                          children: [
                            Expanded(
                              child: ChipTheme(
                                data: _secondaryCategoryChipTheme(context),
                                child: ListView(
                                  key: PageStorageKey<String>(
                                    'home-root-category-tabs-${source.id}',
                                  ),
                                  padding: EdgeInsets.fromLTRB(16, 2, 8, 2),
                                  scrollDirection: Axis.horizontal,
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.only(right: 8),
                                      child: ChoiceChip(
                                        label: Text('全部'),
                                        selected: selectedRootId == null,
                                        showCheckmark: false,
                                        onSelected: (_) => onSelectRoot(null),
                                      ),
                                    ),
                                    ...?visibleRoots?.map(
                                      (item) => Padding(
                                        padding: EdgeInsets.only(right: 8),
                                        child: ChoiceChip(
                                          label: Text(item.name),
                                          selected: selectedRootId == item.id,
                                          showCheckmark: false,
                                          onSelected: (_) =>
                                              onSelectRoot(item.id),
                                        ),
                                      ),
                                    ),
                                    if (categoryError != null)
                                      ActionChip(
                                        label: Text('重试'),
                                        onPressed: onLoadCategories,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (visibleRoots?.isNotEmpty ?? false)
                              ValueListenableBuilder<bool>(
                                valueListenable: collapsed,
                                builder: (context, isCollapsed, _) =>
                                    expandedOverlay || !isCollapsed
                                    ? Padding(
                                        padding: EdgeInsets.only(right: 8),
                                        child: IconButton(
                                          key: ValueKey(
                                            'home-category-expand-button',
                                          ),
                                          tooltip: '全部频道与频道管理',
                                          visualDensity: VisualDensity.compact,
                                          icon: Icon(
                                            Icons.grid_view_rounded,
                                            size: 20,
                                            color: context.appColors.secondary,
                                          ),
                                          onPressed: onOpenChannelsPage,
                                        ),
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey(
                                          'home-category-channels-hidden',
                                        ),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (selectedChildren.isNotEmpty)
                    SizedBox(
                      height: leafRowHeight,
                      child: _pinnedRowChrome(
                        context,
                        active: true,
                        parentContextLabel: _selectedRootLabel,
                        child: ChipTheme(
                          data: categoryChipTheme(context).copyWith(
                            backgroundColor: Colors.transparent,
                            side: BorderSide(color: context.appColors.divider),
                            labelStyle: TextStyle(
                              color: context.appColors.secondary,
                              fontSize: 12,
                            ),
                            secondaryLabelStyle: TextStyle(
                              color: context.appColors.accentForeground,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            padding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            color: WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return context.appColors.accent.withValues(
                                  alpha: 0.18,
                                );
                              }
                              return Colors.transparent;
                            }),
                          ),
                          child: ListView(
                            key: PageStorageKey<String>(
                              'home-child-category-tabs-${source.id}-$selectedRootId',
                            ),
                            padding: EdgeInsets.fromLTRB(16, 2, 16, 2),
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final child in selectedChildren)
                                Padding(
                                  key: expandedOverlay
                                      ? null
                                      : leafTabKeys.putIfAbsent(
                                          child.id,
                                          () => GlobalKey(
                                            debugLabel:
                                                'home-child-category-${child.id}',
                                          ),
                                        ),
                                  padding: EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    key: ValueKey(
                                      'home-child-category-${child.id}',
                                    ),
                                    label: Text(child.name),
                                    selected: selectedCategoryId == child.id,
                                    showCheckmark: false,
                                    onSelected: (_) => onSelectRootLeaf(
                                      selectedRootId!,
                                      child.id,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Container(
                    height: 1,
                    color: context.appColors.divider.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pinnedRowChrome(
    BuildContext context, {
    required bool active,
    required Widget child,
    String? parentContextLabel,
  }) {
    if (!active) return child;

    Widget buildRow({required String? leadingLabel}) => Row(
      children: [
        if (leadingLabel != null) _parentContext(context, leadingLabel),
        Expanded(child: child),
        _categoryToggleButton(context),
      ],
    );

    if (expandedOverlay) return buildRow(leadingLabel: null);
    return ValueListenableBuilder<bool>(
      valueListenable: collapsed,
      child: child,
      builder: (context, isCollapsed, uncollapsedChild) {
        if (!isCollapsed) return uncollapsedChild!;
        return buildRow(leadingLabel: parentContextLabel);
      },
    );
  }

  String get _selectedRootLabel {
    final root = visibleRoots?.where((item) => item.id == selectedRootId);
    return root == null || root.isEmpty ? '全部' : root.first.name;
  }

  Widget _parentContext(BuildContext context, String label) {
    return Container(
      key: const ValueKey('home-category-parent-context'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      margin: const EdgeInsets.only(left: 12),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.appColors.accentForeground,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _categoryToggleButton(BuildContext context) => SizedBox(
    key: const ValueKey('home-category-toggle-visible'),
    width: _categoryToggleWidth,
    child: IconButton(
      key: ValueKey(
        expandedOverlay
            ? 'home-category-panel-collapse-button'
            : 'home-category-panel-expand-button',
      ),
      tooltip: expandedOverlay ? '收起分类' : '展开完整分类',
      onPressed: expandedOverlay ? onCollapsePanel : onExpandPanel,
      icon: AnimatedRotation(
        turns: expandedOverlay ? 0.5 : 0,
        duration: const Duration(milliseconds: 180),
        child: Icon(
          Icons.keyboard_arrow_down_rounded,
          color: context.appColors.secondary,
        ),
      ),
    ),
  );

  ChipThemeData _secondaryCategoryChipTheme(BuildContext context) =>
      categoryChipTheme(context).copyWith(
        backgroundColor: Colors.transparent,
        side: BorderSide(
          color: context.appColors.divider.withValues(alpha: 0.72),
        ),
        labelStyle: TextStyle(color: context.appColors.secondary, fontSize: 13),
        secondaryLabelStyle: TextStyle(
          color: context.appColors.accentForeground,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return context.appColors.accent.withValues(alpha: 0.16);
          }
          return Colors.transparent;
        }),
      );
}

/// 钉住分类栏的 SliverPersistentHeaderDelegate。
class HomePinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  HomePinnedHeaderDelegate({
    required this.minHeight,
    required this.maxHeight,
    required this.child,
    required this.onCollapsedChanged,
  });

  final double minHeight;
  final double maxHeight;
  final Widget child;
  final ValueChanged<bool> onCollapsedChanged;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => math.max(minHeight, maxHeight);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final collapseDistance = maxExtent - minExtent;
    final collapsed =
        collapseDistance > 0.5 && shrinkOffset >= collapseDistance - 0.5;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onCollapsedChanged(collapsed);
    });
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: maxExtent,
        maxHeight: maxExtent,
        child: SizedBox(height: maxExtent, child: child),
      ),
    );
  }

  @override
  bool shouldRebuild(HomePinnedHeaderDelegate oldDelegate) =>
      minHeight != oldDelegate.minHeight ||
      maxHeight != oldDelegate.maxHeight ||
      child != oldDelegate.child;
}

class HomeCategoryHeaderMetrics {
  const HomeCategoryHeaderMetrics({
    required this.mainRowHeight,
    required this.subRowHeight,
    required this.leafRowHeight,
    required this.visibleFeeds,
    required this.showFeedRow,
    required this.showSecondaryRow,
    required this.showLeafRow,
    required this.expandedHeight,
    required this.collapsedHeight,
  });

  final double mainRowHeight;
  final double subRowHeight;
  final double leafRowHeight;
  final List<VideoFeed> visibleFeeds;
  final bool showFeedRow;
  final bool showSecondaryRow;
  final bool showLeafRow;
  final double expandedHeight;
  final double collapsedHeight;
}
