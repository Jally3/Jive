import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/vod_source.dart';

class VodSourceConfig {
  static const _assetPath = 'config/vod_sources.json';

  /// 只允许加载启用、HTTPS 且 host 非空的内置源（http 明文源兜底过滤）。
  static bool isLoadable(VodSource source) =>
      source.id.isNotEmpty &&
      source.enabled &&
      source.isHttps &&
      source.baseUri.host.isNotEmpty;

  Future<List<VodSource>> load() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
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
