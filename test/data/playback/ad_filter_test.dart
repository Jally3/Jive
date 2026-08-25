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

    test('disabled filter report is empty', () {
      final result = disabled.filter(
        playlist([seg('a', '0', 4), seg('a', '1', 4)]),
      );
      expect(result.report.removedAny, isFalse);
      expect(result.report.version, adFilterVersion);
      expect(result.report.statusText, contains('未识别到可跳过分片'));
    });

    test('mid-roll sandwich removes same-duration 75s ad block', () {
      final segments = <HlsSegment>[
        ..._run('a', 300),
        ..._run('ad', 19, disc: true),
        ..._run('b', 300, disc: true),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isTrue);
      expect(result.filtered, hasLength(600));
      expect(result.blocks.single.start, 300);
      expect(result.blocks.single.end, 318);
      expect(result.report.removedCount, 19);
      expect(result.report.removedMs, 76000);
      expect(
        result.report.hits.any(
          (hit) => hit.rule == AdFilterRule.midRollSandwich,
        ),
        isTrue,
      );
      expect(result.report.statusText, contains('已跳过 19 段，共 76 秒'));
      expect(result.report.debugLines, contains('midRollSandwich  #300–318'));
    });

    test('mid-roll sandwich ignores a 120s middle discontinuity block', () {
      final segments = <HlsSegment>[
        ..._run('a', 300),
        ..._run('ad', 30, disc: true),
        ..._run('b', 300, disc: true),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isFalse);
    });

    test(
      'mid-roll sandwich ignores a 75s block with a short left neighbor',
      () {
        final segments = <HlsSegment>[
          ..._run('a', 15),
          ..._run('ad', 19, disc: true),
          ..._run('b', 300, disc: true),
        ];
        final result = enabled.filter(playlist(segments));
        expect(result.removedAny, isFalse);
      },
    );

    test('mid-roll sandwich does not remove a leading pre-roll group', () {
      final segments = <HlsSegment>[
        ..._run('ad', 15),
        ..._run('b', 300, disc: true),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isFalse);
    });

    test('same-duration mid-roll without discontinuity is not removed', () {
      final segments = <HlsSegment>[
        ..._run('a', 300),
        ..._run('ad', 19),
        ..._run('b', 300),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isFalse);
      expect(result.report.statusText, contains('未识别到可跳过分片'));
    });

    test(
      'cadence dwarf removes undersized disc groups in a 5-seg packager',
      () {
        final segments = <HlsSegment>[
          ..._groups('a', 15, 5, discFirst: false),
          ..._adClip('ad'),
          ..._groups('b', 15, 5, discFirst: true),
        ];
        final result = enabled.filter(playlist(segments));
        expect(result.removedAny, isTrue);
        expect(result.filtered, hasLength(150));
        expect(
          result.report.hits.any(
            (hit) => hit.rule == AdFilterRule.cadenceDwarf,
          ),
          isTrue,
        );
        expect(result.report.removedCount, 4);
      },
    );

    test('cadence dwarf keeps a trailing sub-6s stub', () {
      final segments = <HlsSegment>[
        ..._groups('a', 15, 5, discFirst: false),
        seg('cdn', 'tail', 1.24, discontinuity: true),
      ];
      final result = enabled.filter(playlist(segments));
      expect(result.removedAny, isFalse);
    });

    test('cadence dwarf does not fire without a dominant group size', () {
      final segments = <HlsSegment>[
        ..._groups('a', 8, 5, discFirst: false),
        ..._groups('b', 8, 6, discFirst: true),
        ..._adClip('ad'),
        ..._groups('c', 8, 5, discFirst: true),
      ];
      final result = enabled.filter(playlist(segments));
      expect(
        result.report.hits.any((hit) => hit.rule == AdFilterRule.cadenceDwarf),
        isFalse,
      );
    });
  });
}

List<HlsSegment> _run(String prefix, int count, {bool disc = false}) => [
  for (var i = 0; i < count; i++)
    seg('cdn', '$prefix$i', 4, discontinuity: disc && i == 0),
];

List<HlsSegment> _groups(
  String prefix,
  int groupCount,
  int groupSize, {
  required bool discFirst,
}) {
  final out = <HlsSegment>[];
  var n = 0;
  for (var g = 0; g < groupCount; g++) {
    for (var i = 0; i < groupSize; i++) {
      out.add(
        seg(
          'cdn',
          '$prefix$n',
          4,
          discontinuity: i == 0 && (g > 0 || discFirst),
        ),
      );
      n++;
    }
  }
  return out;
}

/// 电影天堂中插形态：1+3 段、约 16 秒，夹在 5 段节奏组之间。
List<HlsSegment> _adClip(String prefix) => [
  seg('cdn', '${prefix}0', 6.67, discontinuity: true),
  seg('cdn', '${prefix}1', 2.13, discontinuity: true),
  seg('cdn', '${prefix}2', 3.23),
  seg('cdn', '${prefix}3', 3.73),
];
