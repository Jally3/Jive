import 'dart:convert';

final class PlaybackTraceStageReport {
  const PlaybackTraceStageReport({
    required this.name,
    required this.durationMs,
    required this.result,
  });

  final String name;
  final double durationMs;
  final String result;
}

final class PlaybackTraceReport {
  const PlaybackTraceReport({
    required this.traceId,
    required this.result,
    required this.totalStartupMs,
    required this.videoTitle,
    required this.sourceId,
    required this.episodeName,
    required this.format,
    required this.mode,
    required this.stages,
    required this.raw,
  });

  final String traceId;
  final String result;
  final double totalStartupMs;
  final String videoTitle;
  final String sourceId;
  final String episodeName;
  final String format;
  final String mode;
  final List<PlaybackTraceStageReport> stages;
  final Map<String, Object?> raw;

  List<PlaybackTraceStageReport> get ranking {
    final sorted = [...stages];
    sorted.sort((a, b) => b.durationMs.compareTo(a.durationMs));
    return sorted;
  }

  static PlaybackTraceReport fromJson(Map<String, Object?> json) {
    if (json['tag'] != 'JIVE_PLAYBACK_TRACE') {
      throw const FormatException('不是 JIVE 播放启动日志');
    }
    final video = _map(json['video']);
    final episode = _map(json['episode']);
    final playback = _map(json['playback']);
    final stages = <PlaybackTraceStageReport>[];
    final rawStages = json['stages'];
    if (rawStages is List) {
      for (final item in rawStages) {
        final stage = _map(item);
        final name = stage['name'];
        final duration = stage['durationMs'];
        if (name is! String || duration is! num) continue;
        stages.add(
          PlaybackTraceStageReport(
            name: name,
            durationMs: duration.toDouble(),
            result: stage['result']?.toString() ?? 'unknown',
          ),
        );
      }
    }
    return PlaybackTraceReport(
      traceId: json['traceId']?.toString() ?? '',
      result: json['result']?.toString() ?? 'unknown',
      totalStartupMs: (json['totalStartupMs'] as num?)?.toDouble() ?? 0,
      videoTitle: video['title']?.toString() ?? '未知视频',
      sourceId: video['sourceId']?.toString() ?? '',
      episodeName: episode['name']?.toString() ?? '未知剧集',
      format: playback['format']?.toString() ?? 'unknown',
      mode: playback['mode']?.toString() ?? 'unknown',
      stages: stages,
      raw: json,
    );
  }
}

List<PlaybackTraceReport> parsePlaybackTraceLogs(String input) {
  final text = input.trim();
  if (text.isEmpty) throw const FormatException('请先粘贴日志');

  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    decoded = null;
  }
  if (decoded != null) return _reportsFromDecoded(decoded);

  final reports = <PlaybackTraceReport>[..._parseChunkedLogs(text)];
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final jsonStart = line.indexOf('{');
    if (jsonStart < 0) continue;
    try {
      reports.addAll(
        _reportsFromDecoded(jsonDecode(line.substring(jsonStart))),
      );
    } catch (_) {
      // Console output may contain unrelated lines; skip them.
    }
  }
  if (reports.isEmpty) {
    throw const FormatException('没有找到有效的 JIVE 播放启动日志');
  }
  return reports;
}

List<PlaybackTraceReport> _parseChunkedLogs(String text) {
  final chunks = <String, Map<int, String>>{};
  final totals = <String, int>{};
  final pattern = RegExp(
    r'JIVE_PLAYBACK_TRACE_CHUNK\s+(\S+)\s+(\d+)/(\d+)\s+([A-Za-z0-9+/=]+)',
  );
  for (final match in pattern.allMatches(text)) {
    final traceId = match.group(1)!;
    final index = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    chunks.putIfAbsent(traceId, () => {})[index] = match.group(4)!;
    totals[traceId] = total;
  }
  final reports = <PlaybackTraceReport>[];
  for (final entry in chunks.entries) {
    final total = totals[entry.key] ?? 0;
    if (total == 0 || entry.value.length != total) continue;
    try {
      final payload = [
        for (var index = 1; index <= total; index++) entry.value[index]!,
      ].join();
      final decoded = jsonDecode(utf8.decode(base64Decode(payload)));
      reports.addAll(_reportsFromDecoded(decoded));
    } catch (_) {
      // Incomplete or damaged console selections are reported by the caller.
    }
  }
  return reports;
}

List<PlaybackTraceReport> _reportsFromDecoded(Object? decoded) {
  final values = decoded is List ? decoded : [decoded];
  final reports = <PlaybackTraceReport>[];
  for (final value in values) {
    final map = _map(value);
    if (map.isEmpty) continue;
    reports.add(PlaybackTraceReport.fromJson(map));
  }
  if (reports.isEmpty) throw const FormatException('日志内容为空');
  return reports;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, value) => MapEntry(key.toString(), value));
}
