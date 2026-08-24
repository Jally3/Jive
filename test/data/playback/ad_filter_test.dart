import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/playback/ad_filter.dart';
import 'package:jive/data/playback/hls_parser.dart';

HlsSegment seg(
  String host,
  String name,
  double duration, {
  bool discontinuity = false,
}) => HlsSegment(
  uri: Uri.parse('https://$host/$name.ts'),
  duration: duration,
  discontinuityBefore: discontinuity,
);

HlsMediaPlaylist playlist(List<HlsSegment> segments) => HlsMediaPlaylist(
  baseUri: Uri.parse('https://cdn.example.com/movie/index.m3u8'),
  segments: segments,
  raw: '',
);

void main() {
  group('TimelineMapping', () {
    test('converts source to filtered and back', () {
      final mapping = TimelineMapping([
        const RemovedRange(1000, 4000),
        const RemovedRange(7000, 9000),
      ]);
      // source 500ms < first removal
      expect(
        mapping.sourceToFiltered(const Duration(milliseconds: 500)),
        const Duration(milliseconds: 500),
      );
      // source 5000 = 4000 + 1000 of content
      expect(
        mapping.sourceToFiltered(const Duration(milliseconds: 5000)),
        const Duration(milliseconds: 2000),
      );
      // source 8000 (inside second removal) -> clamp at 7000 - 3000 = 4000
      expect(
        mapping.sourceToFiltered(const Duration(milliseconds: 8000)),
        const Duration(milliseconds: 4000),
      );
      // source 10000 -> 10000 - 5000 = 5000
      expect(
        mapping.sourceToFiltered(const Duration(milliseconds: 10000)),
        const Duration(milliseconds: 5000),
      );

      expect(
        mapping.filteredToSource(const Duration(milliseconds: 2000)),
        const Duration(milliseconds: 5000),
      );
      expect(
        mapping.filteredToSource(const Duration(milliseconds: 5000)),
        const Duration(milliseconds: 10000),
      );
      expect(mapping.removedMs, 5000);
    });
  });

  group('AdFilter', () {
    final disabled = const AdFilter(enabled: false);
    final enabled = const AdFilter(enabled: true);

    test('disabled filter is a no-op', () {
      final result = disabled.filter(
        playlist([seg('a', '0', 4), seg('a', '1', 4)]),
      );
      expect(result.removedAny, isFalse);
      expect(result.filtered, hasLength(2));
    });

    test('removes explicit marker blocks', () {
      final segments = [
        seg('cdn', '0000', 4),
        seg('cdn', 'ads/0001', 1.7),
        seg('cdn', 'ads/0002', 1.7),
        seg('cdn', 'ads/0003', 1.7),
        seg('cdn', '0004', 4),
        seg('cdn', '0005', 4),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isTrue);
      expect(result.filtered, hasLength(3));
      expect(result.filtered[0].uri.path, '/0000.ts');
      expect(result.blocks.single.start, 1);
      expect(result.blocks.single.end, 3);
    });

    test('removes short cluster blocks (>=5, mean < 50% baseline)', () {
      final segments = <HlsSegment>[
        for (var i = 0; i < 20; i++) seg('cdn', 's$i', 4),
        for (var i = 0; i < 8; i++) seg('cdn', 'a$i', 1.2),
        for (var i = 0; i < 10; i++) seg('cdn', 't$i', 4),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isTrue);
      expect(result.filtered, hasLength(30));
      expect(result.blocks, hasLength(1));
      expect(result.blocks.single.start, 20);
      expect(result.blocks.single.end, 27);
    });

    test('does not remove a few short segments (no false positive)', () {
      final segments = <HlsSegment>[
        for (var i = 0; i < 10; i++) seg('cdn', 's$i', 4),
        seg('cdn', 'cut', 2),
        seg('cdn', 'cut2', 2),
        for (var i = 0; i < 10; i++) seg('cdn', 't$i', 4),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isFalse);
    });

    test('removes discontinuity-wrapped short block (dwarf block)', () {
      final segments = <HlsSegment>[
        for (var i = 0; i < 15; i++) seg('cdn', 's$i', 4),
        seg('cdn', 'a0', 3, discontinuity: true),
        seg('cdn', 'a1', 3),
        seg('cdn', 'a2', 3),
        seg('cdn', 'a3', 3),
        for (var i = 0; i < 15; i++)
          seg('cdn', 't$i', 4, discontinuity: i == 0),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isTrue);
      expect(result.filtered, hasLength(30));
    });

    test('does not remove dominant-host content (no false positive)', () {
      final segments = <HlsSegment>[
        for (var i = 0; i < 30; i++) seg('cdn-a', 'a$i', 4),
        for (var i = 0; i < 30; i++) seg('cdn-b', 'b$i', 4),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isFalse);
    });

    test('source-to-filtered mapping removes ad durations', () {
      final segments = [
        seg('cdn', '0000', 4),
        seg('cdn', 'ads/0001', 1.7),
        seg('cdn', 'ads/0002', 1.7),
        seg('cdn', '0004', 4),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isTrue);
      // source position at 8s (all content + 3.4s ad) -> filtered 8 - 3.4 = 4.6s
      final filtered = result.mapping.sourceToFiltered(
        const Duration(milliseconds: 8000),
      );
      expect(filtered.inMilliseconds, closeTo(4600, 1));
      final back = result.mapping.filteredToSource(filtered);
      expect(back.inMilliseconds, closeTo(8000, 1));
    });
  });
}
