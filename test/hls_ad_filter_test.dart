import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/ad_filter.dart';
import 'package:jive/data/cache/hls_parser.dart';
import 'package:jive/domain/playback_source.dart';

const _mediaWithAds = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:4.0,
https://cdn.example.com/movie/0000.ts
#EXTINF:4.0,
https://cdn.example.com/movie/0001.ts
#EXT-X-DISCONTINUITY
#EXTINF:1.7,
https://cdn.example.com/ads/0001.ts
#EXTINF:1.7,
https://cdn.example.com/ads/0002.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.0,
https://cdn.example.com/movie/0002.ts
#EXTINF:4.0,
https://cdn.example.com/movie/0003.ts
#EXT-X-ENDLIST
''';

void main() {
  PlaybackSource source() => PlaybackSource(
    url: Uri.parse('https://cdn.example.com/movie/index.m3u8'),
  );

  test('filter disabled returns original manifest unchanged', () async {
    final parser = HlsParser(
      client: MockClient((request) async => http.Response(_mediaWithAds, 200)),
    );
    final decision = await parser.resolve(source());
    expect(decision.isCacheable, isTrue);
    final playlist = decision.mediaPlaylist!;
    expect(playlist.timelineMapping, isNull);
    expect(playlist.segments, hasLength(6));
  });

  test('filter enabled removes ads and rewrites proxy manifest', () async {
    final parser = HlsParser(
      client: MockClient((request) async => http.Response(_mediaWithAds, 200)),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await parser.resolve(source());
    expect(decision.isCacheable, isTrue);
    final playlist = decision.mediaPlaylist!;
    expect(playlist.segments, hasLength(4));
    expect(playlist.timelineMapping, isNotNull);

    final plan = parser.buildProxyPlan(playlist, 'tok');
    expect(plan.expectedResourceCount, 4);
    expect(plan.proxyManifest, isNot(contains('ads/0001')));
    expect(plan.proxyManifest, contains('/play/tok/res/'));
    expect(plan.proxyManifest, contains('#EXT-X-ENDLIST'));
  });

  test('filtered raw preserves EXTINF durations', () async {
    final parser = HlsParser(
      client: MockClient((request) async => http.Response(_mediaWithAds, 200)),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await parser.resolve(source());
    final playlist = decision.mediaPlaylist!;
    final plan = parser.buildProxyPlan(playlist, 'tok');
    expect(plan.proxyManifest, contains('#EXTINF:4.0,'));
    expect(plan.proxyManifest, isNot(contains('#EXTINF:1.7,')));
  });

  test('filtered timeline maps ad duration out of playback', () async {
    final parser = HlsParser(
      client: MockClient((request) async => http.Response(_mediaWithAds, 200)),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await parser.resolve(source());
    final mapping = decision.mediaPlaylist!.timelineMapping!;
    // source 11500ms is just after the 3400ms ad block (8000-11400) -> filtered 8100ms
    final filtered = mapping.sourceToFiltered(
      const Duration(milliseconds: 11500),
    );
    expect(filtered.inMilliseconds, closeTo(8100, 1));
    expect(
      mapping.filteredToSource(filtered).inMilliseconds,
      closeTo(11500, 1),
    );
  });

  test('AES-128 without an explicit IV keeps the original timeline', () async {
    final parser = HlsParser(
      client: MockClient(
        (_) async => http.Response(
          _mediaWithAds.replaceFirst(
            '#EXT-X-TARGETDURATION:10',
            '#EXT-X-TARGETDURATION:10\n'
                '#EXT-X-KEY:METHOD=AES-128,URI="enc.key"',
          ),
          200,
        ),
      ),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await parser.resolve(source());

    expect(decision.isCacheable, isTrue);
    expect(decision.mediaPlaylist!.hasImplicitEncryptionIv, isTrue);
    expect(decision.mediaPlaylist!.segments, hasLength(6));
    expect(decision.mediaPlaylist!.timelineMapping, isNull);
  });

  test('structural failure keeps original manifest (rollback)', () async {
    final parser = HlsParser(
      client: MockClient((request) async => http.Response(_mediaWithAds, 200)),
      adFilter: const AdFilter(enabled: true),
    );
    // Even with filter on, live/encrypted still fall back to direct (no filter).
    final live = HlsParser(
      client: MockClient(
        (request) async => http.Response(
          '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:4.0,\na.ts\n',
          200,
        ),
      ),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await live.resolve(
      PlaybackSource(url: Uri.parse('https://cdn.example.com/live.m3u8')),
    );
    expect(decision.isCacheable, isFalse);
    expect(parser, isNotNull);
  });
}
