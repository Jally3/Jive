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

class _HomePageState extends ConsumerState<HomePage> {
  PagedVideoController? controller;
  List<VideoCategory>? categories;
  int? selectedCategoryId;
  String? categoryError;
  String? _activeSourceId;

  @override
  void dispose() {
    controller?.removeListener(_changed);
    controller?.dispose();
    super.dispose();
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
    selectedCategoryId = null;
    categories = null;
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
      final featured = source.featuredCategoryIds;
      final roots = featured.isEmpty
          ? all.where((item) => item.parentId == 0).toList()
          : all
                .where(
                  (item) => item.parentId == 0 && featured.contains(item.id),
                )
                .toList();
      if (!isActive()) return;
      setState(() => categories = roots.isEmpty ? all : roots);
    } catch (e) {
      if (isActive()) setState(() => categoryError = e.toString());
    }
  }

  Future<void> _select(VodSource source, int? categoryId) async {
    setState(() => selectedCategoryId = categoryId);
    await controller?.loadInitial(category: categoryId);
  }

  void _open(Video video) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));

  @override
  Widget build(BuildContext context) {
    final sourceState = ref.watch(selectedVodSourceProvider);
    return SafeArea(
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

  Widget _buildContent(VodSource source) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Jive',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
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
            const Icon(
              Icons.local_movies_outlined,
              color: AppColors.accent,
              size: 32,
            ),
          ],
        ),
      ),
      SizedBox(
        height: 44,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          scrollDirection: Axis.horizontal,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: const Text('最新'),
                selected: selectedCategoryId == null,
                showCheckmark: false,
                onSelected: (_) => _select(source, null),
              ),
            ),
            ...?categories?.map(
              (item) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(item.name),
                  selected: selectedCategoryId == item.id,
                  showCheckmark: false,
                  onSelected: (_) => _select(source, item.id),
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
      const SizedBox(height: 8),
      Expanded(child: _body()),
    ],
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
        if (event.metrics.extentAfter < 400) c.loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: c.refresh,
        child: VideoGrid(
          videos: c.items,
          onTap: _open,
          bottomPadding: c.loading ? 72 : 24,
        ),
      ),
    );
  }
}
