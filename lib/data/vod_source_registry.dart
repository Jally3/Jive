import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../domain/vod_source.dart';
import 'adapters/mac_cms_v10_adapter.dart';
import 'vod_source_adapter.dart';
import 'vod_source_config.dart';

class VodSourceRegistry {
  VodSourceRegistry(this._sources, this._adapters);

  final List<VodSource> _sources;
  final Map<String, VodSourceAdapter> _adapters;

  List<VodSource> get allSources => List.unmodifiable(_sources);

  List<VodSource> get enabledSources =>
      _sources.where((s) => s.enabled).toList();

  List<VodSource> get searchableSources =>
      _sources.where((s) => s.enabled && s.search).toList();

  VodSource? findById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  VodSource? get defaultSource =>
      enabledSources.isNotEmpty ? enabledSources.first : null;

  VodSourceAdapter? adapterFor(VodSource source) =>
      _adapters[source.adapterType];

  VodSourceAdapter? adapterForId(String sourceId) {
    final source = findById(sourceId);
    return source == null ? null : adapterFor(source);
  }
}

final vodSourceRegistryProvider = FutureProvider<VodSourceRegistry>((
  ref,
) async {
  final sources = await ref.watch(vodSourceConfigProvider.future);
  final client = http.Client();
  ref.onDispose(client.close);
  final adapters = <String, VodSourceAdapter>{
    'mac_cms_v10': MacCmsV10Adapter(client),
  };
  return VodSourceRegistry(sources, adapters);
});
