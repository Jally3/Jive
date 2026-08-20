import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../data/vod_source_preferences.dart';
import '../data/vod_source_registry.dart';

class SourceSelectorSheet extends ConsumerStatefulWidget {
  const SourceSelectorSheet({super.key, this.selectedId});

  final String? selectedId;

  static Future<void> show(BuildContext context, {String? selectedId}) {
    return showModalBottomSheet<void>(
      context: context,
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

  final ScrollController _scrollController = ScrollController();
  bool _didInitialScroll = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected(int selectedIndex) {
    if (_didInitialScroll || selectedIndex < 0) return;
    _didInitialScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target =
          selectedIndex * _itemExtent -
          (position.viewportDimension - _itemExtent) / 2;
      _scrollController.jumpTo(
        target.clamp(0.0, position.maxScrollExtent).toDouble(),
      );
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
    final currentId =
        widget.selectedId ??
        ref
            .watch(selectedVodSourceProvider)
            .maybeWhen(data: (s) => s.id, orElse: () => null);
    _scrollToSelected(sources.indexWhere((s) => s.id == currentId));
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
                    '选择来源',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${sources.length} 个',
                    style: const TextStyle(
                      color: AppColors.secondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                controller: _scrollController,
                shrinkWrap: true,
                itemExtent: _itemExtent,
                itemCount: sources.length,
                itemBuilder: (_, index) {
                  final source = sources[index];
                  final isSelected = source.id == currentId;
                  return ListTile(
                    onTap: () {
                      ref
                          .read(selectedVodSourceProvider.notifier)
                          .select(source);
                      Navigator.pop(context);
                    },
                    leading: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected ? AppColors.accent : AppColors.tertiary,
                    ),
                    title: Text(source.name),
                    subtitle: Text(
                      source.baseUri.host,
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
              ),
            ),
          ],
        ),
      ),
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
