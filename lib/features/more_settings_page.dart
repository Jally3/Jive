import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../data/cache/cache_controller.dart';
import '../data/cache/cache_ttl_policy.dart';
import '../data/cache/prefetch_policy.dart';
import 'cache_management_page.dart';

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final precision = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}

String _ttlLabel(CacheTtlOption option) => switch (option) {
  CacheTtlOption.off => '关闭',
  CacheTtlOption.days1 => '1 天',
  CacheTtlOption.days3 => '3 天',
  CacheTtlOption.days5 => '5 天',
  CacheTtlOption.days7 => '7 天',
  CacheTtlOption.days30 => '30 天',
};

Future<void> _selectTtl(
  BuildContext context,
  WidgetRef ref,
  CacheTtlOption current,
) async {
  final selected = await showModalBottomSheet<CacheTtlOption>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in CacheTtlOption.values)
            ListTile(
              title: Text(_ttlLabel(option)),
              trailing: option == current
                  ? const Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(sheetContext, option),
            ),
        ],
      ),
    ),
  );
  if (selected != null) {
    await ref.read(cacheTtlProvider.notifier).setOption(selected);
  }
}

class MoreSettingsPage extends ConsumerWidget {
  const MoreSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('更多设置')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _SettingsSection(
          title: '播放',
          children: [
            Consumer(
              builder: (context, ref, _) {
                final mode = ref.watch(prefetchModeProvider).value;
                final enabled = mode != PrefetchMode.off;
                return SwitchListTile(
                  secondary: const Icon(Icons.speed_outlined),
                  title: const Text('预加载'),
                  subtitle: Text(
                    enabled
                        ? '播放时提前缓存后续分片（Wi-Fi $prefetchWindowWifi 片 / 蜂窝 $prefetchWindowCellular 片）'
                        : '已关闭，播放时只缓存当前观看的分片',
                    style: const TextStyle(fontSize: 13),
                  ),
                  value: enabled,
                  onChanged: (value) => ref
                      .read(prefetchModeProvider.notifier)
                      .setMode(value ? PrefetchMode.auto : PrefetchMode.off),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsSection(
          title: '存储',
          children: [
            Consumer(
              builder: (context, ref, _) {
                final option =
                    ref.watch(cacheTtlProvider).value ?? CacheTtlOption.days3;
                return ListTile(
                  leading: const Icon(Icons.auto_delete_outlined),
                  title: const Text('自动清理缓存'),
                  subtitle: Text(
                    _ttlLabel(option),
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.tertiary,
                  ),
                  onTap: () => _selectTtl(context, ref, option),
                );
              },
            ),
            const Divider(height: 1, color: AppColors.divider),
            Consumer(
              builder: (context, ref, _) {
                final stats = ref.watch(cacheControllerProvider);
                final subtitle = stats.when(
                  data: (value) =>
                      '已用 ${_formatBytes(value.usedBytes)} / 配额 ${_formatBytes(value.quotaBytes)} · ${value.entryCount} 个缓存剧集',
                  loading: () => '正在统计…',
                  error: (_, _) => '缓存统计加载失败',
                );
                return ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('缓存管理'),
                  subtitle: Text(
                    subtitle,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.tertiary,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CacheManagementPage(),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          title,
          style: const TextStyle(color: AppColors.secondary, fontSize: 13),
        ),
      ),
      Card(
        color: AppColors.surface,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    ],
  );
}
