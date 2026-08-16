import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/cache_io.dart';
import 'package:jive/data/cache/local_proxy.dart';

const _token = 'testtoken';
final _segmentId = 'sha256:${'a' * 64}';

ProxySessionRoute _route(http.Client client) => ProxySessionRoute(
  token: _token,
  proxyManifest: '#EXTM3U\n#EXTINF:4.0,\n/play/$_token/res/$_segmentId\n',
  resources: {_segmentId: Uri.parse('https://origin.example.com/seg0001.ts')},
  extByResourceId: {_segmentId: 'ts'},
  sessionHeaders: {'referer': 'https://app.example.com'},
  client: client,
);

void main() {
  late LocalProxyServer proxy;

  setUp(() async {
    proxy = LocalProxyServer();
    await proxy.start();
  });

  tearDown(() async {
    await proxy.close();
  });

  test('serves the proxy manifest with hls content type', () async {
    final client = MockClient((request) async {
      throw StateError('origin should not be hit for manifest');
    });
    proxy.register(_route(client));
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/index.m3u8'),
    );
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('mpegurl'));
    expect(response.body, contains('#EXTM3U'));
  });

  test('proxies a segment from origin', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'origin.example.com');
      expect(request.headers['referer'], 'https://app.example.com');
      return http.Response('segment-bytes', 200);
    });
    proxy.register(_route(client));
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/res/$_segmentId'),
    );
    expect(response.statusCode, 200);
    expect(response.body, 'segment-bytes');
  });

  test('forwards downstream range and relays 206', () async {
    final client = MockClient((request) async {
      expect(request.headers['range'], 'bytes=0-99');
      return http.Response(
        'x' * 100,
        206,
        headers: {
          'content-range': 'bytes 0-99/5000',
          'content-length': '100',
          'content-type': 'video/mp2t',
          'etag': '"v1"',
        },
      );
    });
    proxy.register(_route(client));
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/res/$_segmentId'),
      headers: {'range': 'bytes=0-99'},
    );
    expect(response.statusCode, 206);
    expect(response.headers['content-range'], 'bytes 0-99/5000');
    expect(response.headers['etag'], '"v1"');
    expect(response.body, hasLength(100));
  });

  test('unknown session token returns 404', () async {
    proxy.register(_route(MockClient((r) async => throw StateError('no'))));
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/nope/index.m3u8'),
    );
    expect(response.statusCode, 404);
  });

  test('unknown resource id returns 404', () async {
    proxy.register(_route(MockClient((r) async => throw StateError('no'))));
    final response = await http.Client().get(
      Uri.parse(
        'http://127.0.0.1:${proxy.port}/play/$_token/res/sha256:${'b' * 64}',
      ),
    );
    expect(response.statusCode, 404);
  });

  test('http origin scheme is rejected', () async {
    final route = ProxySessionRoute(
      token: _token,
      proxyManifest: '',
      resources: {_segmentId: Uri.parse('http://insecure.example.com/a.ts')},
      extByResourceId: const {},
      sessionHeaders: const {},
      client: MockClient((r) async => http.Response('x', 200)),
    );
    proxy.register(route);
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/res/$_segmentId'),
    );
    expect(response.statusCode, 400);
  });

  test('origin error is relayed as its status code', () async {
    final client = MockClient((request) async => http.Response('nope', 403));
    proxy.register(_route(client));
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/res/$_segmentId'),
    );
    expect(response.statusCode, 403);
  });

  test('unregister removes the session route', () async {
    proxy.register(_route(MockClient((r) async => http.Response('x', 200))));
    proxy.unregister(_token);
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/index.m3u8'),
    );
    expect(response.statusCode, 404);
  });

  test('manifest is served as raw text', () async {
    final raw = utf8.encode('#EXTM3U\n#EXTINF:4.0,\n/seg.ts\n#EXT-X-ENDLIST\n');
    proxy.register(
      ProxySessionRoute(
        token: _token,
        proxyManifest: utf8.decode(raw),
        resources: const {},
        extByResourceId: const {},
        sessionHeaders: const {},
        client: MockClient((r) async => http.Response('', 200)),
      ),
    );
    final response = await http.Client().get(
      Uri.parse('http://127.0.0.1:${proxy.port}/play/$_token/index.m3u8'),
    );
    expect(response.body, contains('#EXT-X-ENDLIST'));
  });

  test(
    'fetcher-backed route serves a segment through the real server',
    () async {
      final client = MockClient(
        (request) async => http.Response('segment-bytes-123', 200),
      );
      final fetcher = ResourceFetcher(client: client, sessionHeaders: const {});
      proxy.register(
        ProxySessionRoute(
          token: _token,
          proxyManifest: '#EXTM3U\n',
          resources: {
            _segmentId: Uri.parse('https://origin.example.com/seg.ts'),
          },
          extByResourceId: {_segmentId: 'ts'},
          sessionHeaders: const {},
          client: client,
          fetcher: fetcher,
        ),
      );
      final response = await http.Client().get(
        Uri.parse(
          'http://127.0.0.1:${proxy.port}/play/$_token/res/$_segmentId',
        ),
      );
      expect(response.statusCode, 200);
      expect(response.body, 'segment-bytes-123');
    },
  );
}
