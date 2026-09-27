import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/content/category_nav.dart';
import '../../data/content/content_filter_policy.dart';
import '../../data/content/cross_source_search_service.dart';
import '../../data/content/my_channels_store.dart';
import '../../data/catalog/tmdb_catalog_repository.dart';
import '../../data/history_repository.dart';
import '../../data/library_repository.dart';
import '../../data/recommendation/recommendation_repository.dart';
import '../../data/recommendation/recommendation_client.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_preferences.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/video.dart';
import '../../domain/video_feed.dart';
import '../../domain/video_search_target.dart';
import '../../domain/tmdb_catalog.dart';
import '../../domain/vod_source.dart';
import '../../shared/app_toast.dart';
import '../../shared/source_selector.dart';
import '../../shared/video_grid.dart';
import '../../shared/video_card.dart';
import '../detail/detail_page.dart';
import '../search/search_launch_request.dart';
import './category_channels_page.dart';
import './widgets/continue_watching_row.dart';
import './controllers/curated_feed_controller.dart';
import './support/curated_vod_search_pool.dart';
import './support/home_scroll_memory.dart';
import './controllers/paged_video_controller.dart';
import './controllers/recommended_feed_controller.dart';
import './widgets/home_back_to_top_button.dart';
import './widgets/home_category_header.dart';
import './widgets/home_curated_body.dart';
import './widgets/home_recommended_body.dart';
import './widgets/home_state_scroll_view.dart';
import './widgets/home_unavailable_dialog.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, this.active});

  final ValueListenable<bool>? active;
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _productEnabledFeeds = [
    VideoFeed.updated,
    VideoFeed.recommended,
    VideoFeed.newReleases,
    VideoFeed.popular,
    VideoFeed.topRated,
  ];

  PagedVideoController? controller;
  CuratedFeedController? curatedController;
  RecommendedFeedController? recommendedController;
  VideoFeed _selectedFeed = VideoFeed.updated;
  TmdbCatalogScope _catalogScope = TmdbCatalogScope.all;

  /// 顶级分类（tab 栏）与按父 id 分组的子分类（横滑栏）。
  /// MacCMS 的内容只挂在叶子分类上，所以两级导航：
  /// 选中顶级分类后展示其子分类，实际查询使用叶子分类 id。
  List<VideoCategory>? _roots;
  Map<int, List<VideoCategory>> _children = {};
  int? _selectedRootId;
  int? selectedCategoryId;
  final Map<int, int> _lastSelectedLeafByRoot = {};
  String? categoryError;
  String? _activeSourceFingerprint;
  String? _activeSourceId;

  /// 「我的频道」：主 tab 行展示的根分类 id 及顺序，按源持久化；
  /// null 表示未定制，展示全部根分类。
  List<int>? _myChannelIds;

  /// Feed/榜单分类分别保留滚动位置；切换 VOD 分类或来源时仍回到顶部。
  final _scrollMemory = FeedScrollMemory();
  final _categoryHeaderCollapsed = ValueNotifier<bool>(false);
  bool _categoryPanelExpanded = false;
  bool _channelsPageOpen = false;
  VodSource? _currentSource;
  final Map<VideoFeed, GlobalKey> _feedTabKeys = {
    for (final feed in VideoFeed.values)
      feed: GlobalKey(debugLabel: 'home-feed-${feed.name}'),
  };
  final Map<int, GlobalKey> _leafTabKeys = {};
  final Set<String> _crossSourceSearchingIds = {};
  final CuratedVodSearchPool _curatedSearchPool = CuratedVodSearchPool();

  @override
  void initState() {
    super.initState();
    widget.active?.addListener(_handleAppTabVisibility);
  }

  void _handleAppTabVisibility() {
    recommendedController?.setViewActive(
      (widget.active?.value ?? true) && _selectedFeed == VideoFeed.recommended,
    );
  }

  @override
  void dispose() {
    widget.active?.removeListener(_handleAppTabVisibility);
    controller?.removeListener(_changed);
    controller?.dispose();
    curatedController?.removeListener(_changed);
    curatedController?.dispose();
    recommendedController?.removeListener(_changed);
    recommendedController?.dispose();
    _curatedSearchPool.close();
    _scrollMemory.dispose();
    _categoryHeaderCollapsed.dispose();
    super.dispose();
  }

  void _setCategoryHeaderCollapsed(bool collapsed) {
    if (!mounted || _categoryHeaderCollapsed.value == collapsed) return;
    _categoryHeaderCollapsed.value = collapsed;
    if (!collapsed) _closeCategoryPanel();
  }

  Future<void> _expandCategoryPanel() async {
    final source = _currentSource;
    if (!_categoryHeaderCollapsed.value ||
        _categoryPanelExpanded ||
        source == null) {
      return;
    }
    _categoryPanelExpanded = true;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '收起分类',
      barrierColor: Colors.black.withValues(alpha: 0.16),
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.05),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (dialogContext, _, _) => _categoryPanelOverlayView(source),
    );
    _categoryPanelExpanded = false;
  }

  void _closeCategoryPanel() {
    if (!_categoryPanelExpanded || !mounted) return;
    _categoryPanelExpanded = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      final effectiveScope = curatedController?.scope;
      if (effectiveScope != null && effectiveScope != _catalogScope) {
        _catalogScope = effectiveScope;
      }
    });
  }

  String _feedScrollKey(VodSource source) => _selectedFeed == VideoFeed.updated
      ? '${source.id}|${_selectedFeed.name}|${selectedCategoryId ?? ''}'
      : _selectedFeed == VideoFeed.recommended
      ? '${source.id}|${_selectedFeed.name}'
      : '${source.id}|${_selectedFeed.name}|${_catalogScope.name}';

  void _ensureController(VodSource source) {
    final sourceFingerprint = curatedVodSourceFingerprint(source);
    if (controller != null && _activeSourceFingerprint == sourceFingerprint) {
      return;
    }
    final retainedRecommendation = recommendedController;
    if (_activeSourceId == source.id &&
        _activeSourceFingerprint != null &&
        _activeSourceFingerprint != sourceFingerprint) {
      _curatedSearchPool.evictSource(_activeSourceFingerprint!);
    }
    _closeCategoryPanel();
    _scrollMemory.resetAfterBuild();
    _scrollMemory.clear();
    controller?.removeListener(_changed);
    controller?.dispose();
    curatedController?.removeListener(_changed);
    curatedController?.dispose();
    controller = PagedVideoController(ref.read(videoRepositoryProvider), source)
      ..addListener(_changed);
    curatedController = CuratedFeedController(
      catalogRepository: ref.read(tmdbCatalogRepositoryProvider),
      videoRepository: ref.read(videoRepositoryProvider),
      source: source,
      feed:
          _selectedFeed == VideoFeed.updated ||
              _selectedFeed == VideoFeed.recommended
          ? VideoFeed.newReleases
          : _selectedFeed,
      scope: _catalogScope,
      searchPool: _curatedSearchPool,
    )..addListener(_changed);
    if (retainedRecommendation == null) {
      recommendedController = RecommendedFeedController(
        recommendationRepository: ref.read(recommendationRepositoryProvider),
        videoRepository: ref.read(videoRepositoryProvider),
        source: source,
        searchPool: _curatedSearchPool,
      )..addListener(_changed);
    } else {
      recommendedController = retainedRecommendation;
      unawaited(
        retainedRecommendation.switchVodSource(source).then((_) {
          if (!mounted ||
              _activeSourceFingerprint != sourceFingerprint ||
              _selectedFeed != VideoFeed.recommended ||
              retainedRecommendation.hasLoadedState) {
            return;
          }
          unawaited(_loadRecommendations());
        }),
      );
    }
    _activeSourceFingerprint = sourceFingerprint;
    _activeSourceId = source.id;
    _roots = null;
    _children = {};
    _selectedRootId = null;
    selectedCategoryId = null;
    _lastSelectedLeafByRoot.clear();
    _leafTabKeys.clear();
    categoryError = null;
    _myChannelIds = null;
    if (_selectedFeed == VideoFeed.updated) {
      controller!.loadInitial();
    } else if (_selectedFeed == VideoFeed.recommended) {
      final recommendation = recommendedController!;
      recommendation.setViewActive(widget.active?.value ?? true);
      if (!recommendation.hasLoadedState) _loadRecommendations();
    } else {
      curatedController!.loadInitial();
    }
    _loadCategories(source);
  }

  Future<void> _loadCategories(VodSource source) async {
    setState(() => categoryError = null);
    final sourceFingerprint = curatedVodSourceFingerprint(source);
    bool isActive() => mounted && _activeSourceFingerprint == sourceFingerprint;
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

  /// 选中顶级分类：有子分类时直接展开页内横向子分类栏，并恢复该分类
  /// 上次选中的子分类；首次进入默认选择第一个可用子分类。
  /// 无子分类时直接按该分类查询。rootId 为 null 表示“全部”。
  Future<void> _selectRoot(VodSource source, int? rootId) async {
    final children = _children[rootId] ?? <VideoCategory>[];
    if (rootId != null && children.isNotEmpty) {
      final rememberedLeafId = _lastSelectedLeafByRoot[rootId];
      final leafId = children.any((child) => child.id == rememberedLeafId)
          ? rememberedLeafId!
          : children.first.id;
      await _selectRootLeaf(rootId, leafId);
      return;
    }
    _scrollMemory.reset();
    setState(() {
      _selectedRootId = rootId;
      selectedCategoryId = rootId;
    });
    await controller?.loadInitial(
      category: rootId,
      selectedFeed: controller?.feed,
    );
  }

  /// 直接选中子分类：同步所属主分类高亮并按子分类查询。
  Future<void> _selectRootLeaf(int rootId, int leafId) async {
    _closeCategoryPanel();
    _scrollMemory.reset();
    setState(() {
      _selectedRootId = rootId;
      selectedCategoryId = leafId;
      _lastSelectedLeafByRoot[rootId] = leafId;
    });
    _revealLeafTab(leafId);
    await controller?.loadInitial(
      category: leafId,
      selectedFeed: controller?.feed,
    );
  }

  Future<void> _selectFeed(VodSource source, VideoFeed feed) async {
    if (_selectedFeed == feed) return;
    if (feed != VideoFeed.updated && !source.search) {
      showAppToast(context, '当前来源不支持榜单资源检索');
      return;
    }
    _scrollMemory.savePosition(_feedScrollKey(source));
    final scrollTransition = _scrollMemory.beginTransition();
    if (_selectedFeed == VideoFeed.recommended) {
      recommendedController?.setViewActive(false);
    }
    setState(() => _selectedFeed = feed);
    _revealFeedTab(feed);
    if (feed == VideoFeed.updated) {
      await controller?.loadInitial(
        category: selectedCategoryId,
        selectedFeed: VideoFeed.updated,
      );
    } else if (feed == VideoFeed.recommended) {
      final recommendation = recommendedController;
      recommendation?.setViewActive(widget.active?.value ?? true);
      if (!(recommendation?.hasLoadedState ?? false)) {
        await _loadRecommendations();
      }
    } else {
      await curatedController?.selectFeed(feed);
    }
    if (mounted && _selectedFeed == feed) {
      _scrollMemory.finishTransition(
        scrollTransition,
        currentKey: () => _feedScrollKey(source),
      );
    }
  }

  void _revealFeedTab(VideoFeed feed) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tabContext = _feedTabKeys[feed]?.currentContext;
      if (tabContext == null) return;
      Scrollable.ensureVisible(
        tabContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _revealLeafTab(int leafId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tabContext = _leafTabKeys[leafId]?.currentContext;
      if (tabContext == null) return;
      Scrollable.ensureVisible(
        tabContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  List<VideoFeed> _visibleFeeds(VodSource source) {
    return [
      for (final feed in _productEnabledFeeds)
        if (feed != VideoFeed.recommended || source.search) feed,
    ];
  }

  Future<void> _loadRecommendations({bool forceRefresh = false}) async {
    final c = recommendedController;
    if (c == null) return;
    await c.loadInitial(
      history: ref.read(watchHistoryProvider).value ?? const [],
      library: ref.read(favoriteControllerProvider).value ?? const [],
      forceRefresh: forceRefresh,
    );
  }

  Future<void> _selectCatalogScope(
    VodSource source,
    TmdbCatalogScope scope,
  ) async {
    if (_catalogScope == scope) return;
    _scrollMemory.savePosition(_feedScrollKey(source));
    final scrollTransition = _scrollMemory.beginTransition();
    setState(() => _catalogScope = scope);
    await curatedController?.selectScope(scope);
    if (mounted && _catalogScope == scope) {
      _scrollMemory.finishTransition(
        scrollTransition,
        currentKey: () => _feedScrollKey(source),
      );
    }
  }

  /// 打开「全部频道」全屏页面：选择分类、管理我的频道（增删/拖拽排序）。
  Future<void> _openChannelsPage(VodSource source) async {
    final roots = _roots;
    if (roots == null || roots.isEmpty || _channelsPageOpen) return;
    _closeCategoryPanel();
    _channelsPageOpen = true;
    await Navigator.of(context).push(
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
    _channelsPageOpen = false;
  }

  /// 当前生效的「我的频道」id 列表（未定制时为全部根分类）。
  List<int> _currentMyChannelIds() =>
      _myChannelIds ??
      [for (final root in _roots ?? <VideoCategory>[]) root.id];

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
      ref.read(watchHistoryProvider).value ?? [],
    );
    if (current != null && current.video.globalId != video.globalId) {
      ref.read(continueWatchingSessionHiddenProvider.notifier).hide();
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));
  }

  /// 跨源查找公共骨架：登记进行中状态 → 逐个解析备用来源的严格匹配 →
  /// 命中即打开，未命中弹“未找到”提示。推荐流在此基础上附带上报事件。
  Future<void> _runCrossSourceSearch({
    required String trackingId,
    required VideoSearchTarget target,
    required VodSource currentSource,
    required String notFoundTitle,
    Future<void> Function()? beforeSearch,
    Future<void> Function()? onResolved,
  }) async {
    if (_crossSourceSearchingIds.contains(trackingId)) return;
    final registry = ref.read(vodSourceRegistryProvider).value;
    if (registry == null) {
      showAppToast(context, '来源列表尚未就绪');
      return;
    }
    setState(() => _crossSourceSearchingIds.add(trackingId));
    await beforeSearch?.call();
    final service = CrossSourceSearchService(
      repository: ref.read(videoRepositoryProvider),
      registry: registry,
    );
    final results = await service.search(
      target,
      excludedSourceId: currentSource.id,
      limit: 3,
    );
    Video? resolved;
    for (final result in results.where(
      (result) => result.status == CrossSourceSearchStatus.matched,
    )) {
      try {
        resolved = await service.resolve(result);
        break;
      } catch (_) {
        // 某一来源只有列表数据但无法解析播放时，继续尝试下一候选来源。
      }
    }
    if (!mounted) return;
    setState(() => _crossSourceSearchingIds.remove(trackingId));
    if (resolved != null) {
      await onResolved?.call();
      _open(resolved);
      return;
    }
    final failed = results
        .where(
          (result) => result.status == CrossSourceSearchStatus.requestFailed,
        )
        .length;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('未找到可播放资源'),
        content: Text(
          failed == results.length && results.isNotEmpty
              ? '备用来源本次均请求失败，请稍后重试。'
              : '已检索 ${results.length} 个备用来源，暂未找到可解析播放的《$notFoundTitle》。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _findAcrossSources(
    VodSource currentSource,
    TmdbCatalogItem item,
  ) => _runCrossSourceSearch(
    trackingId: item.globalId,
    target: VideoSearchTarget.fromCatalog(item),
    currentSource: currentSource,
    notFoundTitle: item.localizedTitle,
  );

  Future<void> _findRecommendationAcrossSources(
    VodSource currentSource,
    RecommendedCandidateSlot slot,
  ) {
    final candidate = slot.candidate;
    return _runCrossSourceSearch(
      trackingId: candidate.identity,
      target: candidate.searchTarget,
      currentSource: currentSource,
      notFoundTitle: candidate.title,
      beforeSearch: () async => recommendedController?.reportManualEvent(
        slot,
        RecommendationEventType.sourceSwitchOpened,
      ),
      onResolved: () async => recommendedController?.reportManualEvent(
        slot,
        RecommendationEventType.manualPlayableFound,
      ),
    );
  }

  Future<void> _handleUnavailableEntry(
    VodSource currentSource,
    CuratedFeedEntry entry,
  ) async {
    final item = entry.catalogItem;
    final query = entry.query.trim().isEmpty
        ? item.localizedTitle
        : entry.query.trim();
    final hasResults = entry.rawResultCount > 0;
    final candidates = entry.candidateTitles.take(3).join('、');
    final action = await showHomeUnavailableDialog(
      context,
      title: hasResults ? '当前来源有结果但无法确认' : '当前来源无结果',
      message: hasResults
          ? '使用“$query”在 ${currentSource.name} 搜索到 '
                '${entry.rawResultCount} 条结果，但自动匹配无法确认正确影片。'
                '${candidates.isEmpty ? '' : '\n候选：$candidates'}'
          : '使用“$query”在 ${currentSource.name} 未搜索到结果。'
                '你可以进入搜索页调整关键词，或继续查找 3 个备用源。',
      confirmLabel: hasResults ? '查看搜索结果' : '前往搜索页',
    );
    if (!mounted || action == null) return;
    switch (action) {
      case HomeUnavailableAction.reviewCurrentSource:
        ref
            .read(searchLaunchRequestProvider.notifier)
            .launch(
              keyword: query,
              sourceId: currentSource.id,
              mode: SearchLaunchMode.reviewCurrentSource,
            );
        return;
      case HomeUnavailableAction.searchBackups:
        await _findAcrossSources(currentSource, item);
        return;
    }
  }

  Future<void> _handleRecommendedUnavailable(
    VodSource currentSource,
    RecommendedCandidateSlot slot,
  ) async {
    final candidate = slot.candidate;
    final query = slot.query.trim().isEmpty
        ? candidate.title
        : slot.query.trim();
    final hasResults = slot.rawResultCount > 0;
    final searchFailed = slot.status == RecommendedCandidateStatus.failed;
    final candidates = slot.candidateTitles.take(3).join('、');
    final action = await showHomeUnavailableDialog(
      context,
      title: searchFailed
          ? '当前来源搜索失败'
          : hasResults
          ? '当前来源有结果但无法确认'
          : '当前来源无结果',
      message: searchFailed
          ? '使用“$query”搜索 ${currentSource.name} 时请求失败。'
                '你可以进入搜索页重试，或继续查找 3 个备用源。'
          : hasResults
          ? '使用“$query”在 ${currentSource.name} 搜索到 '
                '${slot.rawResultCount} 条结果，但自动匹配无法确认正确影片。'
                '${candidates.isEmpty ? '' : '\n候选：$candidates'}'
          : '使用“$query”在 ${currentSource.name} 未搜索到结果。'
                '你可以进入搜索页调整关键词，或继续查找 3 个备用源。',
      confirmLabel: hasResults && !searchFailed ? '查看搜索结果' : '前往搜索页',
    );
    if (!mounted || action == null) return;
    switch (action) {
      case HomeUnavailableAction.reviewCurrentSource:
        recommendedController?.reportManualEvent(
          slot,
          RecommendationEventType.manualSearchOpened,
        );
        ref
            .read(searchLaunchRequestProvider.notifier)
            .launch(
              keyword: query,
              sourceId: currentSource.id,
              mode: SearchLaunchMode.reviewCurrentSource,
            );
        return;
      case HomeUnavailableAction.searchBackups:
        await _findRecommendationAcrossSources(currentSource, slot);
        return;
    }
  }

  void _handleCuratedSlot(VodSource source, CuratedSearchSlot slot) {
    switch (slot.status) {
      case CuratedSlotStatus.available:
        final video = slot.matchedVideo;
        if (video != null) _open(video);
        return;
      case CuratedSlotStatus.queued:
        curatedController?.prioritizeSlot(slot.slotId);
        return;
      case CuratedSlotStatus.failed:
        curatedController?.retrySlot(slot.slotId);
        return;
      case CuratedSlotStatus.searching:
      case CuratedSlotStatus.unavailable:
      case CuratedSlotStatus.ambiguous:
      case CuratedSlotStatus.duplicate:
        _handleUnavailableEntry(
          source,
          CuratedFeedEntry(
            catalogItem: slot.catalogItem,
            matchedVideo: slot.matchedVideo,
            status: slot.status == CuratedSlotStatus.ambiguous
                ? CuratedMatchStatus.ambiguous
                : CuratedMatchStatus.notFound,
            rawResultCount: slot.rawResultCount,
            query: slot.query,
            candidateTitles: slot.candidateTitles,
          ),
        );
        return;
    }
  }

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
      _scrollMemory.resetAfterBuild();
      controller?.removeListener(_changed);
      controller?.dispose();
      curatedController?.removeListener(_changed);
      curatedController?.dispose();
      recommendedController?.removeListener(_changed);
      recommendedController?.dispose();
      _curatedSearchPool.clearAll();
      controller = null;
      curatedController = null;
      recommendedController = null;
      _activeSourceFingerprint = null;
      _activeSourceId = null;
      setState(() {});
    });
    final sourceState = ref.watch(selectedVodSourceProvider);
    return SafeArea(
      // bottom: false —— extendBody 会把底部导航栏高度计入 MediaQuery.padding，
      // 若此处消费掉，网格就无法延伸到毛玻璃导航栏下方。
      bottom: false,
      child: sourceState.when(
        loading: () => AppLoadingView(label: '正在加载来源…'),
        error: (error, _) => AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(selectedVodSourceProvider),
        ),
        data: (source) {
          _currentSource = source;
          _ensureController(source);
          return _buildContent(source);
        },
      ),
    );
  }

  Widget _buildContent(VodSource source) => Stack(
    children: [
      Positioned.fill(
        child: NotificationListener<ScrollNotification>(
          onNotification: _scrollMemory.trackLoadingInteraction,
          child: _body(source),
        ),
      ),
      Positioned(
        right: 16,
        bottom: 88,
        child: HomeBackToTopButton(
          showBackToTop: _scrollMemory.showBackToTop,
          onTap: _scrollMemory.scrollToTop,
        ),
      ),
    ],
  );

  Widget _categoryPanelOverlayView(VodSource source) {
    final metrics = HomeCategoryHeader.metricsOf(
      context: context,
      selectedFeed: _selectedFeed,
      selectedRootId: _selectedRootId,
      children: _children,
      visibleFeeds: _visibleFeeds(source),
    );
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        bottom: false,
        child: Column(
          key: const ValueKey('home-category-panel-overlay'),
          children: [
            Material(
              elevation: 8,
              shadowColor: Colors.black.withValues(alpha: 0.32),
              child: SizedBox(
                height: metrics.expandedHeight,
                child: _categoryHeader(
                  source,
                  metrics: metrics,
                  expandedOverlay: true,
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                key: const ValueKey('home-category-panel-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: _closeCategoryPanel,
                onVerticalDragStart: (_) => _closeCategoryPanel(),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _homeHeaderSlivers(VodSource source) {
    final visibleFeeds = _visibleFeeds(source);
    final metrics = HomeCategoryHeader.metricsOf(
      context: context,
      selectedFeed: _selectedFeed,
      selectedRootId: _selectedRootId,
      children: _children,
      visibleFeeds: visibleFeeds,
    );
    return [
      SliverToBoxAdapter(child: _introHeader()),
      SliverToBoxAdapter(child: ContinueWatchingSection()),
      SliverPersistentHeader(
        pinned: true,
        delegate: HomePinnedHeaderDelegate(
          minHeight: metrics.collapsedHeight,
          maxHeight: metrics.expandedHeight,
          onCollapsedChanged: _setCategoryHeaderCollapsed,
          child: _categoryHeader(source, metrics: metrics),
        ),
      ),
    ];
  }

  Widget _categoryHeader(
    VodSource source, {
    required HomeCategoryHeaderMetrics metrics,
    bool expandedOverlay = false,
  }) => HomeCategoryHeader(
    source: source,
    metrics: metrics,
    expandedOverlay: expandedOverlay,
    collapsed: _categoryHeaderCollapsed,
    leafTabKeys: _leafTabKeys,
    visibleFeeds: metrics.visibleFeeds,
    selectedFeed: _selectedFeed,
    catalogScope: _catalogScope,
    selectedRootId: _selectedRootId,
    selectedCategoryId: selectedCategoryId,
    children: _children,
    visibleRoots: _visibleRoots,
    categoryError: categoryError,
    feedTabKeys: _feedTabKeys,
    onSelectFeed: (feed) => _selectFeed(source, feed),
    onSelectCatalogScope: (scope) => _selectCatalogScope(source, scope),
    onSelectRoot: (rootId) => _selectRoot(source, rootId),
    onSelectRootLeaf: (rootId, leafId) => _selectRootLeaf(rootId, leafId),
    onLoadCategories: () => _loadCategories(source),
    onOpenChannelsPage: () => _openChannelsPage(source),
    onExpandPanel: _expandCategoryPanel,
    onCollapsePanel: _closeCategoryPanel,
  );

  Widget _introHeader() => Container(
    key: ValueKey('home-intro-header'),
    constraints: BoxConstraints(minHeight: 94),
    color: context.appColors.background.withValues(alpha: 0.55),
    padding: EdgeInsets.fromLTRB(16, 18, 8, 8),
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
                child: Text(
                  'Jive',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
              ),
              SizedBox(height: 4),
              Text(
                '今晚，看点好内容',
                style: TextStyle(
                  color: context.appColors.secondary,
                  fontSize: 15,
                ),
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
            child: Text('取消'),
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

  Widget _body(VodSource source) {
    if (_selectedFeed == VideoFeed.recommended) {
      return _recommendedBody(source);
    }
    if (_selectedFeed != VideoFeed.updated) return _curatedBody(source);
    final unreadUpdates = ref.watch(unreadFollowUpdatesByGlobalIdProvider);
    final c = controller;
    if (c == null) {
      return _loadingStateView(source);
    }
    if (c.items.isEmpty && c.loading) {
      return _loadingStateView(source);
    }
    if (c.items.isEmpty && c.error != null) {
      return homeStateScrollView(
        headerSlivers: _homeHeaderSlivers(source),
        controller: _scrollMemory.scrollController,
        state: AppErrorView(
          message: c.error!,
          onRetry: c.refresh,
          secondaryLabel: '切换来源',
          secondaryAction: () => SourceSelectorSheet.show(context),
        ),
      );
    }
    if (c.items.isEmpty) {
      return homeStateScrollView(
        headerSlivers: _homeHeaderSlivers(source),
        controller: _scrollMemory.scrollController,
        state: AppEmptyView(message: '暂时没有内容'),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        // 分类栏内的横向 ListView 也会上报滚动通知，只处理主网格。
        if (event.depth != 0 || event.metrics.axis != Axis.vertical) {
          return false;
        }
        // 滚动超过约一屏后显示"返回顶部"悬浮按钮。
        final showTop = event.metrics.pixels > 600;
        if (showTop != _scrollMemory.showBackToTop.value) {
          _scrollMemory.showBackToTop.value = showTop;
        }
        if (event.metrics.extentAfter < 400) c.loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: c.refresh,
        child: VideoGrid(
          videos: c.items,
          onTap: (video) {
            _open(video);
          },
          overlayBuilder: (video) {
            final added = unreadUpdates[video.globalId];
            return added == null
                ? null
                : VideoCardOverlay(badgeLabel: '新增$added集');
          },
          topPadding: 12,
          bottomPadding: 96,
          controller: _scrollMemory.scrollController,
          physics: AlwaysScrollableScrollPhysics(),
          headerSlivers: _homeHeaderSlivers(source),
          footer: c.loading
              ? Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : (!c.hasMore
                    ? Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text(
                            '没有更多了',
                            style: TextStyle(
                              color: context.appColors.tertiary,
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

  Widget _loadingStateView(VodSource source) => homeStateScrollView(
    headerSlivers: _homeHeaderSlivers(source),
    controller: _scrollMemory.scrollController,
    state: AppLoadingView(),
  );

  Widget _recommendedBody(VodSource source) {
    final c = recommendedController;
    if (c == null) return _loadingStateView(source);
    return HomeRecommendedBody(
      controller: c,
      source: source,
      headerSlivers: _homeHeaderSlivers(source),
      scrollController: _scrollMemory.scrollController,
      showBackToTop: _scrollMemory.showBackToTop,
      searchingIds: _crossSourceSearchingIds,
      onOpen: _open,
      onRefresh: () => _loadRecommendations(forceRefresh: true),
      onSlotUnavailable: (slot) => _handleRecommendedUnavailable(source, slot),
    );
  }

  Widget _curatedBody(VodSource source) {
    final c = curatedController;
    if (c == null) return _loadingStateView(source);
    return HomeCuratedBody(
      controller: c,
      source: source,
      headerSlivers: _homeHeaderSlivers(source),
      scrollController: _scrollMemory.scrollController,
      showBackToTop: _scrollMemory.showBackToTop,
      onOpen: _open,
      onRefresh: c.refresh,
      onSlotTap: (slot) => _handleCuratedSlot(source, slot),
    );
  }
}
