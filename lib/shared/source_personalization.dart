import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../data/vod_source/vod_source_customization_provider.dart';
import '../data/vod_source/vod_source_presentation.dart';
import '../data/vod_source/vod_source_health_provider.dart';
import '../domain/vod_source.dart';
import '../features/settings/source_edit_sheet.dart';
import 'app_anchored_menu.dart';
import 'app_toast.dart';

const vodCollectionTabLabel = '资源站';
const vodSiteTabLabel = '高清站';
const vodSiteTabHint = '画质更高、速度更快，但线路不一定稳定。失败时可切回资源站。';

/// Resolves aliases at the view boundary, without replacing source identity.
class SourceNameText extends ConsumerWidget {
  const SourceNameText({
    super.key,
    required this.source,
    this.format,
    this.style,
    this.maxLines,
    this.overflow,
  });
  final VodSource source;
  final String Function(String name)? format;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(vodSourceCustomizationsProvider).value;
    final alias = settings?.forSource(source.id).displayName ?? '';
    final name = alias.isEmpty ? source.name : alias;
    return Text(
      format?.call(name) ?? name,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

class PersonalizedSourceTile extends StatelessWidget {
  const PersonalizedSourceTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onSelect,
    this.status,
    this.onCheck,
    this.managing = false,
  });
  final VodSourcePresentation item;
  final bool selected;
  final VoidCallback? onSelect;
  final Widget? status;
  final VoidCallback? onCheck;
  final bool managing;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final subtitle = Text(
      item.subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, height: 16 / 12, color: colors.secondary),
    );
    return Semantics(
      selected: selected,
      child: Material(
        color: selected
            ? colors.accent.withValues(alpha: .08)
            : Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                height: 22 / 15,
                                fontWeight: FontWeight.w600,
                                color: colors.text,
                              ),
                            ),
                          ),
                          if (item.pinned) ...[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.push_pin,
                              size: 14,
                              color: colors.accentForeground,
                              semanticLabel: '已置顶',
                            ),
                          ],
                          if (selected) ...[
                            const SizedBox(width: 8),
                            Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 12,
                                height: 16 / 12,
                                fontWeight: FontWeight.w500,
                                color: colors.accentForeground,
                              ),
                            ),
                          ],
                          if (item.demoted) ...[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.vertical_align_bottom,
                              size: 14,
                              color: colors.secondary,
                              semanticLabel: '已置底',
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (status == null) return subtitle;
                          if (MediaQuery.textScalerOf(context).scale(12) > 18) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                subtitle,
                                const SizedBox(height: 4),
                                status!,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: subtitle),
                              const SizedBox(width: 12),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: constraints.maxWidth * .4,
                                ),
                                child: status!,
                              ),
                            ],
                          );
                        },
                      ),
                      if (item.customization.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final tag in item.customization.tags)
                                Text(
                                  tag.label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 16 / 12,
                                    color: colors.secondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (managing) ...[
                  const SizedBox(width: 4),
                  SourcePinButton(item: item),
                  SourceCustomizationMenu(item: item, onCheck: onCheck),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SourcePinButton extends ConsumerWidget {
  const SourcePinButton({super.key, required this.item});
  final VodSourcePresentation item;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: ValueKey('source-pin-${item.source.id}'),
    tooltip: '${item.pinned ? '取消置顶' : '置顶'}${item.name}',
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    padding: const EdgeInsets.all(12),
    icon: Icon(
      item.pinned ? Icons.push_pin : Icons.push_pin_outlined,
      size: 20,
      color: item.pinned
          ? context.appColors.accentForeground
          : context.appColors.secondary,
    ),
    onPressed: () async {
      try {
        await ref
            .read(vodSourceCustomizationsProvider.notifier)
            .togglePinned(item.source.id);
      } catch (_) {
        if (context.mounted) showAppToast(context, '保存失败，请重试');
      }
    },
  );
}

class SourceCustomizationMenu extends ConsumerWidget {
  const SourceCustomizationMenu({super.key, required this.item, this.onCheck});
  final VodSourcePresentation item;
  final VoidCallback? onCheck;

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    if (action == 'check') {
      onCheck?.call();
      return;
    }
    if (action == 'edit') {
      await SourceEditSheet.show(context, item.source, item.customization);
      return;
    }
    if (action == 'reset') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('恢复此源设置？'),
          content: const Text('清除显示名、标签、备注、置顶和置底，观看记录将保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    try {
      final notifier = ref.read(vodSourceCustomizationsProvider.notifier);
      if (action == 'bottom') {
        await notifier.toggleDemoted(item.source.id);
        if (context.mounted) {
          showAppToast(context, item.demoted ? '已取消置底' : '已置底');
        }
      } else {
        await notifier.reset(item.source.id);
      }
    } catch (_) {
      if (context.mounted) showAppToast(context, '保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Builder(
    builder: (anchorContext) => IconButton(
      key: ValueKey('source-menu-${item.source.id}'),
      tooltip: '${item.name}更多操作',
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: const EdgeInsets.all(12),
      icon: Icon(
        Icons.more_horiz,
        size: 20,
        color: context.appColors.secondary,
      ),
      onPressed: () async {
        final action = await showAppAnchoredMenu<String>(
          anchorContext: anchorContext,
          width: 220,
          builder: (menuContext) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in [
                  (
                    'bottom',
                    item.demoted ? '取消置底' : '置底',
                    Icons.vertical_align_bottom,
                  ),
                  ('edit', '编辑', Icons.edit_outlined),
                  if (onCheck != null) ('check', '检测', Icons.network_check),
                  ('reset', '恢复此源设置', Icons.restore),
                ])
                  ListTile(
                    minTileHeight: 44,
                    visualDensity: VisualDensity.standard,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    minLeadingWidth: 20,
                    horizontalTitleGap: 12,
                    leading: Icon(entry.$3, size: 20),
                    title: Text(entry.$2, style: const TextStyle(fontSize: 13)),
                    onTap: () => Navigator.pop(menuContext, entry.$1),
                  ),
              ],
            ),
          ),
        );
        if (action != null && context.mounted) {
          await _act(context, ref, action);
        }
      },
    ),
  );
}

class SourceHealthIndicator extends StatelessWidget {
  const SourceHealthIndicator({super.key, this.health, this.checking = false});
  final SourceHealth? health;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final result = health;
    final time = result?.checkedAt;
    String two(int value) => value.toString().padLeft(2, '0');
    final timestamp = time == null
        ? ''
        : '${time.month}-${time.day} ${two(time.hour)}:${two(time.minute)}';
    final description = checking
        ? '正在检测来源可用性'
        : result == null
        ? '尚未检测'
        : result.ok
        ? '上次检测：成功 · ${result.latencyMs}ms · $timestamp'
        : '上次检测：失败 · ${result.message ?? '未知错误'} · $timestamp';
    return Tooltip(
      message: description,
      excludeFromSemantics: true,
      child: Semantics(
        label: description,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (checking) ...[
              const SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                checking
                    ? '检测中'
                    : result == null
                    ? '尚未检测'
                    : result.ok
                    ? '${result.latencyMs} ms'
                    : '检测失败',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 16 / 12,
                  color: checking || result == null
                      ? context.appColors.secondary
                      : result.ok
                      ? context.appColors.success
                      : context.appColors.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
