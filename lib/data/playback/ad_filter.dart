import 'dart:math';
import './hls_parser.dart';

/// 广告识别规则版本。修改规则阈值或含义时应递增，便于诊断缓存差异。
const String adFilterVersion = 'adfilter-v3';

/// 原始时间轴与过滤后时间轴的映射格式版本。
const int adTimelineVersion = 1;

/// 广告规则的稳定标识，用于调试报告而非面向用户展示。
abstract final class AdFilterRule {
  static const explicit = 'explicit';
  static const shortCluster = 'shortCluster';
  static const discontinuityDuration = 'discontinuityDuration';
  static const hostCluster = 'hostCluster';
  static const dwarf = 'dwarf';
  static const midRollSandwich = 'midRollSandwich';
  static const cadenceDwarf = 'cadenceDwarf';
}

/// 一次规则命中记录；start/end 均为原始清单中的闭区间分片下标。
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

/// 一次清单过滤的汇总报告，供界面提示和问题诊断使用。
class AdFilterReport {
  /// [originalCount]/[removedCount] 是分片数量，[removedMs] 是移除总时长。
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

  /// 生成人类可读的过滤结果说明。
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

/// 原始播放时间轴上被删除的一段半开区间 `[startMs, endMs)`。
class RemovedRange {
  const RemovedRange(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  int get lengthMs => endMs - startMs;
}

/// 在原始清单时间轴与过滤后播放时间轴之间双向换算。
class TimelineMapping {
  /// [ranges] 可以无序传入，构造时会按起点排序。
  TimelineMapping(List<RemovedRange> ranges)
    : _ranges = [...ranges]..sort((a, b) => a.startMs.compareTo(b.startMs));

  final List<RemovedRange> _ranges;

  List<RemovedRange> get ranges => List.unmodifiable(_ranges);

  /// 把原始源位置 [position] 映射为删除广告后的播放器位置。
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

  /// 把过滤后播放器位置 [position] 还原到原始源时间轴。
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

/// 一个待删除的连续广告分片块，start/end 是闭区间下标。
class AdBlock {
  /// [confidence] 取值 0～1，越大表示规则判断越确定。
  AdBlock(this.start, this.end, this.totalMs, this.confidence);

  final int start;
  final int end;
  final int totalMs;
  final double confidence;

  int get count => end - start + 1;
}

/// 广告过滤结果，包含新分片列表、删除块、时间映射和诊断报告。
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

  /// 返回所有广告块中的最低置信度，表示整次过滤的保守可信程度。
  double? get confidence {
    if (blocks.isEmpty) return null;
    return blocks
        .map((block) => block.confidence)
        .reduce((low, value) => low < value ? low : value);
  }

  /// 判断原清单中的 [index] 是否落在任一删除块内。
  bool isRemoved(int index) =>
      blocks.any((block) => index >= block.start && index <= block.end);
}

/// 基于 HLS 分片结构、时长、域名和显式标记的启发式广告过滤器。
class AdFilter {
  /// [enabled] 默认为 false，避免未经用户/产品开启就改变播放内容。
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

  /// 对 [playlist] 运行全部规则，合并重叠候选并生成时间轴映射。
  ///
  /// 过滤器关闭或没有命中时仍返回完整报告，方便上层统一展示。
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

  /// 构造“未删除任何分片”的标准结果。
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

  /// 识别连续短分片簇；[baseline] 是整份清单分片时长的中位数。
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

  /// 识别由 DISCONTINUITY 划分、且明显短于基准时长的分组。
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

  /// 当多数分片来自同一域名时，将短小的异域名连续段视为候选广告。
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

  /// 识别 URL 路径或查询参数中包含明确广告标记的连续分片。
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

  /// 识别夹在两个大型内容组之间的短小 DISCONTINUITY 分组。
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

  /// 识别 SSAI 中插广告：12～90 秒且夹在两个至少 120 秒内容组之间。
  /// 首组和末组不会被此规则删除，避免误伤片头片尾内容。
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

  /// 识别高密度断点清单中的“小节奏组”广告。
  ///
  /// 只有某一正常组大小占比达到 70% 才启用；比该节奏更短、总长 6～45 秒的
  /// 连续组会成为候选，混合结构清单保持不动以降低误删风险。
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

  /// 合并重叠或相邻的候选块，并按真实分片时长重新计算总时长。
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

  /// 根据每个分片前的 discontinuity 标记，将清单拆成连续分组。
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

  /// 汇总指定 [indices] 分片的毫秒时长。
  static int _groupDurationMs(List<HlsSegment> segments, List<int> indices) {
    var sum = 0.0;
    for (final idx in indices) {
      sum += segments[idx].duration ?? 0;
    }
    return (sum * 1000).round();
  }

  /// 判断单个分片是否显著短于 [baseline]。
  static bool _isShort(HlsSegment segment, double baseline) {
    final duration = segment.duration;
    if (duration == null || baseline <= 0) return false;
    return duration < baseline * 0.7;
  }

  /// 以分片时长中位数作为正常内容基准，降低极端值干扰。
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

  /// 检查分片 URL 是否带有已知广告路径或查询标记。
  static bool _hasExplicitMarker(HlsSegment segment) {
    final path = segment.uri.path.toLowerCase();
    final query = segment.uri.query.toLowerCase();
    for (final marker in _explicitMarkers) {
      if (path.contains(marker) || query.contains('adjump')) return true;
    }
    return false;
  }

  /// 将分片秒数安全转换为毫秒；未知时长按 0 处理。
  static int _durationMs(HlsSegment segment) {
    final duration = segment.duration;
    return duration == null ? 0 : (duration * 1000).round();
  }
}
