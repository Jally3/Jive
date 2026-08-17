import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../data/vod_source_preferences.dart';
import '../data/vod_source_registry.dart';
import '../domain/vod_source.dart';
import '../shared/app_snack_bar.dart';

const _healthKeyPrefix = 'source_health_';
const _checkTimeout = Duration(seconds: 8);

class SourceHealth {
  const SourceHealth({
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
          .fetchCategories(source)
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
    showAppSnackBar(context, '默认来源已改为：${source.name}');
  }

  @override
  Widget build(BuildContext context) {
    final registryState = ref.watch(vodSourceRegistryProvider);
    final selectedId = ref
        .watch(selectedVodSourceProvider)
        .maybeWhen(data: (source) => source.id, orElse: () => null);
    return Scaffold(
      appBar: AppBar(title: const Text('来源管理')),
      body: registryState.when(
        loading: () => const AppLoadingView(label: '正在加载来源…'),
        error: (error, _) => AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(vodSourceRegistryProvider),
        ),
        data: (registry) {
          final sources = registry.enabledSources;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${sources.length} 个来源，点击可设为默认',
                        style: const TextStyle(
                          color: AppColors.secondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _checking.isNotEmpty
                          ? null
                          : () => _checkAll(sources),
                      icon: const Icon(Icons.network_check, size: 18),
                      label: const Text('检测全部'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: sources.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) => _sourceTile(
                    sources[index],
                    sources[index].id == selectedId,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sourceTile(VodSource source, bool isDefault) {
    final health = _health[source.id];
    final checking = _checking.contains(source.id);
    return ListTile(
      onTap: isDefault ? null : () => _setDefault(source),
      leading: Icon(
        isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
        color: isDefault ? AppColors.accent : AppColors.tertiary,
      ),
      title: Row(
        children: [
          Flexible(child: Text(source.name, overflow: TextOverflow.ellipsis)),
          if (isDefault) ...[
            const SizedBox(width: 8),
            const Text(
              '默认',
              style: TextStyle(color: AppColors.accent, fontSize: 12),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${source.baseUri.host} · ${source.search ? '可搜索' : '不可搜索'}',
            style: const TextStyle(fontSize: 12, color: AppColors.secondary),
          ),
          if (health != null)
            Text(
              _healthText(health),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: health.ok ? AppColors.accent : AppColors.error,
              ),
            )
          else
            const Text(
              '尚未检测',
              style: TextStyle(fontSize: 12, color: AppColors.tertiary),
            ),
        ],
      ),
      trailing: checking
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: () => _check(source),
              child: const Text('检测'),
            ),
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
