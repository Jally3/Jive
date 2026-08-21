import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/vod_source_preferences.dart';
import '../data/vod_source_registry.dart';
import '../domain/vod_source.dart';

class SourceSelectorSheet extends ConsumerStatefulWidget {
  const SourceSelectorSheet({super.key, this.selectedId});

  static const collectionTabLabel = '资源站';
  static const siteTabLabel = '高清站';
  static const siteTabHint = '画质更高、速度更快，但线路不一定稳定。失败时可切回资源站。';

  final String? selectedId;

  static Future<void> show(BuildContext context, {String? selectedId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SourceSelectorSheet(selectedId: selectedId),
    );
  }

  @override
  ConsumerState<SourceSelectorSheet> createState() =>
      _SourceSelectorSheetState();
}

class _SourceSelectorSheetState extends ConsumerState<SourceSelectorSheet> {
  /// 固定行高，保证初始滚动定位精确。
  static const double _itemExtent = 72;

  static bool _isPinnedSite(VodSource source) =>
      source.id == 'dbku' || source.name.contains('独播');

  final _collectionScroll = ScrollController();
  final _siteScroll = ScrollController();
  bool _didInitialScroll = false;

  @override
  void dispose() {
    _collectionScroll.dispose();
    _siteScroll.dispose();
    super.dispose();
  }

  void _scrollToSelected(ScrollController controller, int selectedIndex) {
    if (_didInitialScroll || selectedIndex < 0) return;
    _didInitialScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final position = controller.position;
      final target =
          selectedIndex * _itemExtent -
          (position.viewportDimension - _itemExtent) / 2;
      controller.jumpTo(target.clamp(0.0, position.maxScrollExtent).toDouble());
    });
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref
        .watch(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (registry == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final sources = registry.enabledSources;
    final collection = [
      for (final source in sources)
        if (!source.isSiteSource) source,
    ];
    final sites = [
      for (final source in sources)
        if (source.isSiteSource && _isPinnedSite(source)) source,
      for (final source in sources)
        if (source.isSiteSource && !_isPinnedSite(source)) source,
    ];
    final currentId =
        widget.selectedId ??
        ref
            .watch(selectedVodSourceProvider)
            .maybeWhen(data: (s) => s.id, orElse: () => null);
    final selectedIsSite = sites.any((source) => source.id == currentId);
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.58;
    return SafeArea(
      child: SizedBox(
        height: sheetHeight,
        child: DefaultTabController(
          length: 2,
          initialIndex: selectedIsSite ? 1 : 0,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    const Text(
                      '选择来源',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${SourceSelectorSheet.collectionTabLabel} ${collection.length} · ${SourceSelectorSheet.siteTabLabel} ${sites.length}',
                      style: const TextStyle(
                        color: AppColors.secondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const TabBar(
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.secondary,
                indicatorColor: AppColors.accent,
                tabs: [
                  Tab(text: SourceSelectorSheet.collectionTabLabel),
                  Tab(text: SourceSelectorSheet.siteTabLabel),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _sourceList(
                      key: const ValueKey('source-list-collection'),
                      sources: collection,
                      currentId: currentId,
                      controller: _collectionScroll,
                      emptyMessage: '暂时没有可用的资源站',
                    ),
                    Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 16,
                                color: AppColors.secondary,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  SourceSelectorSheet.siteTabHint,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.secondary,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _sourceList(
                            key: const ValueKey('source-list-sites'),
                            sources: sites,
                            currentId: currentId,
                            controller: _siteScroll,
                            emptyMessage: '暂时没有高清站',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceList({
    Key? key,
    required List<VodSource> sources,
    required String? currentId,
    required ScrollController controller,
    required String emptyMessage,
  }) {
    if (sources.isEmpty) {
      return AppEmptyView(message: emptyMessage);
    }
    _scrollToSelected(
      controller,
      sources.indexWhere((source) => source.id == currentId),
    );
    return ListView.builder(
      key: key,
      controller: controller,
      itemExtent: _itemExtent,
      itemCount: sources.length,
      itemBuilder: (_, index) {
        final source = sources[index];
        final isSelected = source.id == currentId;
        final subtitle = source.notification.isNotEmpty
            ? source.notification
            : source.baseUri.host;
        return ListTile(
          onTap: () {
            ref.read(selectedVodSourceProvider.notifier).select(source);
            Navigator.pop(context);
          },
          leading: Icon(
            isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isSelected ? AppColors.accent : AppColors.tertiary,
          ),
          title: Text(source.name),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: source.isHttps
                  ? AppColors.tertiary
                  : AppColors.error.withValues(alpha: .7),
            ),
          ),
          trailing: isSelected
              ? const Icon(Icons.chevron_right, size: 18)
              : null,
        );
      },
    );
  }
}

class SourceIndicatorButton extends ConsumerWidget {
  const SourceIndicatorButton({super.key, this.overrideSelectedId});

  final String? overrideSelectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceId =
        overrideSelectedId ??
        ref
            .watch(selectedVodSourceProvider)
            .maybeWhen(data: (s) => s.id, orElse: () => null);
    final registry = ref
        .watch(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    final name = registry?.findById(sourceId ?? '')?.name ?? sourceId ?? '加载中';
    return TextButton.icon(
      onPressed: () =>
          SourceSelectorSheet.show(context, selectedId: overrideSelectedId),
      icon: const Icon(Icons.source_outlined, size: 18),
      label: Text(
        '$name ▾',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
