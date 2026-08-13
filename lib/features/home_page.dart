import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../domain/video.dart';
import '../shared/video_grid.dart';
import 'detail_page.dart';
import 'paged_video_controller.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late final PagedVideoController controller;
  List<VideoCategory>? categories;
  int? selectedCategoryId;
  String? categoryError;

  @override
  void initState() {
    super.initState();
    controller = PagedVideoController(ref.read(videoRepositoryProvider))
      ..addListener(_changed);
    controller.loadInitial();
    _loadCategories();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCategories() async {
    setState(() => categoryError = null);
    try {
      final all = await ref.read(videoRepositoryProvider).fetchCategories();
      const allowed = {20, 30, 39, 45, 51, 52, 53, 58};
      final roots = all
          .where((item) => item.parentId == 0 && allowed.contains(item.id))
          .toList();
      if (!mounted) return;
      setState(() => categories = roots.isEmpty ? all : roots);
    } catch (e) {
      if (mounted) setState(() => categoryError = e.toString());
    }
  }

  Future<void> _select(int? categoryId) async {
    setState(() => selectedCategoryId = categoryId);
    await controller.loadInitial(category: categoryId);
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  void _open(Video video) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Row(
            children: [
              Expanded(
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
              Icon(
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
                  onSelected: (_) => _select(null),
                ),
              ),
              ...?categories?.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(item.name),
                    selected: selectedCategoryId == item.id,
                    onSelected: (_) => _select(item.id),
                  ),
                ),
              ),
              if (categoryError != null)
                ActionChip(label: const Text('重试'), onPressed: _loadCategories),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _body() {
    if (controller.items.isEmpty && controller.loading) {
      return const AppLoadingView();
    }
    if (controller.items.isEmpty && controller.error != null) {
      return AppErrorView(
        message: controller.error!,
        onRetry: controller.refresh,
      );
    }
    if (controller.items.isEmpty) {
      return const AppEmptyView(message: '暂时没有内容');
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.metrics.extentAfter < 400) controller.loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: controller.refresh,
        child: VideoGrid(
          videos: controller.items,
          onTap: _open,
          bottomPadding: controller.loading ? 72 : 24,
        ),
      ),
    );
  }
}
