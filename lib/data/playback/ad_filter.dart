import 'dart:math';
import './hls_parser.dart';

const String adFilterVersion = 'adfilter-v3';

const int adTimelineVersion = 1;

abstract final class AdFilterRule {
  static const explicit = 'explicit';
  static const shortCluster = 'shortCluster';
  static const discontinuityDuration = 'discontinuityDuration';
  static const hostCluster = 'hostCluster';
  static const dwarf = 'dwarf';
  static const midRollSandwich = 'midRollSandwich';
  static const cadenceDwarf = 'cadenceDwarf';
}

class AdRuleHit {
  const AdRuleHit({
    required this.rule,
    required this.start,
    required this.end,
    required this.totalMs,
  });

  final String rule;
  final int start;
  final int end;
  final int totalMs;
}

class AdFilterReport {
  const AdFilterReport({
    required this.version,
    required this.originalCount,
    required this.removedCount,
    required this.removedMs,
    this.hits = const [],
  });

  final String version;
  final int originalCount;
  final int removedCount;
  final int removedMs;
  final List<AdRuleHit> hits;

  bool get removedAny => removedCount > 0;

  String get statusText {
    if (!removedAny) {
      return '广告过滤：未识别到可跳过分片。硬编进正片、且清单无断点的广告无法去除。';
    }
    final seconds = (removedMs / 1000).round();
    return '广告过滤：已跳过 $removedCount 段，共 $seconds 秒（$version）';
  }

  List<String> get debugLines => [
    for (final hit in hits) '${hit.rule}  #${hit.start}–${hit.end}',
  ];
}

class RemovedRange {
  const RemovedRange(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  int get lengthMs => endMs - startMs;
}

class TimelineMapping {
  TimelineMapping(List<RemovedRange> ranges)
    : _ranges = [...ranges]..sort((a, b) => a.startMs.compareTo(b.startMs));

  final List<RemovedRange> _ranges;

  List<RemovedRange> get ranges => List.unmodifiable(_ranges);

  Duration sourceToFiltered(Duration position) {
    final ms = position.inMilliseconds;
    var removed = 0;
    for (final range in _ranges) {
      if (ms <= range.startMs) break;
      removed += ms < range.endMs
          ? ms - range.startMs
          : range.endMs - range.startMs;
    }
    return Duration(milliseconds: max(0, ms - removed));
  }

  Duration filteredToSource(Duration position) {
    final ms = position.inMilliseconds;
    var removed = 0;
    for (final range in _ranges) {
      final filteredStart = range.startMs - removed;
      if (ms < filteredStart) break;
      removed += range.lengthMs;
    }
    return Duration(milliseconds: ms + removed);
  }

  int get removedMs => _ranges.fold(0, (sum, r) => sum + r.lengthMs);
}

class AdBlock {
  AdBlock(this.start, this.end, this.totalMs, this.confidence);

  final int start;
  final int end;
  final int totalMs;
  final double confidence;

  int get count => end - start + 1;
}

class AdFilterResult {
  AdFilterResult({
    required this.original,
    required this.filtered,
    required this.blocks,
    required this.mapping,
    required this.report,
  });

  final List<HlsSegment> original;
  final List<HlsSegment> filtered;
  final List<AdBlock> blocks;
  final TimelineMapping mapping;
  final AdFilterReport report;

  bool get removedAny => blocks.isNotEmpty;

  double? get confidence {
    if (blocks.isEmpty) return null;
    return blocks
        .map((block) => block.confidence)
        .reduce((low, value) => low < value ? low : value);
  }

  bool isRemoved(int index) =>
      blocks.any((block) => index >= block.start && index <= block.end);
}

class AdFilter {
  const AdFilter({this.enabled = false});

  final bool enabled;

  static const Set<String> _explicitMarkers = {
    '/ad/',
    '/ads/',
    '/adjump/',
    '/gg/',
    '/gdt/',
    '/zj/',
  };

  AdFilterResult filter(HlsMediaPlaylist playlist) {
    if (!enabled) {
      return _emptyResult(playlist.segments);
    }
    final candidates = <AdBlock>{};
    final hits = <AdRuleHit>[];
    void collect(String rule, List<AdBlock> blocks) {
      candidates.addAll(blocks);
      for (final block in blocks) {
        hits.add(
          AdRuleHit(
            rule: rule,
            start: block.start,
            end: block.end,
            totalMs: block.totalMs,
          ),
        );
      }
    }

    final baseline = _baselineDuration(playlist.segments);
    if (baseline > 0) {
      collect(
        AdFilterRule.shortCluster,
        _shortClusterBlocks(playlist, baseline),
      );
      collect(
        AdFilterRule.discontinuityDuration,
        _discontinuityDurationBlocks(playlist, baseline),
      );
      collect(AdFilterRule.hostCluster, _hostClusterBlocks(playlist));
      collect(AdFilterRule.explicit, _explicitMarkerBlocks(playlist));
      collect(AdFilterRule.dwarf, _structuralDwarfBlocks(playlist));
      collect(AdFilterRule.midRollSandwich, _midRollSandwichBlocks(playlist));
      collect(AdFilterRule.cadenceDwarf, _cadenceDwarfBlocks(playlist));
    }

    final merged = _mergeBlocks(candidates, playlist.segments);
    final removedIndices = <int>{};
    for (final block in merged) {
      for (var i = block.start; i <= block.end; i++) {
        removedIndices.add(i);
      }
    }
    final filtered = <HlsSegment>[];
    for (var i = 0; i < playlist.segments.length; i++) {
      if (!removedIndices.contains(i)) filtered.add(playlist.segments[i]);
    }

    final ranges = <RemovedRange>[];
    var cursor = 0;
    for (var i = 0; i < playlist.segments.length; i++) {
      final durationMs = _durationMs(playlist.segments[i]);
      if (removedIndices.contains(i)) {
        ranges.add(RemovedRange(cursor, cursor + durationMs));
      }
      cursor += durationMs;
    }
    final mapping = TimelineMapping(ranges);
    return AdFilterResult(
      original: playlist.segments,
      filtered: filtered,
      blocks: merged,
      mapping: mapping,
      report: AdFilterReport(
        version: adFilterVersion,
        originalCount: playlist.segments.length,
        removedCount: removedIndices.length,
        removedMs: mapping.removedMs,
        hits: hits,
      ),
    );
  }

  AdFilterResult _emptyResult(List<HlsSegment> segments) {
    return AdFilterResult(
      original: segments,
      filtered: segments,
      blocks: const [],
      mapping: TimelineMapping(const []),
      report: AdFilterReport(
        version: adFilterVersion,
        originalCount: segments.length,
        removedCount: 0,
        removedMs: 0,
      ),
    );
  }

  List<AdBlock> _shortClusterBlocks(
    HlsMediaPlaylist playlist,
    double baseline,
  ) {
    final segments = playlist.segments;
    final blocks = <AdBlock>[];
    var i = 0;
    while (i < segments.length) {
      if (_isShort(segments[i], baseline)) {
        var j = i;
        var sum = 0.0;
        while (j < segments.length && _isShort(segments[j], baseline)) {
          sum += segments[j].duration ?? 0;
          j++;
        }
        final count = j - i;
        final mean = count > 0 ? sum / count : 0;
        if (count >= 5 && mean < baseline * 0.5) {
          blocks.add(AdBlock(i, j - 1, (sum * 1000).round(), 0.8));
        }
        i = j;
      } else {
        i++;
      }
    }
    return blocks;
  }

  List<AdBlock> _discontinuityDurationBlocks(
    HlsMediaPlaylist playlist,
    double baseline,
  ) {
    final segments = playlist.segments;
    final blocks = <AdBlock>[];
    for (final indices in _discontinuityGroups(segments)) {
      if (indices.length < 2) continue;
      var sum = 0.0;
      for (final idx in indices) {
        sum += segments[idx].duration ?? 0;
      }
      final mean = sum / indices.length;
      final totalMs = (sum * 1000).round();
      if (mean < baseline * 0.65 && totalMs <= 45000) {
        blocks.add(AdBlock(indices.first, indices.last, totalMs, 0.7));
      }
    }
    return blocks;
  }

  List<AdBlock> _hostClusterBlocks(HlsMediaPlaylist playlist) {
    final segments = playlist.segments;
    if (segments.isEmpty) return const [];
    final counts = <String, int>{};
    for (final segment in segments) {
      final host = segment.uri.host;
      counts[host] = (counts[host] ?? 0) + 1;
    }
    String? dominant;
    var dominantCount = 0;
    counts.forEach((host, count) {
      if (count > dominantCount) {
        dominant = host;
        dominantCount = count;
      }
    });
    if (dominant == null || dominantCount <= segments.length * 0.7) {
      return const [];
    }
    final blocks = <AdBlock>[];
    var i = 0;
    while (i < segments.length) {
      if (segments[i].uri.host != dominant) {
        var j = i;
        var sum = 0.0;
        while (j < segments.length && segments[j].uri.host != dominant) {
          sum += segments[j].duration ?? 0;
          j++;
        }
        final count = j - i;
        final totalMs = (sum * 1000).round();
        if (count <= 15 && totalMs <= 45000) {
          blocks.add(AdBlock(i, j - 1, totalMs, 0.6));
        }
        i = j;
      } else {
        i++;
      }
    }
    return blocks;
  }

  List<AdBlock> _explicitMarkerBlocks(HlsMediaPlaylist playlist) {
    final segments = playlist.segments;
    final blocks = <AdBlock>[];
    var i = 0;
    while (i < segments.length) {
      if (_hasExplicitMarker(segments[i])) {
        var j = i;
        var sum = 0.0;
        while (j < segments.length && _hasExplicitMarker(segments[j])) {
          sum += segments[j].duration ?? 0;
          j++;
        }
        blocks.add(AdBlock(i, j - 1, (sum * 1000).round(), 1.0));
        i = j;
      } else {
        i++;
      }
    }
    return blocks;
  }

  List<AdBlock> _structuralDwarfBlocks(HlsMediaPlaylist playlist) {
    final segments = playlist.segments;
    final groups = _discontinuityGroups(segments);
    if (groups.length < 3) return const [];

    final blocks = <AdBlock>[];
    for (var g = 1; g < groups.length - 1; g++) {
      final indices = groups[g];
      final prev = groups[g - 1];
      final next = groups[g + 1];
      final totalMs = _groupDurationMs(segments, indices);
      if (indices.length <= 8 &&
          totalMs <= 45000 &&
          prev.length >= 15 &&
          next.length >= 15) {
        blocks.add(AdBlock(indices.first, indices.last, totalMs, 0.5));
      }
    }
    return blocks;
  }

  /// Mid-roll SSAI: a 12–90s discontinuity group sandwiched between two
  /// long content groups. Does not touch the first or last group.
  List<AdBlock> _midRollSandwichBlocks(HlsMediaPlaylist playlist) {
    final segments = playlist.segments;
    final groups = _discontinuityGroups(segments);
    if (groups.length < 3) return const [];

    final blocks = <AdBlock>[];
    for (var g = 1; g < groups.length - 1; g++) {
      final indices = groups[g];
      final totalMs = _groupDurationMs(segments, indices);
      if (totalMs < 12000 || totalMs > 90000) continue;
      if (_groupDurationMs(segments, groups[g - 1]) < 120000) continue;
      if (_groupDurationMs(segments, groups[g + 1]) < 120000) continue;
      blocks.add(AdBlock(indices.first, indices.last, totalMs, 0.6));
    }
    return blocks;
  }

  /// Dense-discontinuity packagers (电影天堂 etc.) stamp DISCONTINUITY on
  /// every ~5 content segments. Ads show up as runs of groups smaller than
  /// that cadence, typically 6–20s. Only fires when one group size owns
  /// ≥70% of groups, so mixed playlists are left alone.
  List<AdBlock> _cadenceDwarfBlocks(HlsMediaPlaylist playlist) {
    final segments = playlist.segments;
    final groups = _discontinuityGroups(segments);
    if (groups.length < 8) return const [];

    final counts = <int, int>{};
    for (final group in groups) {
      counts[group.length] = (counts[group.length] ?? 0) + 1;
    }
    var cadence = 0;
    var cadenceCount = 0;
    counts.forEach((size, count) {
      if (count > cadenceCount) {
        cadence = size;
        cadenceCount = count;
      }
    });
    if (cadence < 4 || cadenceCount < groups.length * 0.7) {
      return const [];
    }

    final undersized = <int>[];
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].length < cadence) undersized.add(g);
    }
    if (undersized.isEmpty) return const [];

    final blocks = <AdBlock>[];
    var i = 0;
    while (i < undersized.length) {
      var j = i;
      while (j + 1 < undersized.length &&
          undersized[j + 1] == undersized[j] + 1) {
        j++;
      }
      final firstGroup = undersized[i];
      final lastGroup = undersized[j];
      final start = groups[firstGroup].first;
      final end = groups[lastGroup].last;
      var sum = 0.0;
      for (var idx = start; idx <= end; idx++) {
        sum += segments[idx].duration ?? 0;
      }
      final totalMs = (sum * 1000).round();
      final isTrailingStub =
          lastGroup == groups.length - 1 && firstGroup == lastGroup;
      if (totalMs >= 6000 && totalMs <= 45000 && !isTrailingStub) {
        blocks.add(AdBlock(start, end, totalMs, 0.65));
      }
      i = j + 1;
    }
    return blocks;
  }

  List<AdBlock> _mergeBlocks(
    Set<AdBlock> candidates,
    List<HlsSegment> segments,
  ) {
    if (candidates.isEmpty) return const [];
    final sorted = candidates.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final merged = <AdBlock>[];
    var current = sorted.first;
    for (var i = 1; i < sorted.length; i++) {
      final next = sorted[i];
      if (next.start <= current.end + 1) {
        final end = max(current.end, next.end);
        var sum = 0.0;
        for (var idx = current.start; idx <= end; idx++) {
          sum += segments[idx].duration ?? 0;
        }
        current = AdBlock(
          current.start,
          end,
          (sum * 1000).round(),
          max(current.confidence, next.confidence),
        );
      } else {
        merged.add(current);
        current = next;
      }
    }
    merged.add(current);
    return merged;
  }

  static List<List<int>> _discontinuityGroups(List<HlsSegment> segments) {
    if (segments.isEmpty) return const [];
    final groups = <List<int>>[];
    var group = <int>[0];
    for (var i = 1; i < segments.length; i++) {
      if (segments[i].discontinuityBefore) {
        groups.add(group);
        group = [i];
      } else {
        group.add(i);
      }
    }
    groups.add(group);
    return groups;
  }

  static int _groupDurationMs(List<HlsSegment> segments, List<int> indices) {
    var sum = 0.0;
    for (final idx in indices) {
      sum += segments[idx].duration ?? 0;
    }
    return (sum * 1000).round();
  }

  static bool _isShort(HlsSegment segment, double baseline) {
    final duration = segment.duration;
    if (duration == null || baseline <= 0) return false;
    return duration < baseline * 0.7;
  }

  static double _baselineDuration(List<HlsSegment> segments) {
    final durations = segments
        .map((s) => s.duration)
        .whereType<double>()
        .where((d) => d > 0)
        .toList();
    if (durations.isEmpty) return 0;
    durations.sort();
    return durations[durations.length ~/ 2];
  }

  static bool _hasExplicitMarker(HlsSegment segment) {
    final path = segment.uri.path.toLowerCase();
    final query = segment.uri.query.toLowerCase();
    for (final marker in _explicitMarkers) {
      if (path.contains(marker) || query.contains('adjump')) return true;
    }
    return false;
  }

  static int _durationMs(HlsSegment segment) {
    final duration = segment.duration;
    return duration == null ? 0 : (duration * 1000).round();
  }
}
