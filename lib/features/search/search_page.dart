import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_preferences.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/video.dart';
import '../../domain/vod_source.dart';
import '../../shared/video_grid.dart';
import '../detail/detail_page.dart';
import './multi_source_search_controller.dart';

class SearchPage extends ConsumerStatefulWidget {
  /// 外部传入的焦点节点：搜索页在 IndexedStack 中预建但默认隐藏，
  /// 不能用 autofocus（会在启动时抢焦点弹键盘），由 AppShell 在
  /// 切换到搜索 tab 后延时 requestFocus。
  const SearchPage({super.key, this.focusNode});

  final FocusNode? focusNode;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final input = TextEditingController();
  MultiSourceSearchController? controller;
  Timer? debounce;
  String? _globalSourceId;
  ProviderSubscription<AsyncValue<VodSource>>? _globalSourceSub;

  @override
  void initState() {
    super.initState();
    // 在 listener 中同步全局切源，避免在 build 期间 notifyListeners
    // 触发 "setState() called during build"。
    _globalSourceSub = ref.listenManual(selectedVodSourceProvider, (
      previous,
      next,
    ) {
      final source = next.maybeWhen(data: (s) => s, orElse: () => null);
      if (source == null) return;
      _onGlobalSourceChanged(source);
    });
  }

  @override
  void dispose() {
    _globalSourceSub?.close();
    debounce?.cancel();
    input.dispose();
    controller?.dispose();
    super.dispose();
  }

  void _ensureController() {
    if (controller != null) return;
    final registry = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (registry == null) return;
    final globalSource = ref
        .read(selectedVodSourceProvider)
        .maybeWhen(data: (s) => s, orElse: () => null);
    if (globalSource == null) return;
    controller = MultiSourceSearchController(
      repository: ref.read(videoRepositoryProvider),
      globalSource: globalSource,
      allSources: registry.searchableSources,
    )..addListener(_onChanged);
  }

  void _onGlobalSourceChanged(VodSource source) {
    if (_globalSourceId == source.id) return;
    _globalSourceId = source.id;
    final current = controller;
    if (current == null) return;
    current.onGlobalSourceChanged(source);
    current.resetToGlobalSource();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onInputChanged(String value) {
    setState(() {});
    debounce?.cancel();
    if (value.trim().isEmpty) {
      controller?.clear();
      return;
    }
    controller?.search(value);
  }

  void _clear() {
    input.clear();
    controller?.clear();
    setState(() {});
  }

  void _open(Video video) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => VideoDetailPage(video: video)));

  @override
  Widget build(BuildContext context) {
    final sourceState = ref.watch(selectedVodSourceProvider);
    return SafeArea(
      // bottom: false：让结果网格延伸到底部毛玻璃导航栏下方透出。
      bottom: false,
      child: sourceState.when(
        loading: () => const AppLoadingView(label: '正在加载来源…'),
        error: (error, _) => AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(selectedVodSourceProvider),
        ),
        data: (source) {
          // 初始值同步：后续全局切源由 initState 中的 listener 处理。
          _globalSourceId ??= source.id;
          _ensureController();
          if (controller == null) return const AppLoadingView();
          return _buildContent();
        },
      ),
    );
  }

  Widget _buildContent() => Padding(
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
          focusNode: widget.focusNode,
          onChanged: _onInputChanged,
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
        const SizedBox(height: 8),
        if (controller!.state.keyword.isNotEmpty) _sourceLabelBar(),
        const SizedBox(height: 4),
        Expanded(child: _body()),
      ],
    ),
  );

  Widget _sourceLabelBar() {
    final state = controller!.state;
    final registry = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (registry == null) return const SizedBox.shrink();
    final activeId = state.activeSourceId;
    final backupIds = state.sources.keys
        .where((id) => id != activeId && state.sources[id]?.queried == true)
        .take(3)
        .toList();
    final labels = <Widget>[];

    labels.add(
      _sourceChip(
        id: activeId,
        name: registry.findById(activeId)?.name ?? activeId,
        state: state.sources[activeId],
        isActive: true,
        onTap: () {},
      ),
    );

    for (final id in backupIds) {
      labels.add(
        _sourceChip(
          id: id,
          name: registry.findById(id)?.name ?? id,
          state: state.sources[id],
          isActive: false,
          onTap: () => controller!.switchSource(id),
        ),
      );
    }

    labels.add(
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ActionChip(
          label: const Text('更多 ▾'),
          onPressed: () => _showMoreSources(),
        ),
      ),
    );

    return SizedBox(
      height: 40,
      child: ListView(scrollDirection: Axis.horizontal, children: labels),
    );
  }

  Widget _sourceChip({
    required String id,
    required String name,
    required SourceSearchState? state,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final count = formatSourceCount(state);
    final isLoading = state?.loading == true;
    final hasError = state?.error != null;
    final label = '$name $count';
    final color = hasError
        ? AppColors.error
        : isActive
        ? AppColors.accent
        : AppColors.secondary;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          isLoading && state?.items.isEmpty == true ? '$name …' : label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? AppColors.onAccent : color,
          ),
        ),
        selected: isActive,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  void _showMoreSources() {
    final current = controller;
    if (current == null) return;
    final registry = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (registry == null) return;
    final allSearchable = registry.searchableSources;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => AnimatedBuilder(
        animation: current,
        builder: (_, _) {
          final state = current.state;
          return _MoreSourcesSheet(
            sources: allSearchable,
            states: state.sources,
            activeSourceId: state.activeSourceId,
            onSourceTap: (sourceId) {
              Navigator.pop(context);
              current.switchSource(sourceId);
            },
            onSearchAll: () {
              Navigator.pop(context);
              _confirmSearchAll(current, allSearchable.length);
            },
          );
        },
      ),
    );
  }

  /// 与详情页 _detectAll 保持一致的流量确认：来源超过 6 个时先提示。
  Future<void> _confirmSearchAll(
    MultiSourceSearchController controller,
    int count,
  ) async {
    if (count > 6) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('查找全部来源'),
          content: Text('将向全部 $count 个来源发起请求，可能产生额外流量。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    unawaited(controller.searchAllSources());
  }

  Widget _body() {
    final state = controller!.state;
    if (state.keyword.isEmpty) {
      return const AppEmptyView(icon: Icons.search, message: '输入片名开始搜索');
    }
    final activeState = state.sources[state.activeSourceId];
    if (activeState == null ||
        (activeState.items.isEmpty && activeState.loading)) {
      return const AppLoadingView(label: '正在搜索…');
    }
    if (activeState.items.isEmpty && activeState.error != null) {
      return AppErrorView(
        message: activeState.error!,
        onRetry: controller!.refresh,
      );
    }
    if (activeState.items.isEmpty) {
      return const AppEmptyView(
        icon: Icons.search_off,
        message: '没有找到结果，换个关键词或来源试试',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.metrics.extentAfter < 400) controller!.loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: controller!.refresh,
        child: VideoGrid(
          videos: activeState.items,
          onTap: _open,
          bottomPadding: activeState.loading ? 168 : 96,
        ),
      ),
    );
  }
}

class _MoreSourcesSheet extends StatelessWidget {
  const _MoreSourcesSheet({
    required this.sources,
    required this.states,
    required this.activeSourceId,
    required this.onSourceTap,
    required this.onSearchAll,
  });

  final List<VodSource> sources;
  final Map<String, SourceSearchState> states;
  final String activeSourceId;
  final ValueChanged<String> onSourceTap;
  final VoidCallback onSearchAll;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  const Text(
                    '全部来源',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onSearchAll,
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('查找全部来源'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: sources.length,
                itemBuilder: (_, index) {
                  final source = sources[index];
                  final s = states[source.id];
                  final isActive = source.id == activeSourceId;
                  String status;
                  if (s == null || !s.queried) {
                    status = '未搜索';
                  } else if (s.error != null) {
                    status = '请求失败';
                  } else if (s.total != null) {
                    status = '${s.total} 条';
                  } else if (s.items.isEmpty) {
                    status = '0 条';
                  } else if (s.hasMore) {
                    status = '${s.items.length}+ 条';
                  } else {
                    status = '有结果';
                  }
                  return ListTile(
                    leading: Icon(
                      isActive ? Icons.check_circle : Icons.source_outlined,
                      color: isActive ? AppColors.accent : AppColors.tertiary,
                    ),
                    title: Text(source.name),
                    subtitle: Text(
                      status,
                      style: TextStyle(
                        fontSize: 13,
                        color: s?.error != null
                            ? AppColors.error
                            : AppColors.secondary,
                      ),
                    ),
                    trailing: s?.loading == true
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: () => onSourceTap(source.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
