import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../data/vod_source_preferences.dart';
import '../domain/video.dart';
import '../domain/vod_source.dart';
import '../shared/source_selector.dart';
import '../shared/video_grid.dart';
import 'detail_page.dart';
import 'paged_video_controller.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin {
  /// 顶部毛玻璃浮层高度：header 104 + 顶级分类栏 56 + 分隔线 1。
  /// 选中带子分类的顶级分类时，额外叠加子分类栏 [_subRowHeight]，
  /// 与网格 topPadding 保持一致。
  static const _topBarHeight = 161.0;
  static const _subRowHeight = 48.0;

  /// 头部（标题区）高度：向下滚动时向上折叠隐藏，分类栏保持吸顶。
  static const _headerHeight = 104.0;

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

  /// 头部折叠量（0 ~ [_headerHeight]），仅驱动顶栏浮层重建，避免整页 setState。
  final _headerCollapse = ValueNotifier<double>(0);
  double _lastScrollPixels = 0;

  /// 本次滚动手势是否允许触发下拉刷新：手势开始时头部已完全展开才置真。
  /// 防止"下拉展开头部"的手势因速度过快，剩余 overscroll 直接冲过刷新阈值。
  bool _refreshArmed = true;

  /// 网格滚动控制器与"返回顶部"悬浮按钮的可见性（滚动超过一屏左右时出现）。
  final _scrollController = ScrollController();
  final _showBackToTop = ValueNotifier<bool>(false);

  /// 滚动停止后的吸附动画：折叠量只跟随滚动手势，松手后吸附到全展/全收，
  /// 避免标题停留在被裁切一半的中间态。控制器整个生命周期复用一个，
  /// 每次吸附仅替换 Tween 并重放（SingleTickerProvider 只允许一个 Ticker）。
  late final AnimationController _snap;
  Animation<double>? _snapAnimation;

  @override
  void initState() {
    super.initState();
    _snap =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 180),
        )..addListener(() {
          final anim = _snapAnimation;
          if (anim != null) _headerCollapse.value = anim.value;
        });
  }

  @override
  void dispose() {
    controller?.removeListener(_changed);
    controller?.dispose();
    _headerCollapse.dispose();
    _snap.dispose();
    _scrollController.dispose();
    _showBackToTop.dispose();
    super.dispose();
  }

  void _snapHeader() {
    final from = _headerCollapse.value;
    final target = from * 2 < _headerHeight ? 0.0 : _headerHeight;
    if (from == target) return;
    _snapAnimation = Tween(
      begin: from,
      end: target,
    ).animate(CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic));
    _snap.forward(from: 0);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _ensureController(VodSource source) {
    if (controller != null && _activeSourceId == source.id) return;
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
      final byId = {for (final item in all) item.id: item};
      // 部分源不返回 type_pid，此时所有分类都视为顶级、没有子分类。
      bool isRoot(VideoCategory item) =>
          item.parentId == 0 || !byId.containsKey(item.parentId);
      var roots = all.where(isRoot).toList();
      final children = <int, List<VideoCategory>>{};
      for (final item in all) {
        if (!isRoot(item)) {
          children.putIfAbsent(item.parentId, () => []).add(item);
        }
      }
      final featured = source.featuredCategoryIds;
      if (featured.isNotEmpty) {
        final filtered = roots
            .where((item) => featured.contains(item.id))
            .toList();
        if (filtered.isNotEmpty) roots = filtered;
      }
      if (!isActive()) return;
      setState(() {
        _roots = roots;
        _children = children;
      });
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
    setState(() {
      _selectedRootId = rootId;
      selectedCategoryId = queryId;
    });
    await controller?.loadInitial(category: queryId);
  }

  Future<void> _selectLeaf(int categoryId) async {
    setState(() => selectedCategoryId = categoryId);
    await controller?.loadInitial(category: categoryId);
  }

  void _open(Video video) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));

  List<VideoCategory> get _selectedRootChildren =>
      _children[_selectedRootId] ?? const [];

  double get _gridTopPadding =>
      _topBarHeight + (_selectedRootChildren.isEmpty ? 0 : _subRowHeight);

  @override
  Widget build(BuildContext context) {
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
      Positioned.fill(child: _body()),
      Positioned(top: 0, left: 0, right: 0, child: _frostedTopBar(source)),
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
                onTap: () => _scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                ),
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

  static ChipThemeData get _chipTheme => ChipThemeData(
    backgroundColor: AppColors.elevated.withValues(alpha: 0.6),
    selectedColor: AppColors.accent,
    disabledColor: AppColors.surface,
    side: const BorderSide(color: AppColors.divider),
    shape: const StadiumBorder(),
    labelStyle: const TextStyle(color: AppColors.text, fontSize: 14),
    secondaryLabelStyle: const TextStyle(
      color: AppColors.onAccent,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    checkmarkColor: AppColors.onAccent,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  );

  /// 悬浮毛玻璃顶栏：网格内容从其下方滚过时透出模糊影像。
  Widget _frostedTopBar(VodSource source) => ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: Container(
        color: AppColors.background.withValues(alpha: 0.55),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: _headerCollapse,
              builder: (context, collapse, child) => ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1 - collapse / _headerHeight,
                  child: child,
                ),
              ),
              child: SizedBox(
                height: _headerHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 8, 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Jive',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '今晚，看点好内容',
                              style: TextStyle(
                                color: AppColors.secondary,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SourceIndicatorButton(),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 56,
              child: ChipTheme(
                data: _chipTheme,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
                    ...?_roots?.map(
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
            if (_selectedRootChildren.isNotEmpty)
              SizedBox(
                height: _subRowHeight,
                child: ChipTheme(
                  data: _chipTheme.copyWith(
                    backgroundColor: AppColors.elevated.withValues(alpha: 0.45),
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

  Widget _body() {
    final c = controller;
    if (c == null) return const AppLoadingView();
    if (c.items.isEmpty && c.loading) return const AppLoadingView();
    if (c.items.isEmpty && c.error != null) {
      return AppErrorView(
        message: c.error!,
        onRetry: c.refresh,
        secondaryLabel: '切换来源',
        secondaryAction: () => SourceSelectorSheet.show(context),
      );
    }
    if (c.items.isEmpty) return const AppEmptyView(message: '暂时没有内容');
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event is ScrollStartNotification) {
          // 手势起点决定本次是否可触发刷新：开始时头部未展开的，
          // 这次拉动只用于展开头部，想刷新需松手后再拉一次。
          _refreshArmed = _headerCollapse.value == 0;
        } else if (event is ScrollUpdateNotification) {
          // 手势滚动优先：打断进行中的吸附动画，折叠量实时跟随。
          if (_snap.isAnimating) _snap.stop();
          final pixels = event.metrics.pixels;
          final next = (_headerCollapse.value + pixels - _lastScrollPixels)
              .clamp(0.0, _headerHeight)
              .toDouble();
          _lastScrollPixels = pixels;
          if (next != _headerCollapse.value) _headerCollapse.value = next;
        } else if (event is OverscrollNotification) {
          // 列表已到顶后的下拉（overscroll）优先用于展开头部；
          // 头部完全展开后 RefreshIndicator 才允许接管触发刷新。
          if (event.overscroll < 0 &&
              event.metrics.extentBefore <= 0 &&
              _headerCollapse.value > 0) {
            if (_snap.isAnimating) _snap.stop();
            _headerCollapse.value = (_headerCollapse.value + event.overscroll)
                .clamp(0.0, _headerHeight)
                .toDouble();
          }
        } else if (event is ScrollEndNotification) {
          _snapHeader();
        }
        // 滚动超过约一屏后显示"返回顶部"悬浮按钮。
        final showTop = event.metrics.pixels > 600;
        if (showTop != _showBackToTop.value) _showBackToTop.value = showTop;
        if (event.metrics.extentAfter < 400) c.loadMore();
        return false;
      },
      child: RefreshIndicator(
        // 双重门槛：本次手势开始时头部已展开（[_refreshArmed]），
        // 且当前头部保持完全展开，才允许触发下拉刷新。
        notificationPredicate: (notification) =>
            notification.depth == 0 &&
            _refreshArmed &&
            _headerCollapse.value == 0,
        onRefresh: c.refresh,
        child: VideoGrid(
          videos: c.items,
          onTap: _open,
          topPadding: _gridTopPadding,
          bottomPadding: 96,
          controller: _scrollController,
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
}
