import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/content/category_nav.dart';
import '../../data/content/content_filter_policy.dart';
import '../../data/content/my_channels_store.dart';
import '../../data/history_repository.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_preferences.dart';
import '../../domain/video.dart';
import '../../domain/vod_source.dart';
import '../../shared/source_selector.dart';
import '../../shared/video_grid.dart';
import '../detail/detail_page.dart';
import './category_channels_page.dart';
import './continue_watching_row.dart';
import './paged_video_controller.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  PagedVideoController? controller;

  /// 顶级分类（tab 栏）与按父 id 分组的子分类（横滑栏）。
  /// MacCMS 的内容只挂在叶子分类上，所以两级导航：
  /// 选中顶级分类后展示其子分类，实际查询使用叶子分类 id。
  List<VideoCategory>? _roots;
  Map<int, List<VideoCategory>> _children = const {};
  int? _selectedRootId;
  int? selectedCategoryId;
  String? categoryError;
  String? _activeSourceId;

  /// 「我的频道」：主 tab 行展示的根分类 id 及顺序，按源持久化；
  /// null 表示未定制，展示全部根分类。
  List<int>? _myChannelIds;

  /// 网格滚动控制器与"返回顶部"悬浮按钮的可见性（滚动超过一屏左右时出现）。
  /// 不保存 PageStorage offset，切换分类或来源后始终从新列表顶部开始。
  final _scrollController = ScrollController(keepScrollOffset: false);
  final _showBackToTop = ValueNotifier<bool>(false);

  @override
  void dispose() {
    controller?.removeListener(_changed);
    controller?.dispose();
    _scrollController.dispose();
    _showBackToTop.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _resetScrollPosition() {
    _showBackToTop.value = false;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _resetScrollPositionAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resetScrollPosition();
    });
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _ensureController(VodSource source) {
    if (controller != null && _activeSourceId == source.id) return;
    _resetScrollPositionAfterBuild();
    controller?.removeListener(_changed);
    controller?.dispose();
    controller = PagedVideoController(ref.read(videoRepositoryProvider), source)
      ..addListener(_changed);
    _activeSourceId = source.id;
    _roots = null;
    _children = const {};
    _selectedRootId = null;
    selectedCategoryId = null;
    categoryError = null;
    _myChannelIds = null;
    controller!.loadInitial();
    _loadCategories(source);
  }

  Future<void> _loadCategories(VodSource source) async {
    setState(() => categoryError = null);
    bool isActive() => mounted && _activeSourceId == source.id;
    try {
      final all = await ref
          .read(videoRepositoryProvider)
          .fetchCategories(source);
      if (!isActive()) return;
      var nav = buildCategoryNav(all, featuredIds: source.featuredCategoryIds);
      if (!isActive()) return;
      setState(() {
        _roots = nav.roots;
        _children = nav.children;
      });
      final myIds = await MyChannelsStore.load(source.id);
      if (!isActive()) return;
      setState(() => _myChannelIds = myIds);
      final repository = ref.read(videoRepositoryProvider);
      final emptyIds = await findEmptyCategoryIds(
        ids: categoryIdsToProbe(nav),
        fetchPage: (id) =>
            repository.fetchPage(source, page: 1, categoryId: id),
      );
      if (!isActive() || emptyIds.isEmpty) return;
      nav = hideEmptyCategories(nav, emptyIds);
      if (!isActive()) return;
      final selectable = {
        for (final root in nav.roots) root.id,
        for (final kids in nav.children.values)
          for (final child in kids) child.id,
      };
      final selectionGone =
          (_selectedRootId != null &&
              !nav.roots.any((item) => item.id == _selectedRootId)) ||
          (selectedCategoryId != null &&
              !selectable.contains(selectedCategoryId));
      setState(() {
        _roots = nav.roots;
        _children = nav.children;
        if (selectionGone) {
          _selectedRootId = null;
          selectedCategoryId = null;
        }
      });
      if (selectionGone) await controller?.loadInitial();
    } catch (e) {
      if (isActive()) setState(() => categoryError = e.toString());
    }
  }

  /// 选中顶级分类：有子分类时展示子分类栏并自动选中第一个子分类；
  /// 无子分类时直接按该分类查询。rootId 为 null 表示"最新"。
  Future<void> _selectRoot(VodSource source, int? rootId) async {
    final children = _children[rootId] ?? const <VideoCategory>[];
    final queryId = rootId == null
        ? null
        : (children.isEmpty ? rootId : children.first.id);
    _resetScrollPosition();
    setState(() {
      _selectedRootId = rootId;
      selectedCategoryId = queryId;
    });
    await controller?.loadInitial(category: queryId);
  }

  Future<void> _selectLeaf(int categoryId) async {
    _resetScrollPosition();
    setState(() => selectedCategoryId = categoryId);
    await controller?.loadInitial(category: categoryId);
  }

  /// 下拉面板里直接选中子分类：同步所属主分类高亮并按子分类查询。
  Future<void> _selectRootLeaf(int rootId, int leafId) async {
    _resetScrollPosition();
    setState(() {
      _selectedRootId = rootId;
      selectedCategoryId = leafId;
    });
    await controller?.loadInitial(category: leafId);
  }

  /// 打开「全部频道」全屏页面：选择分类、管理我的频道（增删/拖拽排序）。
  void _openChannelsPage(VodSource source) {
    final roots = _roots;
    if (roots == null || roots.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CategoryChannelsPage(
          roots: roots,
          children: _children,
          myChannelIds: _myChannelIds,
          selectedRootId: _selectedRootId,
          selectedCategoryId: selectedCategoryId,
          onSelectRoot: (id) => _selectRoot(source, id),
          onSelectLeaf: (rootId, leafId) => _selectRootLeaf(rootId, leafId),
          onAddRoot: (id) => _addMyChannel(source, id),
          onRemoveRoot: (id) => _removeMyChannel(source, id),
          onReorder: (ids) => _reorderMyChannels(source, ids),
          onReset: () => _resetMyChannels(source),
        ),
      ),
    );
  }

  /// 当前生效的「我的频道」id 列表（未定制时为全部根分类）。
  List<int> _currentMyChannelIds() =>
      _myChannelIds ??
      [for (final root in _roots ?? const <VideoCategory>[]) root.id];

  Future<void> _addMyChannel(VodSource source, int rootId) async {
    final current = _currentMyChannelIds();
    if (current.contains(rootId)) return;
    final next = [...current, rootId];
    setState(() => _myChannelIds = next);
    await MyChannelsStore.save(source.id, next);
  }

  Future<void> _removeMyChannel(VodSource source, int rootId) async {
    final next = _currentMyChannelIds().where((id) => id != rootId).toList();
    setState(() => _myChannelIds = next);
    await MyChannelsStore.save(source.id, next);
    // 移除的正是当前选中分类时回到「最新」。
    if (_selectedRootId == rootId) await _selectRoot(source, null);
  }

  Future<void> _reorderMyChannels(VodSource source, List<int> ids) async {
    setState(() => _myChannelIds = ids);
    await MyChannelsStore.save(source.id, ids);
  }

  Future<void> _resetMyChannels(VodSource source) async {
    setState(() => _myChannelIds = null);
    await MyChannelsStore.reset(source.id);
  }

  void _open(Video video) {
    final current = homeContinueWatchingRecord(
      ref.read(watchHistoryProvider).value ?? const [],
    );
    if (current != null && current.video.globalId != video.globalId) {
      ref.read(continueWatchingSessionHiddenProvider.notifier).hide();
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));
  }

  List<VideoCategory> get _selectedRootChildren =>
      _children[_selectedRootId] ?? const [];

  /// 主 tab 行实际展示的根分类：按「我的频道」定制过滤并保持顺序；
  /// 未定制或定制全部失效时回退为全部根分类。
  List<VideoCategory>? get _visibleRoots {
    final roots = _roots;
    if (roots == null) return null;
    final ids = _myChannelIds;
    if (ids == null) return roots;
    final byId = {for (final root in roots) root.id: root};
    final mine = [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
    return mine.isEmpty ? roots : mine;
  }

  @override
  Widget build(BuildContext context) {
    // 内容过滤开关变化：丢弃旧控制器，由 _ensureController 用重建后的
    // repository（含新开关状态）重新加载列表与分类。
    // 首次从 loading 解析出默认值时不算变化，避免启动时双重加载。
    ref.listen(contentFilterEnabledProvider, (previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before == null || after == null || before == after) return;
      _resetScrollPositionAfterBuild();
      controller?.removeListener(_changed);
      controller?.dispose();
      controller = null;
      _activeSourceId = null;
      setState(() {});
    });
    final sourceState = ref.watch(selectedVodSourceProvider);
    return SafeArea(
      // bottom: false —— extendBody 会把底部导航栏高度计入 MediaQuery.padding，
      // 若此处消费掉，网格就无法延伸到毛玻璃导航栏下方。
      bottom: false,
      child: sourceState.when(
        loading: () => const AppLoadingView(label: '正在加载来源…'),
        error: (error, _) => AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(selectedVodSourceProvider),
        ),
        data: (source) {
          _ensureController(source);
          return _buildContent(source);
        },
      ),
    );
  }

  Widget _buildContent(VodSource source) => Stack(
    children: [
      Positioned.fill(child: _body(source)),
      Positioned(right: 16, bottom: 88, child: _backToTopButton()),
    ],
  );

  /// 返回顶部悬浮按钮：与底栏同款毛玻璃质感，滚动超阈值后淡入。
  Widget _backToTopButton() => ValueListenableBuilder<bool>(
    valueListenable: _showBackToTop,
    builder: (context, show, _) => AnimatedOpacity(
      opacity: show ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !show,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Material(
              color: AppColors.surface.withValues(alpha: 0.75),
              shape: const CircleBorder(
                side: BorderSide(color: AppColors.divider),
              ),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _scrollToTop,
                child: const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    color: AppColors.accent,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  double _mainCategoryRowHeight(BuildContext context) =>
      math.max(56, MediaQuery.textScalerOf(context).scale(14) + 28);

  double _subCategoryRowHeight(BuildContext context) =>
      math.max(48, MediaQuery.textScalerOf(context).scale(13) + 24);

  List<Widget> _homeHeaderSlivers(VodSource source) {
    final mainRowHeight = _mainCategoryRowHeight(context);
    final subRowHeight = _subCategoryRowHeight(context);
    final hasSubcategories = _selectedRootChildren.isNotEmpty;
    final pinnedHeight =
        mainRowHeight + (hasSubcategories ? subRowHeight : 0) + 1;
    return [
      SliverToBoxAdapter(child: _introHeader()),
      const SliverToBoxAdapter(child: ContinueWatchingSection()),
      SliverPersistentHeader(
        pinned: true,
        delegate: _PinnedHeaderDelegate(
          height: pinnedHeight,
          child: _categoryHeader(
            source,
            mainRowHeight: mainRowHeight,
            subRowHeight: subRowHeight,
          ),
        ),
      ),
    ];
  }

  Widget _introHeader() => Container(
    constraints: const BoxConstraints(minHeight: 104),
    color: AppColors.background.withValues(alpha: 0.55),
    padding: const EdgeInsets.fromLTRB(16, 24, 8, 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: _confirmToggleContentFilter,
                child: const Text(
                  'Jive',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '今晚，看点好内容',
                style: TextStyle(color: AppColors.secondary, fontSize: 15),
              ),
            ],
          ),
        ),
        SourceIndicatorButton(),
      ],
    ),
  );

  /// 长按「Jive」标题切换敏感内容过滤（默认开启），选择持久化。
  Future<void> _confirmToggleContentFilter() async {
    final enabled = ref.read(contentFilterEnabledProvider).value ?? true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(enabled ? '关闭内容过滤？' : '开启内容过滤？'),
        content: Text(
          enabled ? '当前已隐藏伦理、擦边等敏感分类及其内容。关闭后将显示全部分类。' : '开启后将隐藏伦理、擦边等敏感分类及其内容。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(enabled ? '关闭过滤' : '开启过滤'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await ref.read(contentFilterEnabledProvider.notifier).setEnabled(!enabled);
  }

  /// 分类栏由 Sliver 系统与网格共享同一滚动位置，不再单独动画或填充顶部间距。
  Widget _categoryHeader(
    VodSource source, {
    required double mainRowHeight,
    required double subRowHeight,
  }) => ClipRect(
    key: const ValueKey('home-category-header'),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: ColoredBox(
        color: AppColors.background.withValues(alpha: 0.72),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: mainRowHeight,
              child: Row(
                children: [
                  Expanded(
                    child: ChipTheme(
                      data: categoryChipTheme,
                      child: ListView(
                        key: PageStorageKey<String>(
                          'home-root-category-tabs-${source.id}',
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                        scrollDirection: Axis.horizontal,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: const Text('最新'),
                              selected: _selectedRootId == null,
                              showCheckmark: false,
                              onSelected: (_) => _selectRoot(source, null),
                            ),
                          ),
                          ...?_visibleRoots?.map(
                            (item) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(item.name),
                                selected: _selectedRootId == item.id,
                                showCheckmark: false,
                                onSelected: (_) => _selectRoot(source, item.id),
                              ),
                            ),
                          ),
                          if (categoryError != null)
                            ActionChip(
                              label: const Text('重试'),
                              onPressed: () => _loadCategories(source),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // 固定在横滑列表右侧的「全部频道」入口按钮。
                  if (_visibleRoots?.isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        key: const ValueKey('home-category-expand-button'),
                        tooltip: '全部频道',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: AppColors.secondary,
                        ),
                        onPressed: () => _openChannelsPage(source),
                      ),
                    ),
                ],
              ),
            ),
            if (_selectedRootChildren.isNotEmpty)
              SizedBox(
                height: subRowHeight,
                child: ChipTheme(
                  data: categoryChipTheme.copyWith(
                    backgroundColor: AppColors.elevated.withValues(alpha: 0.45),
                    // copyWith 会沿用 categoryChipTheme 的 color 解析器（优先级高于
                    // backgroundColor），这里同步覆盖为 0.45 版本，保持原有底色。
                    color: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return states.contains(WidgetState.focused)
                            ? AppColors.accentPressed
                            : AppColors.accent;
                      }
                      return AppColors.elevated.withValues(alpha: 0.45);
                    }),
                    labelStyle: const TextStyle(
                      color: AppColors.secondary,
                      fontSize: 13,
                    ),
                    secondaryLabelStyle: const TextStyle(
                      color: AppColors.onAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                  child: ListView(
                    key: PageStorageKey<String>(
                      'home-leaf-category-tabs-${source.id}-'
                      '${_selectedRootId ?? 'none'}',
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                    scrollDirection: Axis.horizontal,
                    children: _selectedRootChildren
                        .map(
                          (item) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(item.name),
                              selected: selectedCategoryId == item.id,
                              showCheckmark: false,
                              onSelected: (_) => _selectLeaf(item.id),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            Container(
              height: 1,
              color: AppColors.divider.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _body(VodSource source) {
    final c = controller;
    if (c == null) {
      return _stateScrollView(source, const AppLoadingView());
    }
    if (c.items.isEmpty && c.loading) {
      return _stateScrollView(source, const AppLoadingView());
    }
    if (c.items.isEmpty && c.error != null) {
      return _stateScrollView(
        source,
        AppErrorView(
          message: c.error!,
          onRetry: c.refresh,
          secondaryLabel: '切换来源',
          secondaryAction: () => SourceSelectorSheet.show(context),
        ),
      );
    }
    if (c.items.isEmpty) {
      return _stateScrollView(source, const AppEmptyView(message: '暂时没有内容'));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        // 分类栏内的横向 ListView 也会上报滚动通知，只处理主网格。
        if (event.depth != 0 || event.metrics.axis != Axis.vertical) {
          return false;
        }
        // 滚动超过约一屏后显示"返回顶部"悬浮按钮。
        final showTop = event.metrics.pixels > 600;
        if (showTop != _showBackToTop.value) _showBackToTop.value = showTop;
        if (event.metrics.extentAfter < 400) c.loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: c.refresh,
        child: VideoGrid(
          videos: c.items,
          onTap: _open,
          topPadding: 12,
          bottomPadding: 96,
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          headerSlivers: _homeHeaderSlivers(source),
          footer: c.loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : (!c.hasMore
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text(
                            '没有更多了',
                            style: TextStyle(
                              color: AppColors.tertiary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                    : null),
        ),
      ),
    );
  }

  Widget _stateScrollView(VodSource source, Widget state) => CustomScrollView(
    controller: _scrollController,
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [
      ..._homeHeaderSlivers(source),
      SliverFillRemaining(hasScrollBody: false, child: state),
    ],
  );
}

class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedHeaderDelegate({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox.expand(child: child);

  @override
  bool shouldRebuild(_PinnedHeaderDelegate oldDelegate) =>
      height != oldDelegate.height || child != oldDelegate.child;
}
