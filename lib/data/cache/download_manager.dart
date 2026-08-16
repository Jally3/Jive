import 'dart:math';
import 'cache_io.dart';
import 'hls_parser.dart';

class SegmentPrefetcher {
  SegmentPrefetcher({
    required this.fetcher,
    required this.segments,
    this.concurrency = 5,
    this.isWifi,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 8),
  });

  final ResourceFetcher fetcher;
  final List<HlsSegment> segments;
  final int concurrency;

  /// 返回当前是否处于 Wi-Fi；为 null 表示未知，未知时**不主动预取**。
  final bool Function()? isWifi;
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;

  bool _paused = false;
  bool _cancelled = false;
  int _nextIndex = 0;
  final Set<String> _done = {};
  final Set<int> _inFlight = {};
  final Random _random = Random();

  void pause() => _paused = true;

  void resume() => _paused = false;

  void cancel() => _cancelled = true;

  Future<void> prefetch({int lookahead = 30, Duration? fromPosition}) async {
    if (_cancelled || segments.isEmpty) return;
    final wifi = isWifi;
    if (wifi == null || !wifi()) return;
    if (_nextIndex == 0 && fromPosition != null) {
      _nextIndex = _indexAt(fromPosition);
    }
    final end = min(_nextIndex + lookahead, segments.length);
    while (_nextIndex < end) {
      if (_cancelled || _paused) return;
      final batch = <Future<void>>[];
      while (_nextIndex < end && batch.length < concurrency) {
        final index = _nextIndex++;
        if (_inFlight.contains(index)) continue;
        batch.add(_prefetchOne(index));
      }
      if (batch.isNotEmpty) await Future.wait(batch);
    }
  }

  Future<void> _prefetchOne(int index) async {
    if (_cancelled || index >= segments.length) return;
    _inFlight.add(index);
    try {
      final segment = segments[index];
      final resourceId = HlsParser.resourceId(segment.uri);
      if (_done.contains(resourceId)) return;
      final manager = fetcher.manager;
      final entryKey = fetcher.entryKey;
      if (manager != null && entryKey != null) {
        final record = await manager.resourceRecord(entryKey, resourceId);
        if (record != null && record.complete) {
          _done.add(resourceId);
          return;
        }
      }
      await _fetchWithRetry(segment, resourceId, 0);
      _done.add(resourceId);
    } catch (_) {
    } finally {
      _inFlight.remove(index);
    }
  }

  Future<void> _fetchWithRetry(
    HlsSegment segment,
    String resourceId,
    int attempt,
  ) async {
    try {
      final result = await fetcher.fetch(
        origin: segment.uri,
        resourceId: resourceId,
        ext: HlsParser.extFor(segment.uri),
      );
      if (result.statusCode >= 400 && result.statusCode < 500) {
        await result.body.drain<void>();
        return;
      }
      await result.body.drain<void>();
    } catch (_) {
      if (attempt + 1 < maxAttempts && !_cancelled) {
        await Future<void>.delayed(_backoff(attempt));
        await _fetchWithRetry(segment, resourceId, attempt + 1);
      }
    }
  }

  Duration _backoff(int attempt) {
    final exponential = min(
      maxBackoff.inMilliseconds,
      baseBackoff.inMilliseconds * (1 << attempt),
    );
    final jitter = _random.nextInt(exponential ~/ 4 + 1);
    return Duration(milliseconds: exponential + jitter);
  }

  int _indexAt(Duration position) {
    if (position <= Duration.zero) return 0;
    var acc = Duration.zero;
    for (var i = 0; i < segments.length; i++) {
      final duration = segments[i].duration == null
          ? const Duration(seconds: 4)
          : Duration(milliseconds: (segments[i].duration! * 1000).round());
      if (position < acc + duration) return i;
      acc += duration;
    }
    return segments.length - 1;
  }
}
