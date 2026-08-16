import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/hls_parser.dart';
import 'package:jive/domain/playback_source.dart';

const _media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.0,
https://cdn.example.com/movie/0001.ts
#EXT-X-DISCONTINUITY
#EXTINF:1.7,
https://ads.example.com/0001.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.0,
segment-relative.ts
#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
#EXT-X-ENDLIST
''';

void main() {
  PlaybackSource source(String url) =>
      PlaybackSource(url: Uri.parse(url), format: PlaybackFormat.hls);

  test('classifies a VOD media playlist as cacheable', () async {
    final parser = HlsParser(
      client: MockClient((request) async {
        expect(request.url.path, '/movie/index.m3u8');
        return http.Response(_media, 200);
      }),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/movie/index.m3u8'),
    );
    expect(decision.isCacheable, isTrue);
    final playlist = decision.mediaPlaylist!;
    expect(playlist.isLive, isFalse);
    expect(playlist.hasEncryption, isFalse);
    expect(playlist.segments, hasLength(3));
    expect(playlist.segments[0].uri.host, 'cdn.example.com');
    expect(playlist.segments[2].uri.path, '/movie/segment-relative.ts');
  });

  test('live playlist without ENDLIST falls back to direct', () async {
    final parser = HlsParser(
      client: MockClient(
        (request) async => http.Response(
          '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:4.0,\na.ts\n',
          200,
        ),
      ),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/live.m3u8'),
    );
    expect(decision.isCacheable, isFalse);
    expect(decision.reason, contains('直播'));
  });

  test('encrypted playlist falls back to direct', () async {
    final parser = HlsParser(
      client: MockClient(
        (request) async => http.Response(
          '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"\n'
          '#EXTINF:4.0,\na.ts\n'
          '#EXT-X-ENDLIST\n',
          200,
        ),
      ),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/a.m3u8'),
    );
    expect(decision.isCacheable, isFalse);
  });

  test('unsupported tag falls back to direct', () async {
    final parser = HlsParser(
      client: MockClient(
        (request) async => http.Response(
          '#EXTM3U\n#EXT-X-SOME-FUTURE-TAG:1\n#EXTINF:4.0,\na.ts\n#EXT-X-ENDLIST\n',
          200,
        ),
      ),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/a.m3u8'),
    );
    expect(decision.isCacheable, isFalse);
    expect(decision.reason, contains('SOME-FUTURE-TAG'));
  });

  test('segment BYTERANGE remains cacheable and is preserved', () async {
    const ranged = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
#EXT-X-BYTERANGE:100@0
media.mp4
#EXTINF:4.0,
#EXT-X-BYTERANGE:100@100
media.mp4
#EXT-X-ENDLIST
''';
    final parser = HlsParser(
      client: MockClient((_) async => http.Response(ranged, 200)),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/movie/index.m3u8'),
    );

    expect(decision.isCacheable, isTrue);
    expect(decision.mediaPlaylist!.segments[0].byteRange, '100@0');
    expect(decision.mediaPlaylist!.segments[1].byteRange, '100@100');
    final plan = parser.buildProxyPlan(decision.mediaPlaylist!, 'range');
    expect(plan.expectedResourceCount, 1);
    expect(plan.proxyManifest, contains('#EXT-X-BYTERANGE:100@100'));
  });

  test('master playlist picks the first variant and resolves it', () async {
    final parser = HlsParser(
      client: MockClient((request) async {
        if (request.url.path == '/index.m3u8') {
          return http.Response(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1920x1080\n'
            '1080/index.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=640000,RESOLUTION=720x480\n'
            '720/index.m3u8\n',
            200,
          );
        }
        expect(request.url.path, '/1080/index.m3u8');
        return http.Response(_media, 200);
      }),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/index.m3u8'),
    );
    expect(decision.isCacheable, isTrue);
    expect(decision.mediaPlaylist!.segments, hasLength(3));
  });

  test('proxy plan rewrites segment uris and preserves tags', () async {
    final parser = HlsParser(
      client: MockClient((r) async => http.Response(_media, 200)),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/movie/index.m3u8'),
    );
    final plan = parser.buildProxyPlan(decision.mediaPlaylist!, 'tok123');
    expect(plan.expectedResourceCount, 4);
    expect(plan.proxyManifest, contains('#EXTINF:4.0,'));
    expect(plan.proxyManifest, contains('#EXT-X-DISCONTINUITY'));
    expect(plan.proxyManifest, contains('#EXT-X-ENDLIST'));
    expect(plan.proxyManifest, contains('/play/tok123/res/sha256:'));
    expect(
      plan.proxyManifest,
      isNot(contains('cdn.example.com/movie/0001.ts')),
    );
    expect(plan.resources.values.every((u) => u.scheme == 'https'), isTrue);
    final mapId = plan.mapResourceId;
    expect(mapId, isNotNull);
    expect(plan.resources[mapId], isNotNull);
  });

  test('non-200 manifest falls back to direct', () async {
    final parser = HlsParser(
      client: MockClient((request) async => http.Response('nope', 404)),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/missing.m3u8'),
    );
    expect(decision.isCacheable, isFalse);
    expect(decision.reason, contains('404'));
  });

  test('ext is derived from uri path and falls back to bin', () {
    expect(HlsParser.extFor(Uri.parse('https://cdn.example.com/a.mp4')), 'mp4');
    expect(
      HlsParser.extFor(Uri.parse('https://cdn.example.com/a.ts?token=1')),
      'ts',
    );
    expect(HlsParser.extFor(Uri.parse('https://cdn.example.com/raw')), 'bin');
  });

  test('resource id is a stable sha256 hash', () {
    final id = HlsParser.resourceId(Uri.parse('https://cdn.example.com/a.ts'));
    expect(id, startsWith('sha256:'));
    expect(RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(id), isTrue);
    expect(id, HlsParser.resourceId(Uri.parse('https://cdn.example.com/a.ts')));
  });

  test('utf8 manifest body decodes correctly', () async {
    final parser = HlsParser(
      client: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(_media),
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        ),
      ),
    );
    final decision = await parser.resolve(
      source('https://cdn.example.com/movie/index.m3u8'),
    );
    expect(decision.isCacheable, isTrue);
  });
}
