import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../domain/video.dart';
import '../shared/video_grid.dart';
import 'detail_page.dart';
import 'paged_video_controller.dart';

class CategoryPage extends ConsumerStatefulWidget {
  const CategoryPage({super.key, this.initialCategoryId});
  final int? initialCategoryId;
  @override
  ConsumerState<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends ConsumerState<CategoryPage> {
  late final PagedVideoController controller;
  List<VideoCategory>? categories;
  VideoCategory? selected;
  String? categoryError;
  @override
  void initState() {
    super.initState();
    controller = PagedVideoController(ref.read(videoRepositoryProvider))
      ..addListener(_changed);
    _loadCategories();
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
      setState(() {
        categories = roots.isEmpty ? all : roots;
        selected =
            categories!
                .where((item) => item.id == widget.initialCategoryId)
                .firstOrNull ??
            categories!.firstOrNull;
      });
      await controller.loadInitial(category: selected?.id);
    } catch (e) {
      if (mounted) setState(() => categoryError = e.toString());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _select(VideoCategory value) async {
    setState(() => selected = value);
    await controller.loadInitial(category: value.id);
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text(
            '分类',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
        ),
        if (categories != null)
          SizedBox(
            height: 44,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: categories!.length,
              itemBuilder: (_, i) {
                final item = categories![i];
                final active = selected?.id == item.id;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(item.name),
                    selected: active,
                    onSelected: (_) => _select(item),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 8),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _body() {
    if (categories == null && categoryError == null) {
      return const AppLoadingView(label: '正在加载分类…');
    }
    if (categoryError != null) {
      return AppErrorView(message: categoryError!, onRetry: _loadCategories);
    }
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
      return const AppEmptyView(message: '该分类暂时没有内容');
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
          onTap: (video) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)),
          ),
          bottomPadding: controller.loading ? 72 : 24,
        ),
      ),
    );
  }
}
