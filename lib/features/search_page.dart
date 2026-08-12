import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../shared/video_grid.dart';
import 'detail_page.dart';
import 'paged_video_controller.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final input = TextEditingController();
  late final PagedVideoController controller;
  Timer? debounce;
  bool searched = false;
  @override
  void initState() {
    super.initState();
    controller = PagedVideoController(ref.read(videoRepositoryProvider))
      ..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onChanged(String value) {
    setState(() {});
    debounce?.cancel();
    if (value.trim().isEmpty) {
      searched = false;
      controller.reset();
      return;
    }
    debounce = Timer(const Duration(milliseconds: 400), () {
      searched = true;
      controller.loadInitial(search: value.trim());
    });
  }

  void _clear() {
    input.clear();
    debounce?.cancel();
    searched = false;
    controller.reset();
  }

  @override
  void dispose() {
    debounce?.cancel();
    input.dispose();
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          const Text(
            '搜索',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '搜索视频',
              suffixIcon: input.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '清空',
                      onPressed: _clear,
                    ),
            ),
          ),
          const SizedBox(height: 12),
          if (controller.loading && controller.items.isNotEmpty)
            const LinearProgressIndicator(),
          Expanded(child: _body()),
        ],
      ),
    ),
  );

  Widget _body() {
    if (!searched) {
      return const AppEmptyView(icon: Icons.search, message: '输入片名开始搜索');
    }
    if (controller.items.isEmpty && controller.loading) {
      return const AppLoadingView(label: '正在搜索…');
    }
    if (controller.items.isEmpty && controller.error != null) {
      return AppErrorView(
        message: controller.error!,
        onRetry: controller.refresh,
      );
    }
    if (controller.items.isEmpty) {
      return const AppEmptyView(
        icon: Icons.search_off,
        message: '没有找到结果，换个关键词试试',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.metrics.extentAfter < 400) controller.loadMore();
        return false;
      },
      child: VideoGrid(
        videos: controller.items,
        onTap: (video) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)),
        ),
        bottomPadding: controller.loading ? 72 : 24,
      ),
    );
  }
}
