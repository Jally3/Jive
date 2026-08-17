import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/cache/cache_controller.dart';
import '../data/cache/cache_index.dart';
import '../data/cache/cache_manager.dart';

class CacheManagementPage extends ConsumerStatefulWidget {
  const CacheManagementPage({super.key});
  @override
  ConsumerState<CacheManagementPage> createState() =>
      _CacheManagementPageState();
}

class _CacheManagementPageState extends ConsumerState<CacheManagementPage> {
  bool _busy = false;

  Future<void> _clearAll() async {
    if (_busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空全部缓存？'),
        content: const Text('将删除所有已缓存的剧集片段，释放磁盘空间。当前正在播放的内容不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(cacheControllerProvider.notifier)
          .clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.failed > 0
                  ? '已清空 ${result.deleted} 项，${result.failed} 项失败'
                  : result.skippedActive > 0
                  ? '已清空 ${result.deleted} 项，${result.skippedActive} 项正在播放已跳过'
                  : '已清空全部缓存',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清理失败，请重试')));
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
        title: const Text('删除该缓存？'),
        content: Text('删除「${entry.episodeName}」的缓存片段。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('缓存管理')),
    body: ref
        .watch(cacheControllerProvider)
        .when(
          loading: () => const AppLoadingView(label: '正在统计缓存…'),
          error: (error, _) => AppErrorView(
            message: '缓存统计加载失败',
            onRetry: () => ref.invalidate(cacheControllerProvider),
          ),
          data: (stats) => _content(stats),
        ),
  );

  Widget _content(CacheStats stats) {
    if (stats.entries.isEmpty) {
      return const AppEmptyView(
        icon: Icons.cleaning_services_outlined,
        message: '还没有缓存\n播放或下载视频后片段会保存到这里',
      );
    }
    final used = stats.usedBytes;
    final quota = stats.quotaBytes;
    final fraction = quota > 0 ? (used / quota).clamp(0.0, 1.0) : 0.0;
    final grouped = _groupByTitle(stats.entries);
    return RefreshIndicator(
      onRefresh: () => ref.read(cacheControllerProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            color: AppColors.elevated,
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                              backgroundColor: AppColors.divider,
                              color: AppColors.accent,
                            ),
                            Text(
                              '${(fraction * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '已用 ${_formatBytes(used)} / ${_formatBytes(quota)}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Text(
                                  '自动',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.secondary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '完整资源 ${_formatBytes(stats.completeBytes)} · 临时文件 ${_formatBytes(stats.partialBytes)} · ${stats.entryCount} 个缓存剧集',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _clearAll,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('清理全部'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
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
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            dense: true,
            title: Text(
              group.$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${group.$2.length} 个剧集 · ${_formatBytes(used)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
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
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
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
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
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
                const SizedBox(height: 4),
                Text(
                  '$size$accessed',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.secondary,
                  ),
                ),
                if (showProgress) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: entry.progress.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: AppColors.divider,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: _busy ? null : () => _deleteEntry(entry),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }

  /// 条目状态标签与颜色：可离线 / 下载失败 / 部分缓存百分比。
  (String, Color) _entryStatus(CacheEntry entry) {
    if (entry.offlinePlayable) return ('可离线', AppColors.success);
    if (entry.status == CacheEntryStatus.failed) {
      return ('下载失败', AppColors.error);
    }
    return ('${(entry.progress * 100).round()}%', AppColors.accent);
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
