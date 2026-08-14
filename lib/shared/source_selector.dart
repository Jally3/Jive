import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../data/vod_source_preferences.dart';
import '../data/vod_source_registry.dart';

class SourceSelectorSheet extends ConsumerWidget {
  const SourceSelectorSheet({super.key, this.selectedId});

  final String? selectedId;

  static Future<void> show(BuildContext context, {String? selectedId}) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => SourceSelectorSheet(selectedId: selectedId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        selectedId ??
        ref
            .watch(selectedVodSourceProvider)
            .maybeWhen(data: (s) => s.id, orElse: () => null);
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
                shrinkWrap: true,
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
