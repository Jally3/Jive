import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../data/cache/cache_controller.dart';
import '../../data/cache/cache_ttl_policy.dart';
import '../../data/download/download_network_policy.dart';
import '../../data/playback/prefetch_policy.dart';
import '../../data/theme_mode_preferences.dart';
import '../cache/cache_management_page.dart';

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
  CacheTtlOption.never => '不自动清理',
  CacheTtlOption.onExit => '退出播放时清理',
  CacheTtlOption.hours1 => '1 小时后',
  CacheTtlOption.hours5 => '5 小时后',
  CacheTtlOption.days1 => '1 天后',
  CacheTtlOption.days3 => '3 天后',
  CacheTtlOption.days7 => '7 天后',
};

String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '日间模式',
  ThemeMode.dark => '夜间模式',
};

Future<void> _selectThemeMode(
  BuildContext context,
  WidgetRef ref,
  ThemeMode current,
) async {
  final selected = await showModalBottomSheet<ThemeMode>(
    context: context,
    constraints: BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in ThemeMode.values)
            ListTile(
              leading: Icon(switch (mode) {
                ThemeMode.system => Icons.brightness_auto_outlined,
                ThemeMode.light => Icons.light_mode_outlined,
                ThemeMode.dark => Icons.dark_mode_outlined,
              }),
              title: Text(_themeModeLabel(mode)),
              trailing: mode == current
                  ? Icon(Icons.check, color: context.appColors.accentForeground)
                  : null,
              onTap: () => Navigator.pop(sheetContext, mode),
            ),
        ],
      ),
    ),
  );
  if (selected != null) {
    await ref.read(themeModeProvider.notifier).setMode(selected);
  }
}

Future<void> _selectTtl(
  BuildContext context,
  WidgetRef ref,
  CacheTtlOption current,
) async {
  final selected = await showModalBottomSheet<CacheTtlOption>(
    context: context,
    // 宽屏（电视/平板横屏）下收敛宽度居中。
    constraints: BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in CacheTtlOption.values)
              ListTile(
                title: Text(_ttlLabel(option)),
                trailing: option == current
                    ? Icon(
                        Icons.check,
                        color: context.appColors.accentForeground,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        ),
      ),
    ),
  );
  if (selected != null) {
    await ref.read(cacheTtlProvider.notifier).setOption(selected);
  }
}

Future<bool> _confirmCellularDownloads(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('允许蜂窝网络下载？'),
        content: Text('下载视频可能消耗较多移动数据。开启后，其他正在等待 Wi-Fi 的任务也会继续。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('允许'),
          ),
        ],
      ),
    ) ??
    false;

class MoreSettingsPage extends ConsumerStatefulWidget {
  const MoreSettingsPage({super.key});

  @override
  ConsumerState<MoreSettingsPage> createState() => _MoreSettingsPageState();
}

class _MoreSettingsPageState extends ConsumerState<MoreSettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(cacheControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('更多设置')),
    body: ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _SettingsSection(
          title: '外观',
          children: [
            Consumer(
              builder: (context, ref, _) {
                final mode = ref.watch(themeModeProvider);
                return ListTile(
                  leading: Icon(Icons.palette_outlined),
                  title: Text('主题模式'),
                  subtitle: Text(
                    _themeModeLabel(mode),
                    style: TextStyle(fontSize: 13),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: context.appColors.tertiary,
                  ),
                  onTap: () => _selectThemeMode(context, ref, mode),
                );
              },
            ),
          ],
        ),
        SizedBox(height: 16),
        _SettingsSection(
          title: '播放',
          children: [
            Consumer(
              builder: (context, ref, _) {
                final mode = ref.watch(prefetchModeProvider).value;
                final enabled = mode != PrefetchMode.off;
                return SwitchListTile(
                  secondary: Icon(Icons.speed_outlined),
                  title: Text('预加载'),
                  subtitle: Text(
                    enabled
                        ? '播放时提前缓存后续内容（Wi-Fi ${prefetchAheadWifi.inMinutes} 分钟 / 蜂窝 ${prefetchAheadCellular.inMinutes} 分钟）'
                        : '已关闭，播放时只缓存当前观看的分片',
                    style: TextStyle(fontSize: 13),
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
        SizedBox(height: 16),
        _SettingsSection(
          title: '下载',
          children: [
            Consumer(
              builder: (context, ref, _) {
                final preference = ref.watch(allowCellularDownloadsProvider);
                final allowed = preference.value ?? false;
                return SwitchListTile(
                  secondary: Icon(Icons.cell_tower_outlined),
                  title: Text('允许蜂窝网络下载'),
                  subtitle: Text(
                    allowed ? '已允许使用移动数据，可能产生流量费用' : '仅在 Wi-Fi 或有线网络下下载',
                    style: TextStyle(fontSize: 13),
                  ),
                  value: allowed,
                  onChanged: preference.isLoading
                      ? null
                      : (value) async {
                          if (value &&
                              !await _confirmCellularDownloads(context)) {
                            return;
                          }
                          await ref
                              .read(allowCellularDownloadsProvider.notifier)
                              .setAllowed(value);
                        },
                );
              },
            ),
          ],
        ),
        SizedBox(height: 16),
        _SettingsSection(
          title: '存储',
          children: [
            Consumer(
              builder: (context, ref, _) {
                final option =
                    ref.watch(cacheTtlProvider).value ?? CacheTtlOption.onExit;
                return ListTile(
                  leading: Icon(Icons.auto_delete_outlined),
                  title: Text('自动清理缓存'),
                  subtitle: Text(
                    _ttlLabel(option),
                    style: TextStyle(fontSize: 13),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: context.appColors.tertiary,
                  ),
                  onTap: () => _selectTtl(context, ref, option),
                );
              },
            ),
            Divider(height: 1, color: context.appColors.divider),
            Consumer(
              builder: (context, ref, _) {
                final stats = ref.watch(cacheControllerProvider);
                final subtitle = stats.when(
                  data: (value) {
                    final playback = value.playback;
                    return '已用 ${_formatBytes(playback.usedBytes)} / 配额 ${_formatBytes(playback.quotaBytes)} · ${playback.entryCount} 个剧集';
                  },
                  loading: () => '正在统计播放缓存…',
                  error: (_, _) => '播放缓存统计加载失败',
                );
                return ListTile(
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('播放缓存'),
                  subtitle: Text(subtitle, style: TextStyle(fontSize: 13)),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: context.appColors.tertiary,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => CacheManagementPage()),
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
        padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          title,
          style: TextStyle(color: context.appColors.secondary, fontSize: 13),
        ),
      ),
      Card(
        color: context.appColors.surface,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    ],
  );
}
