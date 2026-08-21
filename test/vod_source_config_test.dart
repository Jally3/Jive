import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/vod_source_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _remoteJson = '''
{
  "sources": [
    {
      "id": "remote-b",
      "name": "远端B",
      "baseUri": "https://b.example.com/api.php/provide/vod",
      "adapterType": "mac_cms_v10",
      "priority": 2
    },
    {
      "id": "remote-a",
      "name": "远端A",
      "baseUri": "https://a.example.com/api.php/provide/vod",
      "adapterType": "mac_cms_v10",
      "priority": 1
    },
    {
      "id": "remote-http",
      "name": "明文源",
      "baseUri": "http://c.example.com/api.php/provide/vod",
      "adapterType": "mac_cms_v10",
      "priority": 3
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads and sorts remote sources, filtering non-HTTPS ones', () async {
    final client = MockClient(
      (request) async => http.Response.bytes(utf8.encode(_remoteJson), 200),
    );
    final sources = await VodSourceConfig().load(client: client);
    expect(sources.map((s) => s.id), ['remote-a', 'remote-b']);
  });

  test('uses the last successful remote config when remote fails', () async {
    final preferences = await SharedPreferences.getInstance();
    final config = VodSourceConfig(preferences: preferences);
    final successfulClient = MockClient(
      (request) async => http.Response.bytes(utf8.encode(_remoteJson), 200),
    );
    await config.load(client: successfulClient);

    final failingClient = MockClient(
      (request) async => http.Response('oops', 500),
    );
    final sources = await config.load(client: failingClient);

    expect(sources.map((s) => s.id), ['remote-a', 'remote-b']);
  });

  test(
    'does not replace the last successful cache with an empty remote',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final config = VodSourceConfig(preferences: preferences);
      final successfulClient = MockClient(
        (request) async => http.Response.bytes(utf8.encode(_remoteJson), 200),
      );
      await config.load(client: successfulClient);

      final emptyClient = MockClient(
        (request) async => http.Response('{"sources": []}', 200),
      );
      final sources = await config.load(client: emptyClient);

      expect(sources.map((s) => s.id), ['remote-a', 'remote-b']);
    },
  );

  test('falls back to the bundled asset when remote fails', () async {
    final client = MockClient((request) async => http.Response('oops', 500));
    final sources = await VodSourceConfig().load(client: client);
    expect(sources, isNotEmpty);
  });

  test('falls back to the bundled asset when remote is empty', () async {
    final client = MockClient(
      (request) async => http.Response('{"sources": []}', 200),
    );
    final sources = await VodSourceConfig().load(client: client);
    expect(sources, isNotEmpty);
  });

  test('falls back to the bundled asset when remote throws', () async {
    final client = MockClient((request) async => throw Exception('network'));
    final sources = await VodSourceConfig().load(client: client);
    expect(sources, isNotEmpty);
  });

  test(
    'forceLocalAsset without a client loads the bundled asset including age',
    () async {
      expect(VodSourceConfig.forceLocalAsset, isTrue);
      final sources = await VodSourceConfig().load();
      expect(sources.map((s) => s.id), contains('age'));
      expect(
        sources.map((s) => s.id),
        containsAll([
          'ddys',
          'olevod',
          'czzy',
          'youknow',
          'libvio',
          'thanju',
          'dbku',
        ]),
      );
      expect(
        sources.firstWhere((s) => s.id == 'dbku').adapterType,
        'syncnext_plugin',
      );
      expect(sources.last.id, 'dbku');
    },
  );
}
