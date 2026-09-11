import 'dart:async';
import 'dart:collection';

import '../../domain/video.dart';
import '../../domain/vod_source.dart';

enum SearchCacheMode { preferCache, refresh }

enum SearchReuseKind { network, cache, joinedInflight }

class PooledSearchResult {
  const PooledSearchResult({required this.page, required this.reuseKind});

  final VideoPage page;
  final SearchReuseKind reuseKind;
}

class CuratedVodSearchKey {
  const CuratedVodSearchKey({
    required this.sourceFingerprint,
    required this.normalizedQuery,
  });

  final String sourceFingerprint;
  final String normalizedQuery;

  @override
  bool operator ==(Object other) =>
      other is CuratedVodSearchKey &&
      sourceFingerprint == other.sourceFingerprint &&
      normalizedQuery == other.normalizedQuery;

  @override
  int get hashCode => Object.hash(sourceFingerprint, normalizedQuery);
}

String curatedVodSourceFingerprint(VodSource source) => [
  source.id,
  source.adapterType,
  source.baseUri.toString(),
  source.pluginConfigUri?.toString() ?? '',
].join('|');

String normalizeCuratedVodQuery(String query) =>
    query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

typedef CuratedVodSearchLoader =
    Future<VideoPage> Function(Future<void> abortTrigger);

abstract interface class CuratedVodSearchLease {
  Future<PooledSearchResult> get future;
  SearchReuseKind get reuseKind;
  void release();
}

class CuratedVodSearchPool {
  CuratedVodSearchPool({
    this.maxConcurrentRequests = 3,
    this.maxReadyEntries = 64,
    this.maxReadySources = 3,
    this.successTtl = const Duration(minutes: 5),
    this.emptyTtl = const Duration(seconds: 90),
    this.requestTimeout = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxConcurrentRequests;
  final int maxReadyEntries;
  final int maxReadySources;
  final Duration successTtl;
  final Duration emptyTtl;
  final Duration requestTimeout;
  final DateTime Function() _now;

  final Map<CuratedVodSearchKey, _PoolEntry> _entries = {};
  final Queue<_PoolEntry> _queue = Queue<_PoolEntry>();
  int _activeRequests = 0;
  bool _closed = false;

  int get activeRequests => _activeRequests;
  int get readyEntryCount =>
      _entries.values.where((entry) => entry.state == _PoolState.ready).length;

  /// Reads a completed cache entry synchronously without creating a lease.
  PooledSearchResult? peekReady({
    required String sourceFingerprint,
    required String query,
    bool touch = true,
  }) {
    if (_closed) return null;
    _pruneExpired();
    final entry =
        _entries[CuratedVodSearchKey(
          sourceFingerprint: sourceFingerprint,
          normalizedQuery: normalizeCuratedVodQuery(query),
        )];
    if (entry == null || entry.state != _PoolState.ready) return null;
    if (touch) entry.lastAccessedAt = _now();
    return PooledSearchResult(
      page: entry.page!,
      reuseKind: SearchReuseKind.cache,
    );
  }

  SearchReuseKind? reuseKindFor({
    required String sourceFingerprint,
    required String query,
    SearchCacheMode mode = SearchCacheMode.preferCache,
  }) {
    if (_closed) return null;
    _pruneExpired();
    final entry =
        _entries[CuratedVodSearchKey(
          sourceFingerprint: sourceFingerprint,
          normalizedQuery: normalizeCuratedVodQuery(query),
        )];
    if (entry == null) return null;
    if (entry.state == _PoolState.ready) {
      return mode == SearchCacheMode.preferCache ? SearchReuseKind.cache : null;
    }
    return SearchReuseKind.joinedInflight;
  }

  CuratedVodSearchLease acquire({
    required String sourceFingerprint,
    required String query,
    required CuratedVodSearchLoader loader,
    SearchCacheMode mode = SearchCacheMode.preferCache,
  }) {
    if (_closed) throw StateError('VOD 搜索池已关闭');
    final normalizedQuery = normalizeCuratedVodQuery(query);
    if (normalizedQuery.isEmpty) throw ArgumentError.value(query, 'query');
    _pruneExpired();
    final key = CuratedVodSearchKey(
      sourceFingerprint: sourceFingerprint,
      normalizedQuery: normalizedQuery,
    );
    final existing = _entries[key];
    if (existing != null && existing.state == _PoolState.ready) {
      if (mode == SearchCacheMode.preferCache) {
        existing.lastAccessedAt = _now();
        return _ReadyLease(existing.page!);
      }
      _entries.remove(key);
    } else if (existing != null) {
      existing.subscribers++;
      existing.lastAccessedAt = _now();
      return _EntryLease(existing, SearchReuseKind.joinedInflight, _release);
    }

    final entry = _PoolEntry(key: key, loader: loader, createdAt: _now())
      ..subscribers = 1;
    _entries[key] = entry;
    _queue.addLast(entry);
    _pump();
    return _EntryLease(entry, SearchReuseKind.network, _release);
  }

  void _pump() {
    while (!_closed &&
        _activeRequests < maxConcurrentRequests &&
        _queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      if (!identical(_entries[entry.key], entry) ||
          entry.state != _PoolState.queued ||
          entry.subscribers == 0) {
        continue;
      }
      entry.state = _PoolState.inFlight;
      _activeRequests++;
      unawaited(_start(entry));
    }
  }

  Future<void> _start(_PoolEntry entry) async {
    final timer = Timer(requestTimeout, () {
      if (!entry.abort.isCompleted) entry.abort.complete();
    });
    try {
      final page = await entry
          .loader(entry.abort.future)
          .timeout(requestTimeout);
      if (_closed || !identical(_entries[entry.key], entry)) {
        throw const _PoolRequestCancelled();
      }
      entry
        ..state = _PoolState.ready
        ..page = _trim(page)
        ..expiresAt = _now().add(page.items.isEmpty ? emptyTtl : successTtl)
        ..lastAccessedAt = _now();
      if (!entry.completer.isCompleted) entry.completer.complete(entry.page);
      _enforceReadyLimit();
      _enforceSourceLimit();
    } catch (error, stackTrace) {
      if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(error, stackTrace);
      }
    } finally {
      timer.cancel();
      _activeRequests--;
      _pump();
    }
  }

  void _release(_PoolEntry entry) {
    if (entry.subscribers <= 0) return;
    entry.subscribers--;
    if (entry.subscribers != 0 || entry.state == _PoolState.ready) return;
    if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
    if (!entry.abort.isCompleted) entry.abort.complete();
    if (!entry.completer.isCompleted) {
      entry.completer.completeError(const _PoolRequestCancelled());
    }
    _pump();
  }

  void _pruneExpired() {
    final now = _now();
    final expired = _entries.entries
        .where(
          (entry) =>
              entry.value.state == _PoolState.ready &&
              !now.isBefore(entry.value.expiresAt!),
        )
        .map((entry) => entry.key)
        .toList();
    for (final key in expired) {
      _entries.remove(key);
    }
  }

  void _enforceReadyLimit() {
    final ready = _entries.entries
        .where((entry) => entry.value.state == _PoolState.ready)
        .toList();
    if (ready.length <= maxReadyEntries) return;
    ready.sort(
      (left, right) =>
          left.value.lastAccessedAt.compareTo(right.value.lastAccessedAt),
    );
    for (final entry in ready.take(ready.length - maxReadyEntries)) {
      _entries.remove(entry.key);
    }
  }

  void _enforceSourceLimit() {
    final ready = _entries.values
        .where((entry) => entry.state == _PoolState.ready)
        .toList(growable: false);
    final newestBySource = <String, DateTime>{};
    for (final entry in ready) {
      final source = entry.key.sourceFingerprint;
      final previous = newestBySource[source];
      if (previous == null || entry.lastAccessedAt.isAfter(previous)) {
        newestBySource[source] = entry.lastAccessedAt;
      }
    }
    if (newestBySource.length <= maxReadySources) return;
    final sources = newestBySource.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final retained = sources
        .take(maxReadySources)
        .map((entry) => entry.key)
        .toSet();
    final staleKeys = _entries.entries
        .where(
          (entry) =>
              entry.value.state == _PoolState.ready &&
              !retained.contains(entry.key.sourceFingerprint),
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in staleKeys) {
      _entries.remove(key);
    }
  }

  VideoPage _trim(VideoPage page) => VideoPage(
    items: page.items.take(20).toList(growable: false),
    page: page.page,
    pageCount: page.pageCount,
    total: page.total,
  );

  void evictSource(String sourceFingerprint, {bool abortInflight = true}) {
    if (_closed) return;
    final targets = _entries.values
        .where((entry) => entry.key.sourceFingerprint == sourceFingerprint)
        .toList(growable: false);
    for (final entry in targets) {
      if (entry.state != _PoolState.ready && !abortInflight) continue;
      if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
      if (entry.state != _PoolState.ready) {
        if (!entry.abort.isCompleted) entry.abort.complete();
        if (!entry.completer.isCompleted) {
          entry.completer.completeError(const _PoolRequestCancelled());
        }
      }
    }
    _pump();
  }

  void clearReady() {
    if (_closed) return;
    final keys = _entries.entries
        .where((entry) => entry.value.state == _PoolState.ready)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keys) {
      _entries.remove(key);
    }
  }

  void clearAll() {
    if (_closed) return;
    for (final entry in _entries.values.toList(growable: false)) {
      if (entry.state != _PoolState.ready) {
        if (!entry.abort.isCompleted) entry.abort.complete();
        if (!entry.completer.isCompleted) {
          entry.completer.completeError(const _PoolRequestCancelled());
        }
      }
    }
    _entries.clear();
    _queue.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final entry in _entries.values) {
      if (entry.state != _PoolState.ready && !entry.abort.isCompleted) {
        entry.abort.complete();
      }
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(const _PoolRequestCancelled());
      }
    }
    _entries.clear();
    _queue.clear();
  }
}

enum _PoolState { queued, inFlight, ready }

class _PoolEntry {
  _PoolEntry({required this.key, required this.loader, required this.createdAt})
    : lastAccessedAt = createdAt;

  final CuratedVodSearchKey key;
  final CuratedVodSearchLoader loader;
  final DateTime createdAt;
  DateTime lastAccessedAt;
  DateTime? expiresAt;
  _PoolState state = _PoolState.queued;
  int subscribers = 0;
  VideoPage? page;
  final Completer<VideoPage> completer = Completer<VideoPage>();
  final Completer<void> abort = Completer<void>();
}

class _EntryLease implements CuratedVodSearchLease {
  _EntryLease(this._entry, this.reuseKind, this._onRelease);

  final _PoolEntry _entry;
  final void Function(_PoolEntry) _onRelease;
  bool _released = false;

  @override
  final SearchReuseKind reuseKind;

  @override
  Future<PooledSearchResult> get future => _entry.completer.future.then(
    (page) => PooledSearchResult(page: page, reuseKind: reuseKind),
  );

  @override
  void release() {
    if (_released) return;
    _released = true;
    _onRelease(_entry);
  }
}

class _ReadyLease implements CuratedVodSearchLease {
  _ReadyLease(VideoPage page)
    : future = Future.value(
        PooledSearchResult(page: page, reuseKind: SearchReuseKind.cache),
      );

  @override
  final Future<PooledSearchResult> future;

  @override
  SearchReuseKind get reuseKind => SearchReuseKind.cache;

  @override
  void release() {}
}

class _PoolRequestCancelled implements Exception {
  const _PoolRequestCancelled();

  @override
  String toString() => 'VOD 搜索已取消';
}
