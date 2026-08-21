import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/playback_url_resolver.dart';
import 'package:jive/domain/playback_selection.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:jive/domain/video.dart';

void main() {
  test('resolves an HTML player page to its real HLS URL', () async {
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        expect(request.url.path, '/play/token/index.m3u8');
        return http.Response(
          '',
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      expect(request.url.path, '/play/token');
      expect(request.headers['range'], isNull);
      return http.Response(
        '''<html><script>const vid = '/play/token/index.m3u8';</script></html>''',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final resolver = PlaybackUrlResolver(client: client);
    const episode = Episode(
      id: '1',
      name: '第1集',
      url: 'https://v.example.com/play/token',
      identity: 'episode:1',
    );
    final resolved = await resolver.resolveSelection(
      PlaybackSelection(
        sourceId: 'source',
        sourceVideoId: 'video',
        title: '影片',
        playbackLineIdentity: 'line',
        episodeIdentity: episode.identity,
        episode: episode,
        playbackSource: PlaybackSource(
          url: Uri.parse(episode.url),
          format: PlaybackFormat.unknown,
        ),
      ),
    );

    expect(
      resolved.playbackSource.url,
      Uri.parse('https://v.example.com/play/token/index.m3u8'),
    );
    expect(resolved.playbackSource.format, PlaybackFormat.hls);
    expect(resolved.episode.url, resolved.playbackSource.url.toString());
    client.close();
  });

  test('rejects an HTML page without a media candidate', () async {
    final resolver = PlaybackUrlResolver(
      client: MockClient(
        (_) async => http.Response(
          '<html>no player</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      ),
    );

    expect(
      () => resolver.resolve(
        PlaybackSource(url: Uri.parse('https://v.example.com/play/token')),
      ),
      throwsA(isA<PlaybackUrlResolutionException>()),
    );
  });

  test('wraps transport failures in PlaybackUrlResolutionException', () async {
    final failures = <Object>[
      TimeoutException('timed out'),
      const SocketException('failed host lookup'),
      http.ClientException('connection closed'),
    ];

    for (final failure in failures) {
      final resolver = PlaybackUrlResolver(
        client: MockClient((_) async => throw failure),
      );

      await expectLater(
        resolver.resolve(
          PlaybackSource(url: Uri.parse('https://v.example.com/play/token')),
        ),
        throwsA(
          isA<PlaybackUrlResolutionException>().having(
            (error) => error.message,
            'message',
            '播放地址请求失败，请检查网络后重试',
          ),
        ),
      );
    }
  });

  test('clears one cached URL or all cached URLs', () async {
    final pageRequests = <String, int>{};
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      final key = request.url.pathSegments.last;
      final requestCount = (pageRequests[key] ?? 0) + 1;
      pageRequests[key] = requestCount;
      return http.Response(
        '''<html><script>const vid = '/media/$key-$requestCount.m3u8';</script></html>''',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final resolver = PlaybackUrlResolver(client: client);
    final sourceA = PlaybackSource(
      url: Uri.parse('https://v.example.com/play/a'),
    );
    final sourceB = PlaybackSource(
      url: Uri.parse('https://v.example.com/play/b'),
    );

    expect((await resolver.resolve(sourceA)).url.path, '/media/a-1.m3u8');
    expect((await resolver.resolve(sourceB)).url.path, '/media/b-1.m3u8');
    await resolver.resolve(sourceA);
    await resolver.resolve(sourceB);
    expect(pageRequests, {'a': 1, 'b': 1});

    resolver.clearCacheFor(sourceA.url);
    expect((await resolver.resolve(sourceA)).url.path, '/media/a-2.m3u8');
    await resolver.resolve(sourceB);
    expect(pageRequests, {'a': 2, 'b': 1});

    resolver.clearCache();
    await resolver.resolve(sourceA);
    await resolver.resolve(sourceB);
    expect(pageRequests, {'a': 3, 'b': 2});
    client.close();
  });

  test('extracts Vurl without HEAD and keeps empty headers empty', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      expect(request.headers['range'], isNull);
      expect(request.headers['referer'], isNull);
      return http.Response(
        '''<html><script>var Vurl = 'https://cdn.example.com/a.m3u8';</script></html>''',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final resolved = await PlaybackUrlResolver(client: client).resolve(
      PlaybackSource(
        url: Uri.parse('https://jx.example.com/m3u8/?url=age_x'),
        headers: {
          'User-Agent': 'AgeUA',
          'Referer': 'https://jx.example.com/m3u8/?url=age_x',
        },
      ),
    );
    expect(methods, ['GET']);
    expect(resolved.url, Uri.parse('https://cdn.example.com/a.m3u8'));
    expect(resolved.format, PlaybackFormat.hls);
    expect(resolved.headers['User-Agent'], 'AgeUA');
    expect(
      resolved.headers['Referer'],
      'https://jx.example.com/m3u8/?url=age_x',
    );
    client.close();
  });

  test('prefers a dotted m3u8 url over Vurl without extension', () async {
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        expect(request.url.path, '/real.m3u8');
        return http.Response('', 200);
      }
      return http.Response(
        '''<html><script>
          var url = 'https://cdn.example.com/real.m3u8';
          var Vurl = 'https://cdn.example.com/ad';
        </script></html>''',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final resolved = await PlaybackUrlResolver(client: client).resolve(
      PlaybackSource(url: Uri.parse('https://v.example.com/play/token')),
    );
    expect(resolved.url.path, '/real.m3u8');
    client.close();
  });

  test('falls back from HEAD 502 to Range GET 206', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      if (!request.url.path.endsWith('.m3u8')) {
        expect(request.headers['range'], isNull);
      }
      if (request.url.path.endsWith('.m3u8')) {
        if (request.method == 'HEAD') {
          return http.Response('', 502);
        }
        expect(request.headers['range'], 'bytes=0-511');
        expect(request.headers['user-agent'], 'AgeUA');
        expect(request.headers['referer'], 'https://v.example.com/play/token');
        return http.Response(
          '#EXTM3U\n',
          206,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      return http.Response(
        '''<html><script>const vid = 'https://cdn.example.com/a.m3u8';</script></html>''',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final resolved = await PlaybackUrlResolver(client: client).resolve(
      PlaybackSource(
        url: Uri.parse('https://v.example.com/play/token'),
        headers: {
          'User-Agent': 'AgeUA',
          'Referer': 'https://v.example.com/play/token',
        },
      ),
    );
    expect(methods, ['GET', 'HEAD', 'GET']);
    expect(resolved.url, Uri.parse('https://cdn.example.com/a.m3u8'));
    expect(resolved.format, PlaybackFormat.hls);
    expect(resolved.headers['User-Agent'], 'AgeUA');
    expect(resolved.headers['Referer'], 'https://v.example.com/play/token');
    client.close();
  });
}
