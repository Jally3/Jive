import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/vod_source.dart';

class VodSourceConfig {
  static const _assetPath = 'config/vod_sources.json';
  static const _remoteUrl = 'https://hey-rickytse.com/data/vod_sources.json';
  static const _remoteTimeout = Duration(seconds: 10);
  static const _remoteCacheKey = 'vod_source_config_remote_cache';

  /// 为 true 时 App 启动只读内置 `config/vod_sources.json`，跳过远端和远端缓存。
  /// 本地验收 AGE 时保持 true；测完改回 false 以恢复远端源列表。
  /// 单测传入 [load] 的 `client` 时仍走远端路径，不受此开关影响。
  static const forceLocalAsset = true;

  VodSourceConfig({SharedPreferences? preferences})
    : _preferences = preferences;

  final SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ?? await SharedPreferences.getInstance();

  /// 只允许加载启用、HTTPS 且 host 非空的内置源（http 明文源兜底过滤）。
  /// `syncnext_plugin` 还要求 HTTPS 的 `pluginConfigUri`。
  static bool isLoadable(VodSource source) {
    if (source.id.isEmpty ||
        !source.enabled ||
        !source.isHttps ||
        source.baseUri.host.isEmpty) {
      return false;
    }
    if (source.adapterType != 'syncnext_plugin') return true;
    final plugin = source.pluginConfigUri;
    return plugin != null && plugin.scheme == 'https' && plugin.host.isNotEmpty;
  }

  /// 优先加载在线配置（源列表可随时更新）。远端不可用时先使用最近一次
  /// 成功的远端配置，缓存也不可用时才回退内置资产。
  Future<List<VodSource>> load({http.Client? client}) async {
    if (forceLocalAsset && client == null) return _loadAsset();
    final remote = await _loadRemote(client);
    if (remote != null) return remote;
    final cached = await _loadCachedRemote();
    if (cached != null) return cached;
    return _loadAsset();
  }

  Future<List<VodSource>?> _loadRemote(http.Client? injected) async {
    final client = injected ?? http.Client();
    try {
      final response = await client
          .get(Uri.parse(_remoteUrl))
          .timeout(_remoteTimeout);
      if (response.statusCode != 200) return null;
      final raw = utf8.decode(response.bodyBytes);
      final sources = _parse(raw);
      // 远端配置为空视为异常（防误清空导致 App 无源可用），回退内置。
      if (sources.isEmpty) return null;
      await _cacheRemote(raw);
      return sources;
    } catch (_) {
      return null;
    } finally {
      if (injected == null) client.close();
    }
  }

  Future<void> _cacheRemote(String raw) async {
    try {
      await (await _prefs).setString(_remoteCacheKey, raw);
    } catch (_) {
      // 缓存失败不影响本次已成功获取的远端配置。
    }
  }

  Future<List<VodSource>?> _loadCachedRemote() async {
    try {
      final raw = (await _prefs).getString(_remoteCacheKey);
      if (raw == null) return null;
      final sources = _parse(raw);
      return sources.isEmpty ? null : sources;
    } catch (_) {
      return null;
    }
  }

  Future<List<VodSource>> _loadAsset() async {
    try {
      return _parse(await rootBundle.loadString(_assetPath));
    } catch (_) {
      return [];
    }
  }

  List<VodSource> _parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return [];
      final list = decoded['sources'];
      if (list is! List) return [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(VodSource.fromJson)
          .where(isLoadable)
          .toList()
        ..sort((a, b) {
          final cmp = a.priority.compareTo(b.priority);
          return cmp != 0 ? cmp : a.id.compareTo(b.id);
        });
    } catch (_) {
      return [];
    }
  }
}

final vodSourceConfigProvider = FutureProvider<List<VodSource>>((ref) async {
  return VodSourceConfig().load();
});
