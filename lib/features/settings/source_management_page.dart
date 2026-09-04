import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_preferences.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/vod_source.dart';
import '../../shared/app_toast.dart';
import '../../shared/source_selector.dart';

const _healthKeyPrefix = 'source_health_';
const _checkTimeout = Duration(seconds: 8);

class SourceHealth {
  SourceHealth({
    required this.ok,
    required this.latencyMs,
    required this.checkedAt,
    this.message,
  });

  factory SourceHealth.fromJson(Map<String, dynamic> json) => SourceHealth(
    ok: json['ok'] == true,
    latencyMs: json['latencyMs'] is int ? json['latencyMs'] as int : 0,
    checkedAt:
        DateTime.tryParse('${json['checkedAt'] ?? ''}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    message: json['message'] as String?,
  );

  final bool ok;
  final int latencyMs;
  final DateTime checkedAt;
  final String? message;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'latencyMs': latencyMs,
    'checkedAt': checkedAt.toIso8601String(),
    if (message != null) 'message': message,
  };
}

class SourceManagementPage extends ConsumerStatefulWidget {
  const SourceManagementPage({super.key});
  @override
  ConsumerState<SourceManagementPage> createState() =>
      _SourceManagementPageState();
}

class _SourceManagementPageState extends ConsumerState<SourceManagementPage> {
  final Map<String, SourceHealth> _health = {};
  final Set<String> _checking = {};

  @override
  void initState() {
    super.initState();
    _loadHealth();
  }

  Future<void> _loadHealth() async {
    final prefs = await SharedPreferences.getInstance();
    final loaded = <String, SourceHealth>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_healthKeyPrefix)) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        loaded[key.substring(_healthKeyPrefix.length)] = SourceHealth.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        // 忽略损坏的历史检测结果
      }
    }
    if (mounted && loaded.isNotEmpty) {
      setState(() => _health.addAll(loaded));
    }
  }

  Future<void> _check(VodSource source) async {
    if (_checking.contains(source.id)) return;
    setState(() => _checking.add(source.id));
    final stopwatch = Stopwatch()..start();
    SourceHealth health;
    try {
      await ref
          .read(videoRepositoryProvider)
          .fetchPage(source)
          .timeout(_checkTimeout);
      health = SourceHealth(
        ok: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      health = SourceHealth(
        ok: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
        message: e.toString(),
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_healthKeyPrefix${source.id}',
      jsonEncode(health.toJson()),
    );
    if (!mounted) return;
    setState(() {
      _checking.remove(source.id);
      _health[source.id] = health;
    });
  }

  Future<void> _checkAll(List<VodSource> sources) =>
      Future.wait(sources.map(_check));

  Future<void> _setDefault(VodSource source) async {
    await ref.read(selectedVodSourceProvider.notifier).select(source);
    if (!mounted) return;
    showAppToast(context, '默认来源已改为：${source.name}');
  }

  @override
  Widget build(BuildContext context) {
    final registryState = ref.watch(vodSourceRegistryProvider);
    final selectedId = ref
        .watch(selectedVodSourceProvider)
        .maybeWhen(data: (source) => source.id, orElse: () => null);
    return Scaffold(
      appBar: AppBar(title: Text('来源管理')),
      body: registryState.when(
        loading: () => AppLoadingView(label: '正在加载来源…'),
        error: (error, _) => AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(vodSourceRegistryProvider),
        ),
        data: (registry) {
          final sources = registry.enabledSources;
          // 与首页选源一致：资源站/高清站两个 tab，高清站中置顶源排前。
          final collection = [
            for (final source in sources)
              if (!source.isSiteSource) source,
          ];
          final sites = [
            for (final source in sources)
              if (source.isSiteSource &&
                  SourceSelectorSheet.isPinnedSite(source))
                source,
            for (final source in sources)
              if (source.isSiteSource &&
                  !SourceSelectorSheet.isPinnedSite(source))
                source,
          ];
          final selectedIsSite = sites.any((s) => s.id == selectedId);
          return DefaultTabController(
            length: 2,
            initialIndex: selectedIsSite ? 1 : 0,
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${SourceSelectorSheet.collectionTabLabel} ${collection.length} · '
                          '${SourceSelectorSheet.siteTabLabel} ${sites.length}，点击可设为默认',
                          style: TextStyle(
                            color: context.appColors.secondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _checking.isNotEmpty
                            ? null
                            : () => _checkAll(sources),
                        icon: Icon(Icons.network_check, size: 18),
                        label: Text('检测全部'),
                      ),
                    ],
                  ),
                ),
                TabBar(
                  labelColor: context.appColors.accentForeground,
                  unselectedLabelColor: context.appColors.secondary,
                  indicatorColor: context.appColors.accentForeground,
                  tabs: [
                    Tab(text: SourceSelectorSheet.collectionTabLabel),
                    Tab(text: SourceSelectorSheet.siteTabLabel),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _sourceList(collection, selectedId, '暂时没有可用的资源站'),
                      Column(
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 16,
                                  color: context.appColors.secondary,
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    SourceSelectorSheet.siteTabHint,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.appColors.secondary,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: _sourceList(sites, selectedId, '暂时没有高清站'),
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
    );
  }

  Widget _sourceList(
    List<VodSource> sources,
    String? selectedId,
    String emptyMessage,
  ) {
    if (sources.isEmpty) return AppEmptyView(message: emptyMessage);
    return ListView.separated(
      itemCount: sources.length,
      separatorBuilder: (_, _) => Divider(height: 1),
      itemBuilder: (_, index) =>
          _sourceTile(sources[index], sources[index].id == selectedId),
    );
  }

  Widget _sourceTile(VodSource source, bool isDefault) {
    final health = _health[source.id];
    final checking = _checking.contains(source.id);
    return ListTile(
      onTap: isDefault ? null : () => _setDefault(source),
      leading: Icon(
        isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
        color: isDefault
            ? context.appColors.accentForeground
            : context.appColors.tertiary,
      ),
      title: Row(
        children: [
          Flexible(child: Text(source.name, overflow: TextOverflow.ellipsis)),
          if (isDefault) ...[
            SizedBox(width: 8),
            Text(
              '默认',
              style: TextStyle(
                color: context.appColors.accentForeground,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              source.baseUri.host,
              if (source.search) '可搜索' else '不可搜索',
              if (source.notification.isNotEmpty) source.notification,
            ].join(' · '),
            style: TextStyle(fontSize: 12, color: context.appColors.secondary),
          ),
          if (health != null)
            Text(
              _healthText(health),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: health.ok
                    ? context.appColors.accentForeground
                    : context.appColors.error,
              ),
            )
          else
            Text(
              '尚未检测',
              style: TextStyle(fontSize: 12, color: context.appColors.tertiary),
            ),
        ],
      ),
      trailing: checking
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(onPressed: () => _check(source), child: Text('检测')),
    );
  }

  String _healthText(SourceHealth health) {
    final time = _formatTime(health.checkedAt);
    if (health.ok) return '上次检测：成功 · ${health.latencyMs}ms · $time';
    return '上次检测：失败 · ${health.message ?? '未知错误'} · $time';
  }

  String _formatTime(DateTime value) {
    String two(int part) => part.toString().padLeft(2, '0');
    return '${value.month}-${value.day} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
