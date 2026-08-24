import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/playback/ad_filter.dart';
import 'package:jive/data/playback/hls_parser.dart';
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

  test('filter enabled but no ads keeps the original timeline', () async {
    const clean = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:4.0,
https://cdn.example.com/movie/0000.ts
#EXTINF:4.0,
https://cdn.example.com/movie/0001.ts
#EXTINF:4.0,
https://cdn.example.com/movie/0002.ts
#EXT-X-ENDLIST
''';
    final parser = HlsParser(
      client: MockClient((request) async => http.Response(clean, 200)),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await parser.resolve(source());
    expect(decision.isCacheable, isTrue);
    expect(decision.filterConfidence, isNull);
    final playlist = decision.mediaPlaylist!;
    expect(playlist.segments, hasLength(3));
    expect(playlist.timelineMapping, isNull);
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

  // 真实样本回归：广告分片时长(3s)比正片(1s)长、路径含 /adjump/、
  // 前后 DISCONTINUITY 包裹，时长类检测器对此全部失效，只能靠明牌路径。
  test('adjump path markers remove longer-than-content ad segments', () async {
    final buffer = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:10');
    void content(int from, int to) {
      for (var i = from; i <= to; i++) {
        buffer.writeln('#EXTINF:1.0,');
        buffer.writeln('${i.toString().padLeft(7, '0')}.ts');
      }
    }

    void adBlock() {
      buffer.writeln('#EXT-X-DISCONTINUITY');
      for (var i = 0; i < 9; i++) {
        buffer.writeln('#EXTINF:${i == 8 ? 1.76 : 3.0},');
        buffer.writeln('/video/adjump/time/1786905362888000000$i.ts');
      }
      buffer.writeln('#EXT-X-DISCONTINUITY');
    }

    content(0, 299);
    adBlock();
    content(300, 2399);
    adBlock();
    content(2400, 2499);
    buffer.writeln('#EXT-X-ENDLIST');

    final parser = HlsParser(
      client: MockClient(
        (request) async => http.Response(buffer.toString(), 200),
      ),
      adFilter: const AdFilter(enabled: true),
    );
    final decision = await parser.resolve(source());
    expect(decision.isCacheable, isTrue);
    expect(decision.filterConfidence, 1.0);
    final playlist = decision.mediaPlaylist!;
    // 2500 个正片分片保留，两段共 18 个 adjump 广告分片被移除。
    expect(playlist.segments, hasLength(2500));
    expect(
      playlist.segments.every((s) => !s.uri.path.contains('adjump')),
      isTrue,
    );
    final mapping = playlist.timelineMapping!;
    // RemovedRange 按被删分片逐个记录（每段 9 片，共 18 条）。
    expect(mapping.ranges, hasLength(18));
    // 每段广告 8×3.0 + 1.76 = 25.76s。
    expect(mapping.removedMs, 25760 * 2);
    final plan = parser.buildProxyPlan(playlist, 'tok');
    expect(plan.proxyManifest, isNot(contains('adjump')));
  });
}
