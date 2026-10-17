import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../data/vod_source/vod_source_customization_provider.dart';
import '../data/vod_source/vod_source_preferences.dart';
import '../data/vod_source/vod_source_registry.dart';
import '../data/vod_source/vod_source_presentation.dart';
import '../data/vod_source/vod_source_health_provider.dart';
import '../domain/vod_source.dart';
import '../domain/vod_source_customization.dart';
import 'app_states.dart';
import 'app_toast.dart';
import 'source_personalization.dart';

class SourceSelectorSheet extends StatelessWidget {
  const SourceSelectorSheet({super.key, this.selectedId});

  static const collectionTabLabel = vodCollectionTabLabel;
  static const siteTabLabel = vodSiteTabLabel;
  static const siteTabHint = vodSiteTabHint;
  final String? selectedId;

  static Future<void> show(BuildContext context, {String? selectedId}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 600),
        builder: (_) => SourceSelectorSheet(selectedId: selectedId),
      );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: SourcePanel(selectedId: selectedId),
    ),
  );
}

/// Both entry points use the same mode, filters, source actions and health state.
class SourcePanel extends ConsumerStatefulWidget {
  const SourcePanel({super.key, this.selectedId, this.isPage = false});
  final String? selectedId;
  final bool isPage;

  @override
  ConsumerState<SourcePanel> createState() => _SourcePanelState();
}

class _SourcePanelState extends ConsumerState<SourcePanel> {
  final _collectionScroll = ScrollController();
  final _siteScroll = ScrollController();
  final _selectedKey = GlobalKey();
  bool _didInitialScroll = false;
  late bool _managing;
  VodContentTag? _tag;

  void _revealTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final controller in [_collectionScroll, _siteScroll]) {
        if (controller.hasClients) controller.jumpTo(0);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _managing = widget.isPage;
    _didInitialScroll = widget.isPage;
  }

  @override
  void dispose() {
    _collectionScroll.dispose();
    _siteScroll.dispose();
    super.dispose();
  }

  void _filter(VodContentTag? tag) {
    setState(() {
      _tag = tag;
      _didInitialScroll = true;
    });
    _revealTop();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(vodSourceCustomizationsProvider, (previous, next) {
      final oldPins = previous?.value?.pinnedSourceIds;
      final pins = next.value?.pinnedSourceIds;
      if (oldPins != null && pins != null && !listEquals(oldPins, pins)) {
        _didInitialScroll = true;
        _revealTop();
      }
    });
    final registry = ref.watch(vodSourceRegistryProvider);
    final settings = ref.watch(vodSourceCustomizationsProvider);
    final globalSourceId = ref.watch(selectedVodSourceProvider).value?.id;
    return Column(
      children: [
        _header(),
        Expanded(
          child: registry.when(
            loading: () => const AppLoadingView(label: '正在加载来源…'),
            error: (_, _) => AppErrorView(
              message: '来源加载失败',
              onRetry: () => ref.invalidate(vodSourceRegistryProvider),
            ),
            data: (registry) => settings.when(
              loading: () => const AppLoadingView(label: '正在加载来源设置…'),
              error: (_, _) => AppErrorView(
                message: '来源设置加载失败',
                onRetry: () => ref.invalidate(vodSourceCustomizationsProvider),
              ),
              data: (settings) {
                final sources = registry.enabledSources;
                // If the last annotation was removed, do not retain a hidden filter.
                final hasTags = sources.any(
                  (s) => settings.forSource(s.id).tags.isNotEmpty,
                );
                if (!hasTags) _tag = null;
                final tag = _tag;
                final items = presentVodSources(sources, settings, tag: tag);
                final collection = items
                    .where((s) => !s.source.isSiteSource)
                    .toList();
                final sites = items
                    .where((s) => s.source.isSiteSource)
                    .toList();
                final currentId = widget.selectedId ?? globalSourceId;
                final selectedIsSite =
                    registry.findById(currentId ?? '')?.isSiteSource ?? false;
                return DefaultTabController(
                  length: 2,
                  initialIndex: selectedIsSite ? 1 : 0,
                  child: Column(
                    children: [
                      if (_managing) _managementToolbar(sources),
                      if (hasTags) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '按我的标签筛选',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: const Text('全部'),
                                  showCheckmark: false,
                                  selected: tag == null,
                                  onSelected: (_) => _filter(null),
                                ),
                              ),
                              for (final option in VodContentTag.values)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    key: ValueKey('source-tag-${option.name}'),
                                    showCheckmark: false,
                                    label: Text(option.label),
                                    selected: tag == option,
                                    onSelected: (_) => _filter(option),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      TabBar(
                        labelStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                        labelColor: context.appColors.accentForeground,
                        indicatorColor: context.appColors.accentForeground,
                        tabs: [
                          Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Flexible(
                                  child: Text(
                                    vodCollectionTabLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  ' ${collection.length}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Flexible(
                                  child: Text(
                                    vodSiteTabLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  ' ${sites.length}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _sourceList(
                              key: const ValueKey('source-list-collection'),
                              items: collection,
                              currentId: currentId,
                              controller: _collectionScroll,
                              tag: tag,
                              settings: settings,
                            ),
                            Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    4,
                                  ),
                                  child: Text(
                                    vodSiteTabHint,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.appColors.secondary,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: _sourceList(
                                    key: const ValueKey('source-list-sites'),
                                    items: sites,
                                    currentId: currentId,
                                    controller: _siteScroll,
                                    tag: tag,
                                    settings: settings,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _header() => Padding(
    padding: EdgeInsets.fromLTRB(widget.isPage ? 4 : 16, 4, 8, 4),
    child: Row(
      children: [
        if (widget.isPage) const BackButton(),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              _managing || widget.isPage ? '来源管理' : '选择来源',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
          onPressed: () => setState(() => _managing = !_managing),
          child: Text(_managing ? '完成' : '管理'),
        ),
      ],
    ),
  );

  Widget _sourceList({
    required Key key,
    required List<VodSourcePresentation> items,
    required String? currentId,
    required ScrollController controller,
    required VodContentTag? tag,
    required VodSourceCustomizations settings,
  }) {
    final showMissing =
        _managing &&
        tag == null &&
        key == const ValueKey('source-list-collection');
    if (items.isEmpty &&
        showMissing &&
        _missingSourceIds(settings).isNotEmpty) {
      return SingleChildScrollView(
        key: key,
        controller: controller,
        child: Column(
          children: [
            const SizedBox(
              height: 180,
              child: AppEmptyView(message: '暂时没有可用的来源'),
            ),
            _missingSettings(settings),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: AppEmptyView(
              message: tag == null ? '暂时没有可用的来源' : '这里还没有标记为${tag.label}的来源',
            ),
          ),
          if (tag != null)
            TextButton(
              onPressed: () => _filter(null),
              child: const Text('显示全部'),
            ),
        ],
      );
    }
    if (!_didInitialScroll && items.any((s) => s.source.id == currentId)) {
      _didInitialScroll = true;
      if (!items.any((s) => s.pinned)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final selectedContext = _selectedKey.currentContext;
          if (mounted && selectedContext != null) {
            Scrollable.ensureVisible(selectedContext, alignment: .5);
          }
        });
      }
    }
    // A source directory is small. Eager layout allows precise positioning with
    // variable-height notes/tags and text scaling, without guessing row heights.
    return SingleChildScrollView(
      key: key,
      controller: controller,
      child: Column(
        children: [
          for (final item in items) ...[
            PersonalizedSourceTile(
              key: widget.isPage
                  ? ValueKey('managed-source-${item.source.id}')
                  : item.source.id == currentId
                  ? _selectedKey
                  : ValueKey('source-row-${item.source.id}'),
              item: item,
              selected: item.source.id == currentId,
              managing: _managing,
              status: _managing
                  ? SourceHealthIndicator(
                      health: ref
                          .watch(vodSourceHealthProvider)
                          .value
                          ?.results[item.source.id],
                      checking:
                          ref
                              .watch(vodSourceHealthProvider)
                              .value
                              ?.checking
                              .contains(item.source.id) ??
                          false,
                    )
                  : null,
              onCheck:
                  ref
                          .watch(vodSourceHealthProvider)
                          .value
                          ?.checking
                          .contains(item.source.id) ==
                      true
                  ? null
                  : () => _check(item.source),
              onSelect: _managing
                  ? null
                  : () async {
                      final route = ModalRoute.of(context);
                      try {
                        await ref
                            .read(selectedVodSourceProvider.notifier)
                            .select(item.source);
                        if (mounted && route?.isCurrent == true) {
                          if (widget.isPage) {
                            showAppToast(context, '当前来源已切换');
                          } else {
                            Navigator.pop(context);
                          }
                        }
                      } catch (_) {
                        if (mounted) showAppToast(context, '来源切换失败，请重试');
                      }
                    },
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
          ],
          if (showMissing) _missingSettings(settings),
        ],
      ),
    );
  }

  Widget _managementToolbar(List<VodSource> sources) {
    final checking =
        ref.watch(vodSourceHealthProvider).value?.checking.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '管理中 · 点击图钉置顶',
              style: TextStyle(
                fontSize: 12,
                color: context.appColors.secondary,
              ),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            onPressed: checking || sources.isEmpty
                ? null
                : () async {
                    try {
                      await ref
                          .read(vodSourceHealthProvider.notifier)
                          .checkAll(sources);
                    } catch (_) {
                      if (mounted) showAppToast(context, '检测记录保存失败，请重试');
                    }
                  },
            icon: const Icon(Icons.network_check, size: 18),
            label: Text(
              checking ? '检测中…' : '检测全部',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _check(VodSource source) async {
    try {
      await ref.read(vodSourceHealthProvider.notifier).check(source);
    } catch (_) {
      if (mounted) showAppToast(context, '检测记录保存失败，请重试');
    }
  }

  List<String> _missingSourceIds(VodSourceCustomizations settings) {
    final registry = ref.read(vodSourceRegistryProvider).value!;
    return {
      ...settings.sources.keys,
      ...settings.pinnedSourceIds,
      ...settings.demotedSourceIds,
    }.where((id) => registry.findById(id) == null).toList();
  }

  Widget _missingSettings(VodSourceCustomizations settings) {
    final missing = _missingSourceIds(settings);
    if (missing.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      title: Text(
        '已不可用的个性化来源（${missing.length}）',
        style: const TextStyle(fontSize: 13),
      ),
      children: [
        for (final id in missing)
          ListTile(
            title: Text(
              settings.forSource(id).displayName.isEmpty
                  ? id
                  : settings.forSource(id).displayName,
            ),
            subtitle: const Text('来源目录中已不存在，个人设置仍保留'),
            trailing: TextButton(
              onPressed: () => _clearMissing(id),
              child: const Text('清除'),
            ),
          ),
      ],
    );
  }

  Future<void> _clearMissing(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除个人设置？'),
        content: const Text('仅清除此不可用来源的显示名、标签、备注、置顶和置底。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(vodSourceCustomizationsProvider.notifier).reset(id);
    } catch (_) {
      if (mounted) showAppToast(context, '保存失败，请重试');
    }
  }
}

class SourceIndicatorButton extends ConsumerWidget {
  const SourceIndicatorButton({super.key, this.overrideSelectedId});
  final String? overrideSelectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceId =
        overrideSelectedId ?? ref.watch(selectedVodSourceProvider).value?.id;
    final registry = ref.watch(vodSourceRegistryProvider).value;
    final source = registry?.findById(sourceId ?? '');
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width * .45).clamp(80.0, 240.0),
      ),
      child: TextButton.icon(
        key: const ValueKey('source-indicator-button'),
        onPressed: () =>
            SourceSelectorSheet.show(context, selectedId: overrideSelectedId),
        style: TextButton.styleFrom(
          foregroundColor: context.appColors.secondary,
        ),
        icon: const Icon(Icons.source_outlined, size: 16),
        label: source == null
            ? Text(sourceId ?? '加载中')
            : SourceNameText(
                source: source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                format: (name) => '$name ▾',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
      ),
    );
  }
}
