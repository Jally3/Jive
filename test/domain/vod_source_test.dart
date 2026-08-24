import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:jive/data/vod_source/adapters/mac_cms_v10_adapter.dart';
import 'package:jive/data/vod_source/vod_source_config.dart';
import 'package:jive/data/vod_source/vod_source_preferences.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

VodSource _source(
  String id, {
  bool enabled = true,
  bool https = true,
  int priority = 1,
}) => VodSource(
  id: id,
  name: '源$id',
  baseUri: Uri.parse(
    '${https ? 'https' : 'http'}://api.$id.example.com/api.php/provide/vod',
  ),
  adapterType: 'mac_cms_v10',
  enabled: enabled,
  priority: priority,
);

VodSourceRegistry _registry(List<VodSource> sources) =>
    VodSourceRegistry(sources, const {});

ProviderContainer _container(VodSourceRegistry registry) {
  final container = ProviderContainer(
    overrides: [
      vodSourceRegistryProvider.overrideWith((ref) async => registry),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<AsyncValue<VodSource>> _settled(ProviderContainer container) {
  final current = container.read(selectedVodSourceProvider);
  if (current is! AsyncLoading) return Future.value(current);
  final completer = Completer<AsyncValue<VodSource>>();
  final sub = container.listen(selectedVodSourceProvider, (_, next) {
    if (next is! AsyncLoading && !completer.isCompleted) {
      completer.complete(next);
    }
  });
  return completer.future.whenComplete(sub.close);
}

void main() {
  test('VodSource parses from json with defaults', () {
    final source = VodSource.fromJson({
      'id': '2',
      'name': 'U酷资源',
      'baseUri': 'https://api.ukuapi.com/api.php/provide/vod',
      'adapterType': 'mac_cms_v10',
      'search': true,
      'enabled': true,
      'priority': 2,
    });
    expect(source.id, '2');
    expect(source.name, 'U酷资源');
    expect(source.isHttps, isTrue);
    expect(source.search, isTrue);
    expect(source.enabled, isTrue);
    expect(source.priority, 2);
    expect(source.featuredCategoryIds, isEmpty);
    expect(source.notification, isEmpty);
  });

  test('VodSource round-trips notification', () {
    final source = VodSource.fromJson({
      'id': 'age',
      'name': '新 AGE',
      'baseUri': 'https://ageapi.omwjhz.com:18888',
      'adapterType': 'age_v2',
      'notification': 'AGE 动漫',
    });
    expect(source.notification, 'AGE 动漫');
    expect(source.toJson()['notification'], 'AGE 动漫');
    expect(source.isSiteSource, isTrue);
    expect(source.disablesDownload, isTrue);
  });

  test('VodSource round-trips pluginConfigUri', () {
    final source = VodSource.fromJson({
      'id': 'dbku',
      'name': '独播库',
      'baseUri': 'https://www.dbku.tv',
      'adapterType': 'syncnext_plugin',
      'pluginConfigUri':
          'https://raw.githubusercontent.com/example/plugin_dbku/config.json',
      'notification': 'dbku.tv 线上看',
    });
    expect(source.pluginConfigUri?.host, 'raw.githubusercontent.com');
    expect(source.isSiteSource, isTrue);
    expect(source.disablesDownload, isTrue);
    expect(
      source.toJson()['pluginConfigUri'],
      'https://raw.githubusercontent.com/example/plugin_dbku/config.json',
    );
  });

  test('VodSource defaults when fields are missing', () {
    final source = VodSource.fromJson({'id': 'x'});
    expect(source.name, 'x');
    expect(source.search, isTrue);
    expect(source.enabled, isTrue);
    expect(source.priority, 999);
    expect(source.adapterType, 'mac_cms_v10');
    expect(source.isSiteSource, isFalse);
  });

  test('registry filters enabled and searchable sources', () {
    final registry = VodSourceRegistry([
      VodSource(
        id: 'a',
        name: 'A',
        baseUri: Uri.parse('https://a'),
        adapterType: 'mac_cms_v10',
        enabled: true,
        search: true,
      ),
      VodSource(
        id: 'b',
        name: 'B',
        baseUri: Uri.parse('https://b'),
        adapterType: 'mac_cms_v10',
        enabled: true,
        search: false,
      ),
      VodSource(
        id: 'c',
        name: 'C',
        baseUri: Uri.parse('https://c'),
        adapterType: 'mac_cms_v10',
        enabled: false,
        search: true,
      ),
    ], const {});
    expect(registry.enabledSources.map((s) => s.id), ['a', 'b']);
    expect(registry.searchableSources.map((s) => s.id), ['a']);
    expect(registry.defaultSource!.id, 'a');
    expect(registry.findById('c')!.enabled, isFalse);
    expect(registry.findById('z'), isNull);
  });

  test('excludingUnregistered drops unknown adapter types', () {
    final sources = [
      VodSource(
        id: 'a',
        name: 'A',
        baseUri: Uri.parse('https://a.example.com'),
        adapterType: 'mac_cms_v10',
      ),
      VodSource(
        id: 'plugin',
        name: '插件源',
        baseUri: Uri.parse('https://plugin.example.com'),
        adapterType: 'syncnext_plugin',
      ),
    ];
    final registry = VodSourceRegistry.excludingUnregistered(sources, {
      'mac_cms_v10': MacCmsV10Adapter(http.Client()),
    });
    expect(registry.allSources.map((s) => s.id), ['a']);
    expect(registry.findById('plugin'), isNull);
  });

  test('same vod_id across sources keeps distinct global ids', () {
    final a = Video(
      id: '42',
      title: '同名影片',
      sourceId: 's1',
      sourceVideoId: '42',
    );
    final b = Video(
      id: '42',
      title: '同名影片',
      sourceId: 's2',
      sourceVideoId: '42',
    );
    expect(a.globalId, 's1:42');
    expect(b.globalId, 's2:42');
    expect(a.globalId, isNot(b.globalId));
    expect(VideoRef.fromVideo(a).globalId, 's1:42');
  });

  test('old json without sourceId migrates to default storm', () {
    final video = Video.fromJson({'id': '1', 'title': '旧数据'});
    expect(video.sourceId, 'storm');
    expect(video.sourceVideoId, '1');
    expect(video.globalId, 'storm:1');
  });

  test('json round-trips source identity and matching fields', () {
    final video = Video(
      id: '9',
      title: '影片',
      sourceId: 's2',
      sourceVideoId: '9',
      year: '2026',
      area: '中国',
      actors: '演员A',
      director: '导演B',
    );
    final decoded = Video.fromJson(video.toJson());
    expect(decoded.globalId, 's2:9');
    expect(decoded.year, '2026');
    expect(decoded.area, '中国');
    expect(decoded.actors, '演员A');
    expect(decoded.director, '导演B');
  });

  test('empty sourceId/sourceVideoId migrate to defaults like missing', () {
    final video = Video.fromJson({
      'id': '7',
      'title': '旧数据',
      'sourceId': '',
      'sourceVideoId': '',
    });
    expect(video.sourceId, 'storm');
    expect(video.sourceVideoId, '7');
    expect(video.globalId, 'storm:7');
  });

  test('config filter rejects http, disabled and empty-host sources', () {
    expect(VodSourceConfig.isLoadable(_source('ok')), isTrue);
    expect(VodSourceConfig.isLoadable(_source('plain', https: false)), isFalse);
    expect(VodSourceConfig.isLoadable(_source('off', enabled: false)), isFalse);
    expect(
      VodSourceConfig.isLoadable(
        VodSource(
          id: '',
          name: '无 id',
          baseUri: Uri.parse('https://a.example.com'),
          adapterType: 'mac_cms_v10',
        ),
      ),
      isFalse,
    );
    expect(
      VodSourceConfig.isLoadable(
        VodSource(
          id: 'nohost',
          name: '无 host',
          baseUri: Uri.parse(''),
          adapterType: 'mac_cms_v10',
        ),
      ),
      isFalse,
    );
  });

  test('select rejects non-whitelist, http and disabled sources', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = _registry([
      _source('a'),
      _source('off', enabled: false),
      _source('plain', https: false),
    ]);
    final container = _container(registry);
    await _settled(container);
    final notifier = container.read(selectedVodSourceProvider.notifier);
    await expectLater(
      () => notifier.select(_source('ghost')),
      throwsArgumentError,
    );
    await expectLater(
      () => notifier.select(registry.findById('plain')!),
      throwsArgumentError,
    );
    await expectLater(
      () => notifier.select(registry.findById('off')!),
      throwsArgumentError,
    );
  });

  test('select persists and a fresh notifier restores the selection', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = _registry([_source('a'), _source('b', priority: 2)]);
    final first = _container(registry);
    expect((await _settled(first)).value!.id, 'a');
    await first
        .read(selectedVodSourceProvider.notifier)
        .select(registry.findById('b')!);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_vod_source_id'), 'b');

    final second = _container(registry);
    expect((await _settled(second)).value!.id, 'b');
  });

  test(
    'persisted id disabled or unknown falls back to default source',
    () async {
      final registry = _registry([
        _source('a'),
        _source('off', enabled: false, priority: 2),
      ]);

      SharedPreferences.setMockInitialValues({'selected_vod_source_id': 'off'});
      final disabled = _container(registry);
      expect((await _settled(disabled)).value!.id, 'a');

      SharedPreferences.setMockInitialValues({
        'selected_vod_source_id': 'ghost',
      });
      final unknown = _container(registry);
      expect((await _settled(unknown)).value!.id, 'a');
    },
  );
}
