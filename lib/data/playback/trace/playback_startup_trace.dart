import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../../domain/video.dart';
import 'playback_trace_config.dart';

final class PlaybackTraceSpan {
  PlaybackTraceSpan._(this.name, this.stopwatch, this.metadata);

  final String name;
  final Stopwatch stopwatch;
  final Map<String, Object?> metadata;
  bool finished = false;
}

/// A best-effort, in-memory trace covering only startup-to-play.
///
/// Logging never participates in playback control flow: every public method is
/// guarded and swallows its own failures. A trace emits exactly one JSON object
/// when startup succeeds, fails, or is cancelled.
final class PlaybackStartupTrace {
  PlaybackStartupTrace._({
    required String videoTitle,
    required String sourceId,
    required String sourceVideoId,
    required Episode episode,
    required bool offlineOnly,
  }) : traceId = 'pb-${DateTime.now().microsecondsSinceEpoch}',
       _videoTitle = videoTitle,
       _sourceId = sourceId,
       _sourceVideoId = sourceVideoId,
       _episodeId = episode.id,
       _episodeName = episode.name,
       _offlineOnly = offlineOnly {
    _total.start();
  }

  static PlaybackStartupTrace? maybeStart({
    required String videoTitle,
    required String sourceId,
    required String sourceVideoId,
    required Episode episode,
    required bool offlineOnly,
  }) {
    if (!PlaybackTraceConfig.enabled) return null;
    return PlaybackStartupTrace._(
      videoTitle: videoTitle,
      sourceId: sourceId,
      sourceVideoId: sourceVideoId,
      episode: episode,
      offlineOnly: offlineOnly,
    );
  }

  final String traceId;
  final Stopwatch _total = Stopwatch();
  final List<Map<String, Object?>> _stages = [];
  final List<PlaybackTraceSpan> _openSpans = [];
  final Map<String, Object?> _proxyManifestTrace = {};
  final Map<int, Map<String, Object?>> _proxyResourceTraces = {};
  final String _videoTitle;
  final String _sourceId;
  final String _sourceVideoId;
  String _episodeId;
  String _episodeName;
  final bool _offlineOnly;
  bool _finished = false;
  String? _format;
  String? _playbackMode;
  bool? _usedProxy;

  bool get isFinished => _finished;

  /// Collects best-effort proxy/cache diagnostics for at most the first few
  /// startup resources. The proxy owns sampling; this method only aggregates
  /// events and never throws into playback code.
  void recordStartupIoEvent(Map<String, Object?> event) {
    if (_finished) return;
    try {
      final eventName = event['event'];
      if (eventName is! String) return;
      final nowMs = _total.elapsedMicroseconds / 1000;
      final resourceIndex = event['resourceIndex'];
      final values = Map<String, Object?>.from(event)
        ..remove('event')
        ..remove('resourceIndex');
      if (resourceIndex is int) {
        final resource = _proxyResourceTraces.putIfAbsent(
          resourceIndex,
          () => {'index': resourceIndex},
        );
        if (eventName == 'resourceStart') {
          resource.addAll(values);
          resource['startedAtMs'] = nowMs;
        } else {
          resource[eventName] = values;
        }
        return;
      }
      if (eventName == 'proxyManifestReceived') {
        _proxyManifestTrace['receivedAtMs'] = nowMs;
      } else if (eventName == 'proxyManifestResponse') {
        _proxyManifestTrace.addAll(values);
        _proxyManifestTrace['completedAtMs'] = nowMs;
      }
    } catch (_) {}
  }

  void updateEpisode(Episode episode) {
    if (_finished) return;
    _episodeId = episode.id;
    _episodeName = episode.name;
  }

  void updatePlayback({String? format, String? mode, bool? usedProxy}) {
    if (_finished) return;
    _format = format ?? _format;
    _playbackMode = mode ?? _playbackMode;
    _usedProxy = usedProxy ?? _usedProxy;
  }

  PlaybackTraceSpan? startStage(
    String name, {
    Map<String, Object?> metadata = const {},
  }) {
    if (_finished) return null;
    try {
      final span = PlaybackTraceSpan._(
        name,
        Stopwatch()..start(),
        Map<String, Object?>.from(metadata),
      );
      _openSpans.add(span);
      return span;
    } catch (_) {
      return null;
    }
  }

  void finishStage(
    PlaybackTraceSpan? span, {
    String result = 'success',
    Map<String, Object?> metadata = const {},
  }) {
    if (_finished || span == null || span.finished) return;
    try {
      span.finished = true;
      span.stopwatch.stop();
      _openSpans.remove(span);
      _stages.add({
        'name': span.name,
        'durationMs': span.stopwatch.elapsedMicroseconds / 1000,
        'result': result,
        if (span.metadata.isNotEmpty || metadata.isNotEmpty)
          'metadata': {...span.metadata, ...metadata},
      });
    } catch (_) {}
  }

  void complete() => _finish('success');

  void fail(Object error, {String? failedStage}) => _finish(
    'failed',
    errorType: error.runtimeType.toString(),
    failedStage: failedStage,
  );

  void cancel() => _finish('cancelled');

  void _finish(String result, {String? errorType, String? failedStage}) {
    if (_finished) return;
    try {
      for (final span in List<PlaybackTraceSpan>.of(_openSpans)) {
        finishStage(span, result: result == 'failed' ? 'failed' : 'cancelled');
      }
      _finished = true;
      _total.stop();
      final ranked = [..._stages]
        ..sort(
          (a, b) => ((b['durationMs'] as num?) ?? 0).compareTo(
            (a['durationMs'] as num?) ?? 0,
          ),
        );
      final summary = <String, Object?>{
        'tag': 'JIVE_PLAYBACK_TRACE',
        'schemaVersion': 2,
        'traceId': traceId,
        'result': result,
        'totalStartupMs': _total.elapsedMicroseconds / 1000,
        'video': {
          'title': _videoTitle,
          'sourceId': _sourceId,
          // Identity is useful for comparison but URLs and headers are never
          // captured. Keep the raw ID local to the developer console only.
          'sourceVideoId': _sourceVideoId,
        },
        'episode': {'id': _episodeId, 'name': _episodeName},
        'playback': {
          'offlineOnly': _offlineOnly,
          if (_format != null) 'format': _format,
          if (_playbackMode != null) 'mode': _playbackMode,
          if (_usedProxy != null) 'usedProxy': _usedProxy,
        },
        'stages': _stages,
        if (_proxyManifestTrace.isNotEmpty || _proxyResourceTraces.isNotEmpty)
          'startupIo': {
            if (_proxyManifestTrace.isNotEmpty)
              'proxyManifest': _proxyManifestTrace,
            if (_proxyResourceTraces.isNotEmpty)
              'resources': [
                for (final entry
                    in (_proxyResourceTraces.entries.toList()
                      ..sort((a, b) => a.key.compareTo(b.key))))
                  entry.value,
              ],
          },
        if (ranked.isNotEmpty) 'slowest': ranked.first,
        if (failedStage != null) 'failedStage': failedStage,
        if (errorType != null) 'errorType': errorType,
      };
      final encoded = jsonEncode(summary);
      // developer.log is useful in DevTools but is not guaranteed to appear in
      // `flutter run` output. debugPrint makes the same importable JSON visible
      // in the terminal used to launch the app.
      developer.log(encoded, name: 'JIVE_PLAYBACK_TRACE');
      _printTerminalChunks(encoded, ranked, result);
    } catch (_) {
      // Diagnostics must never affect playback.
    }
  }

  void _printTerminalChunks(
    String encoded,
    List<Map<String, Object?>> ranked,
    String result,
  ) {
    const chunkSize = 700;
    final payload = base64Encode(utf8.encode(encoded));
    final chunkCount = (payload.length / chunkSize).ceil();
    for (var index = 0; index < chunkCount; index++) {
      final start = index * chunkSize;
      final end = start + chunkSize < payload.length
          ? start + chunkSize
          : payload.length;
      debugPrint(
        'JIVE_PLAYBACK_TRACE_CHUNK $traceId ${index + 1}/$chunkCount '
        '${payload.substring(start, end)}',
      );
    }
    final slowest = ranked.isEmpty ? null : ranked.first;
    debugPrint(
      'JIVE_PLAYBACK_TRACE_SUMMARY traceId=$traceId '
      'result=$result '
      'totalMs=${_total.elapsedMicroseconds / 1000} '
      'slowest=${slowest?['name'] ?? 'none'} '
      'slowestMs=${slowest?['durationMs'] ?? 0}',
    );
  }
}
