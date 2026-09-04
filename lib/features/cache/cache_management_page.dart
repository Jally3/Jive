import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/cache/cache_controller.dart';
import '../../data/cache/cache_index.dart';
import '../../data/cache/cache_manager.dart';
import '../../shared/app_toast.dart';

class CacheManagementPage extends ConsumerStatefulWidget {
  const CacheManagementPage({super.key});
  @override
  ConsumerState<CacheManagementPage> createState() =>
      _CacheManagementPageState();
}

class _CacheManagementPageState extends ConsumerState<CacheManagementPage> {
  bool _busy = false;

  Future<void> _clearPlaybackCache() async {
    if (_busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('清理播放缓存？'),
        content: Text('将删除观看时自动保存的本地片段以释放空间。离线下载与正在播放的内容会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('清理'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(cacheControllerProvider.notifier)
          .clearPlaybackCache();
      if (mounted) {
        showAppToast(
          context,
          result.failed > 0
              ? '已清理 ${result.deleted} 项，${result.failed} 项失败'
              : result.skippedActive > 0
              ? '已清理 ${result.deleted} 项，${result.skippedActive} 项正在播放已跳过'
              : result.deleted > 0
              ? '已清理 ${result.deleted} 项播放缓存'
              : '没有可清理的播放缓存',
        );
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '清理失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteEntry(CacheEntry entry) async {
    if (_busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除该缓存？'),
        content: Text(
          entry.downloadOrigin
              ? '删除「${entry.episodeName}」的本地文件。下载任务仍在「下载」里，但本集将无法离线播放。'
              : '删除「${entry.episodeName}」观看时保存的片段，不影响下载列表。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('删除'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(cacheControllerProvider.notifier)
          .deleteEntry(entry.key);
      if (mounted) {
        final message = switch (result) {
          DeleteResult.deleted => '已删除',
          DeleteResult.blocked => '该缓存正在播放中，播放结束后可删除',
          DeleteResult.notFound => '缓存不存在',
          DeleteResult.failed => '删除失败，请重试',
        };
        showAppToast(context, message);
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '删除失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('缓存管理')),
    body: ref
        .watch(cacheControllerProvider)
        .when(
          loading: () => AppLoadingView(label: '正在统计缓存…'),
          error: (error, _) => AppErrorView(
            message: '缓存统计加载失败',
            onRetry: () => ref.invalidate(cacheControllerProvider),
          ),
          data: (stats) => _content(stats),
        ),
  );

  Widget _content(CacheStats stats) {
    if (stats.entries.isEmpty) {
      return AppEmptyView(
        icon: Icons.cleaning_services_outlined,
        message: '还没有播放缓存\n看过的片子会把片段留在这里，方便接着播。主动下载的任务在「下载」里。',
      );
    }
    final used = stats.usedBytes;
    final quota = stats.quotaBytes;
    final fraction = quota > 0 ? (used / quota).clamp(0.0, 1.0) : 0.0;
    final grouped = _groupByTitle(stats.entries);
    return RefreshIndicator(
      onRefresh: () => ref.read(cacheControllerProvider.notifier).refresh(),
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            color: context.appColors.elevated,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox.square(
                        dimension: 56,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: fraction,
                              strokeWidth: 6,
                              strokeCap: StrokeCap.round,
                              backgroundColor: context.appColors.divider,
                              color: context.appColors.accent,
                            ),
                            Text(
                              '${(fraction * 100).round()}%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '已用 ${_formatBytes(used)} / ${_formatBytes(quota)}',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              '观看时自动保存的片段，占满后会自动清理。离线下载请到「下载」。',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.appColors.secondary,
                                height: 1.4,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              '完整资源 ${_formatBytes(stats.completeBytes)} · 临时文件 ${_formatBytes(stats.partialBytes)} · ${stats.entryCount} 个剧集',
                              style: TextStyle(
                                fontSize: 12,
                                color: context.appColors.secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _clearPlaybackCache,
                      icon: Icon(Icons.delete_sweep_outlined),
                      label: Text('清理播放缓存'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 16),
          for (final group in grouped.entries)
            _groupCard((group.key, group.value)),
        ],
      ),
    );
  }

  Widget _groupCard((String title, List<CacheEntry> entries) group) {
    final used = group.$2.fold<int>(
      0,
      (sum, e) => sum + e.completeBytes + e.partialBytes,
    );
    return Card(
      color: context.appColors.surface,
      margin: EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            title: Text(
              group.$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${group.$2.length} 个剧集 · ${_formatBytes(used)}',
              style: TextStyle(fontSize: 12),
            ),
          ),
          Divider(height: 1, color: context.appColors.divider),
          for (final entry in group.$2) _entryTile(entry),
        ],
      ),
    );
  }

  Widget _entryTile(CacheEntry entry) {
    final size = _formatBytes(entry.completeBytes + entry.partialBytes);
    final accessed = entry.lastAccessMs > 0
        ? ' · ${_timeAgo(entry.lastAccessMs)}'
        : '';
    final (label, color) = _entryStatus(entry);
    final showProgress =
        !entry.offlinePlayable && entry.status != CacheEntryStatus.failed;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.episodeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                    SizedBox(width: 8),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Text(
                  '$size$accessed',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.appColors.secondary,
                  ),
                ),
                if (showProgress) ...[
                  SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: entry.progress.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: context.appColors.divider,
                      color: context.appColors.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: _busy ? null : () => _deleteEntry(entry),
            icon: Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }

  /// 条目状态：离线下载成片 / 观看缓存 / 缓存失败 / 部分缓存百分比。
  (String, Color) _entryStatus(CacheEntry entry) {
    if (entry.offlinePlayable) {
      return (entry.downloadOrigin ? '离线下载' : '已缓存', context.appColors.success);
    }
    if (entry.status == CacheEntryStatus.failed) {
      return ('缓存失败', context.appColors.error);
    }
    return (
      '${(entry.progress * 100).round()}%',
      context.appColors.accentForeground,
    );
  }

  static Map<String, List<CacheEntry>> _groupByTitle(List<CacheEntry> entries) {
    final map = <String, List<CacheEntry>>{};
    for (final entry in entries) {
      map.putIfAbsent(entry.title, () => []).add(entry);
    }
    return map;
  }

  static String _formatBytes(int bytes) {
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

  static String _timeAgo(int ms) {
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }
}
