import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../domain/video.dart';
import '../shared/video_card.dart';
import 'detail_page.dart';
import 'paged_video_controller.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.onCategorySelected});
  final ValueChanged<int> onCategorySelected;
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late final PagedVideoController controller;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    controller = PagedVideoController(ref.read(videoRepositoryProvider))
      ..addListener(_changed);
    scroll.addListener(_scrolled);
    controller.loadInitial();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _scrolled() {
    if (scroll.position.extentAfter < 500) controller.loadMore();
  }

  @override
  void dispose() {
    scroll.dispose();
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  void _open(Video video) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));

  @override
  Widget build(BuildContext context) => SafeArea(
    child: RefreshIndicator(
      onRefresh: controller.refresh,
      child: CustomScrollView(
        controller: scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
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
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _HomeChip(
                          label: '电影',
                          onTap: () => widget.onCategorySelected(20),
                        ),
                        _HomeChip(
                          label: '连续剧',
                          onTap: () => widget.onCategorySelected(30),
                        ),
                        _HomeChip(
                          label: '动漫',
                          onTap: () => widget.onCategorySelected(39),
                        ),
                        _HomeChip(
                          label: '综艺',
                          onTap: () => widget.onCategorySelected(45),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '最新内容',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          if (controller.items.isEmpty && controller.loading)
            const SliverFillRemaining(child: AppLoadingView())
          else if (controller.items.isEmpty && controller.error != null)
            SliverFillRemaining(
              child: AppErrorView(
                message: controller.error!,
                onRetry: controller.refresh,
              ),
            )
          else if (controller.items.isEmpty)
            const SliverFillRemaining(child: AppEmptyView(message: '暂时没有内容'))
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              sliver: SliverGrid.builder(
                itemCount: controller.items.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: MediaQuery.sizeOf(context).width >= 700
                      ? 4
                      : 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 20,
                  childAspectRatio: .52,
                ),
                itemBuilder: (_, i) => VideoCard(
                  video: controller.items[i],
                  onTap: () => _open(controller.items[i]),
                ),
              ),
            ),
            SliverToBoxAdapter(child: _LoadFooter(controller: controller)),
          ],
        ],
      ),
    ),
  );
}

class _HomeChip extends StatelessWidget {
  const _HomeChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ActionChip(label: Text(label), onPressed: onTap),
  );
}

class _LoadFooter extends StatelessWidget {
  const _LoadFooter({required this.controller});
  final PagedVideoController controller;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: Center(
      child: controller.loading
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : controller.error != null
          ? TextButton(
              onPressed: controller.loadMore,
              child: const Text('加载失败，点击重试'),
            )
          : !controller.hasMore
          ? const Text('已经到底了', style: TextStyle(color: AppColors.tertiary))
          : null,
    ),
  );
}
