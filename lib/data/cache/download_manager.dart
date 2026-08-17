import 'dart:math';
import 'cache_io.dart';
import 'hls_parser.dart';

class SegmentPrefetcher {
  SegmentPrefetcher({
    required this.fetcher,
    required this.segments,
    this.concurrency = 5,
    int Function()? windowSize,
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 8),
  }) : windowSize = windowSize ?? (() => 30);

  final ResourceFetcher fetcher;
  final List<HlsSegment> segments;
  final int concurrency;

  /// 当前预取窗口大小（片数），每次调度时读取以支持随网络/设置动态变化；
  /// 返回 0 表示暂停预取（如蜂窝网络下用户关闭了预加载）。
  final int Function() windowSize;
  final int maxAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;

  bool _paused = false;
  bool _cancelled = false;
  bool _running = false;
  int _nextIndex = 0;
  Duration? _pendingPosition;
  final Set<String> _done = {};
  final Set<int> _inFlight = {};
  final Random _random = Random();

  void pause() => _paused = true;

  void resume() => _paused = false;

  void cancel() => _cancelled = true;

  /// 播放位置变化（seek 或周期性进度上报）时重锚定预取窗口。
  /// 正在运行的预取循环会在当前批次结束后按新位置重排。
  /// 返回的 Future 在本次触发调度时完成；已有循环在跑时立即返回，
  /// 由运行中的循环在批次边界消费新位置。
  Future<void> updatePosition(Duration position) async {
    _pendingPosition = position;
    if (!_running && !_cancelled && !_paused) {
      await prefetch();
    }
  }

  /// 预取一个窗口。可通过 [fromPosition] 指定起点（起播/恢复）；
  /// [lookahead] 为测试用的显式窗口覆盖，缺省读 [windowSize]。
  Future<void> prefetch({int? lookahead, Duration? fromPosition}) async {
    if (fromPosition != null) _pendingPosition = fromPosition;
    if (_cancelled || segments.isEmpty || _running) return;
    _running = true;
    var didWork = false;
    try {
      while (!_cancelled && !_paused) {
        final pending = _pendingPosition;
        if (pending != null) {
          _pendingPosition = null;
          _nextIndex = _indexAt(pending);
        } else if (didWork) {
          // 完成一个窗口后没有新指令：退出，等待下次调度。
          break;
        }
        final window = lookahead ?? windowSize();
        if (window <= 0) break;
        final end = min(_nextIndex + window, segments.length);
        while (_nextIndex < end &&
            !_cancelled &&
            !_paused &&
            _pendingPosition == null) {
          final batch = <Future<void>>[];
          while (_nextIndex < end && batch.length < concurrency) {
            final index = _nextIndex++;
            if (_inFlight.contains(index)) continue;
            batch.add(_prefetchOne(index));
          }
          if (batch.isNotEmpty) await Future.wait(batch);
        }
        didWork = true;
      }
    } finally {
      _running = false;
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
