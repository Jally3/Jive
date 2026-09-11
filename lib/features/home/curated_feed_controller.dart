import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/catalog/tmdb_catalog_repository.dart';
import '../../data/content/video_matcher.dart';
import '../../data/video_repository.dart';
import '../../domain/tmdb_catalog.dart';
import '../../domain/video.dart';
import '../../domain/video_feed.dart';
import '../../domain/video_search_target.dart';
import '../../domain/vod_source.dart';
import 'curated_vod_search_pool.dart';

enum CuratedSlotStatus {
  queued,
  searching,
  available,
  unavailable,
  ambiguous,
  duplicate,
  failed,
}

class CuratedSearchSlot {
  CuratedSearchSlot({
    required this.catalogIndex,
    required this.catalogItem,
    required this.generation,
    required this.sourceName,
  }) : slotId = '${catalogItem.mediaType.name}:${catalogItem.tmdbId}';
  final String slotId;
  final int catalogIndex;
  final TmdbCatalogItem catalogItem;
  final String sourceName;
  CuratedSlotStatus status = CuratedSlotStatus.queued;
  Video? matchedVideo;
  int currentQueryIndex = 0;
  String currentQuery = '';
  int evidenceQueryIndex = 0;
  String evidenceQuery = '';
  int rawResultCount = 0;
  List<String> candidateTitles = const [];
  Object? lastError;
  int attempt = 0;
  int generation;
  final List<_SlotCandidate> _matches = [];
  Future<void>? _running;

  /// Query paired with [rawResultCount] and [candidateTitles].
  String get query =>
      evidenceQuery.isEmpty ? catalogItem.localizedTitle : evidenceQuery;
  int get queryIndex => evidenceQueryIndex;
}

enum CuratedMatchStatus { matched, notFound, ambiguous, requestFailed }

class CuratedFeedEntry {
  const CuratedFeedEntry({
    required this.catalogItem,
    required this.status,
    this.matchedVideo,
    this.rawResultCount = 0,
    this.query = '',
    this.candidateTitles = const [],
  });
  final TmdbCatalogItem catalogItem;
  final Video? matchedVideo;
  final CuratedMatchStatus status;
  final int rawResultCount;
  final String query;
  final List<String> candidateTitles;
}

class CuratedFeedController extends ChangeNotifier {
  CuratedFeedController({
    required this.catalogRepository,
    required this.videoRepository,
    required this.source,
    this.feed = VideoFeed.newReleases,
    this.scope = TmdbCatalogScope.all,
    this.matcher = const VideoMatcher(),
    int targetCount = 20,
    int maxCandidatesPerLoad = 20,
    this.maxFallbackSearches = 6,
    this.maxConcurrentSearches = 3,
    this.requestTimeout = const Duration(seconds: 8),
    this.operationTimeout = const Duration(seconds: 30),
    this.viewCacheDuration = const Duration(minutes: 10),
    this.incompleteSessionDuration = const Duration(minutes: 2),
    this.maxCachedViews = 8,
    CuratedVodSearchPool? searchPool,
  }) : catalogPageSize = maxCandidatesPerLoad,
       _searchPool =
           searchPool ?? CuratedVodSearchPool(requestTimeout: requestTimeout),
       _ownsSearchPool = searchPool == null,
       _sourceFingerprint = curatedVodSourceFingerprint(source);

  final TmdbCatalogRepository catalogRepository;
  final VideoRepository videoRepository;
  final VodSource source;
  final VideoMatcher matcher;
  final int catalogPageSize;
  final int maxFallbackSearches;
  final int maxConcurrentSearches;
  final Duration requestTimeout;
  final Duration operationTimeout;
  final Duration viewCacheDuration;
  final Duration incompleteSessionDuration;
  final int maxCachedViews;
  final CuratedVodSearchPool _searchPool;
  final bool _ownsSearchPool;
  final String _sourceFingerprint;
  VideoFeed feed;
  TmdbCatalogScope scope;
  final Map<_ViewKey, _Session> _sessions = {};
  _Session? _active;
  int _binding = 0;
  int _generation = 0;
  bool _catalogLoading = false;
  bool _disposed = false;
  String? _catalogError;
  Timer? _notifyTimer;

  List<CuratedSearchSlot> get slots => _active?.slots ?? const [];
  List<Video> get items => [
    for (final slot in slots)
      if (slot.status == CuratedSlotStatus.available &&
          slot.matchedVideo != null)
        slot.matchedVideo!,
  ];
  List<CuratedFeedEntry> get entries => slots.map(_entryFor).toList();
  List<CuratedFeedEntry> get unavailableEntries => entries
      .where(
        (entry) =>
            entry.status == CuratedMatchStatus.notFound ||
            entry.status == CuratedMatchStatus.ambiguous,
      )
      .toList(growable: false);
  List<CuratedFeedEntry> get failedEntries => entries
      .where((entry) => entry.status == CuratedMatchStatus.requestFailed)
      .toList(growable: false);
  bool get loading => _catalogLoading || (_active?.searching ?? false);
  bool get catalogLoading => _catalogLoading;
  bool get hasMore => _active?.hasMore ?? true;
  String? get error => _catalogError ?? _active?.error;
  int get searched =>
      slots.where((slot) => slot.status != CuratedSlotStatus.queued).length;
  int get matched =>
      slots.where((slot) => slot.status == CuratedSlotStatus.available).length;
  bool get sourceUnavailable => _active?.sourceUnavailable ?? false;

  Future<void> selectFeed(VideoFeed value) async {
    if (feed == value && _active != null) return;
    feed = value;
    await loadInitial();
  }

  Future<void> selectScope(TmdbCatalogScope value) async {
    if (scope == value && _active != null) return;
    scope = value;
    await loadInitial();
  }

  Future<void> loadInitial({bool forceRefresh = false}) async {
    final binding = ++_binding;
    final requestedFeed = feed;
    final requestedScope = scope;
    _detach();
    if (!forceRefresh &&
        _active != null &&
        (_active!.key.feed != requestedFeed ||
            _active!.key.scope != requestedScope)) {
      _active = null;
    }
    _catalogError = null;
    _catalogLoading = true;
    _notify(immediate: true);
    try {
      final snapshot = await catalogRepository.fetchFeed(
        requestedFeed,
        forceRefresh: forceRefresh,
      );
      if (!_current(binding, requestedFeed)) return;
      final effectiveScope = snapshot.supportedScopes.contains(requestedScope)
          ? requestedScope
          : TmdbCatalogScope.all;
      scope = effectiveScope;
      final key = _ViewKey(
        _sourceFingerprint,
        requestedFeed,
        effectiveScope,
        snapshot.revision,
      );
      if (forceRefresh) _remove(key);
      _prune();
      final session =
          _take(key) ??
          _Session(key, snapshot, forceRefresh, generation: ++_generation);
      _sessions[key] = session;
      session
        ..attached = true
        ..lastAccessedAt = DateTime.now();
      _active = session;
      _catalogLoading = false;
      if (session.slots.isEmpty) _appendCatalogPage(session);
      _notify(immediate: true);
      await _schedule(session);
    } catch (exception) {
      if (_current(binding, requestedFeed)) _catalogError = '$exception';
    } finally {
      if (!_disposed && binding == _binding) {
        _catalogLoading = false;
        _notify(immediate: true);
      }
    }
  }

  Future<void> refresh() => loadInitial(forceRefresh: true);
  Future<void> loadMore() async {
    final session = _active;
    if (session == null || _catalogLoading || !session.hasMore) return;
    _appendCatalogPage(session);
    _notify(immediate: true);
    await _schedule(session);
  }

  void prioritizeSlot(String slotId) {
    final session = _active;
    if (session == null) return;
    final slot = session.slots
        .where((item) => item.slotId == slotId)
        .firstOrNull;
    if (slot == null || slot.status != CuratedSlotStatus.queued) return;
    unawaited(_startSlot(session, slot));
  }

  Future<void> retrySlot(String slotId) async {
    final session = _active;
    if (session == null) return;
    final slot = session.slots
        .where((item) => item.slotId == slotId)
        .firstOrNull;
    if (slot == null) return;
    slot.generation = ++_generation;
    slot.attempt++;
    slot
      ..status = CuratedSlotStatus.queued
      ..matchedVideo = null
      ..lastError = null
      ..currentQueryIndex = 0
      ..currentQuery = ''
      ..evidenceQueryIndex = 0
      ..evidenceQuery = ''
      ..rawResultCount = 0
      ..candidateTitles = const []
      .._matches.clear();
    session
      ..sourceUnavailable = false
      ..consecutiveErrors = 0;
    _notify(immediate: true);
    await _startSlot(session, slot);
  }

  Future<void> retryFailed() async {
    final session = _active;
    if (session == null) return;
    session
      ..sourceUnavailable = false
      ..consecutiveErrors = 0;
    for (final slot in session.slots) {
      if (slot.status == CuratedSlotStatus.failed) {
        slot.generation = ++_generation;
        slot.attempt++;
        slot
          ..status = CuratedSlotStatus.queued
          ..lastError = null;
      }
    }
    _notify(immediate: true);
    await _schedule(session);
  }

  void _appendCatalogPage(_Session session) {
    final candidates = session.snapshot.itemsFor(session.key.scope);
    final end = (session.cursor + catalogPageSize).clamp(0, candidates.length);
    for (var index = session.cursor; index < end; index++) {
      session.slots.add(
        CuratedSearchSlot(
          catalogIndex: index,
          catalogItem: candidates[index],
          generation: session.generation,
          sourceName: source.name,
        ),
      );
    }
    session.cursor = end;
    session.hasMore = end < candidates.length;
  }

  Future<void> _schedule(_Session session) async {
    if (!session.attached || session.cancelled || session.sourceUnavailable) {
      return;
    }
    await Future.wait(
      List.generate(maxConcurrentSearches, (_) => _worker(session)),
    );
    if (!session.cancelled) {
      session
        ..searching = false
        ..cacheable = !session.sourceUnavailable
        ..cachedAt = DateTime.now()
        ..lastAccessedAt = DateTime.now();
      _notifyIfActive(session);
    }
  }

  Future<void> _worker(_Session session) async {
    while (!_disposed &&
        session.attached &&
        !session.cancelled &&
        !session.sourceUnavailable) {
      final slot = session.slots
          .where((item) => item.status == CuratedSlotStatus.queued)
          .firstOrNull;
      if (slot == null) return;
      await _startSlot(session, slot);
    }
  }

  Future<void> _startSlot(_Session session, CuratedSearchSlot slot) {
    final existing = slot._running;
    if (existing != null) return existing;
    final future = _searchSlot(session, slot);
    slot._running = future;
    session.searching = true;
    return future.whenComplete(() {
      if (identical(slot._running, future)) slot._running = null;
    });
  }

  Future<void> _searchSlot(_Session session, CuratedSearchSlot slot) async {
    final generation = slot.generation;
    final queries = slot.catalogItem.searchQueries;
    final startIndex = slot._matches.isEmpty
        ? 0
        : slot._matches
                  .map((candidate) => candidate.queryIndex)
                  .reduce((left, right) => left > right ? left : right) +
              1;
    if (queries.isEmpty) {
      slot.status = CuratedSlotStatus.unavailable;
      _notifyIfActive(session);
      return;
    }
    if (!session.forceRefresh) {
      for (var index = startIndex; index < queries.length; index++) {
        final ready = _searchPool.peekReady(
          sourceFingerprint: _sourceFingerprint,
          query: queries[index],
        );
        if (ready == null) continue;
        final result = _recordAndMatch(slot, index, queries[index], ready.page);
        if (!_valid(session, slot, generation)) return;
        if (result.outcome == VideoMatchOutcome.matched) {
          _addMatch(slot, result.match!, index);
          _reconcile(session);
          _notifyIfActive(session, immediate: true);
          return;
        }
      }
    }
    var ambiguous = false;
    var attempted = false;
    final deadline = DateTime.now().add(operationTimeout);
    for (var index = startIndex; index < queries.length; index++) {
      if (!_valid(session, slot, generation) || !session.attached) return;
      if (index > 0 && index > maxFallbackSearches) break;
      attempted = true;
      slot
        ..status = CuratedSlotStatus.searching
        ..currentQueryIndex = index
        ..currentQuery = queries[index];
      _notifyIfActive(session);
      try {
        final page = await _search(
          session,
          queries[index],
          deadline,
          refresh:
              session.forceRefresh &&
              session.refreshedQueries.add(
                normalizeCuratedVodQuery(queries[index]),
              ),
        );
        if (!_valid(session, slot, generation)) return;
        session.consecutiveErrors = 0;
        final result = _recordAndMatch(slot, index, queries[index], page);
        if (result.outcome == VideoMatchOutcome.matched) {
          _addMatch(slot, result.match!, index);
          _reconcile(session);
          _notifyIfActive(session, immediate: true);
          if (slot.status == CuratedSlotStatus.available) return;
          continue;
        }
        ambiguous |= result.outcome == VideoMatchOutcome.ambiguous;
      } catch (error) {
        if (!_valid(session, slot, generation)) return;
        slot.lastError = error;
        session.consecutiveErrors++;
        if (session.consecutiveErrors >= 3) session.sourceUnavailable = true;
      }
    }
    if (!_valid(session, slot, generation)) return;
    if (slot._matches.isNotEmpty) {
      _reconcile(session);
    } else if (slot.lastError != null &&
        (!attempted || slot.rawResultCount == 0)) {
      slot.status = CuratedSlotStatus.failed;
    } else {
      slot.status = ambiguous
          ? CuratedSlotStatus.ambiguous
          : CuratedSlotStatus.unavailable;
    }
    _notifyIfActive(session, immediate: true);
  }

  Future<VideoPage> _search(
    _Session session,
    String query,
    DateTime deadline, {
    required bool refresh,
  }) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw TimeoutException('榜单匹配超时');
    final repository = videoRepository;
    final lease = _searchPool.acquire(
      sourceFingerprint: _sourceFingerprint,
      query: query,
      mode: refresh ? SearchCacheMode.refresh : SearchCacheMode.preferCache,
      loader: (abortTrigger) => repository is CancellableVideoRepository
          ? (repository as CancellableVideoRepository).fetchPageCancellable(
              source,
              page: 1,
              keyword: query,
              abortTrigger: abortTrigger,
            )
          : repository.fetchPage(source, page: 1, keyword: query),
    );
    try {
      final result = await Future.any([
        lease.future,
        session.abort.future.then<PooledSearchResult>(
          (_) => throw const _SessionCancelled(),
        ),
      ]).timeout(remaining);
      return result.page;
    } finally {
      lease.release();
    }
  }

  VideoMatchResult _recordAndMatch(
    CuratedSearchSlot slot,
    int queryIndex,
    String query,
    VideoPage page,
  ) {
    final count = page.total ?? page.items.length;
    if (slot.evidenceQuery.isEmpty || count > slot.rawResultCount) {
      slot
        ..rawResultCount = count
        ..evidenceQuery = query
        ..evidenceQueryIndex = queryIndex
        ..candidateTitles = page.items
            .map((video) => video.title.trim())
            .where((title) => title.isNotEmpty)
            .take(5)
            .toList(growable: false);
    }
    return matcher.matchTarget(
      VideoSearchTarget.fromCatalog(slot.catalogItem),
      page.items,
    );
  }

  void _addMatch(CuratedSearchSlot slot, VideoMatch match, int queryIndex) {
    final video = _materialize(slot.catalogItem, match);
    if (slot._matches.any(
      (candidate) => candidate.video.globalId == video.globalId,
    )) {
      return;
    }
    slot._matches.add(_SlotCandidate(video, queryIndex));
    slot._matches.sort((a, b) => a.queryIndex.compareTo(b.queryIndex));
  }

  Video _materialize(TmdbCatalogItem target, VideoMatch match) {
    final useVod = match.strategy == VideoMatchStrategy.varietyLatestSeason;
    return match.video.copyWith(
      title: useVod ? match.video.title : target.localizedTitle,
      posterUrl: useVod
          ? (match.video.posterUrl.isEmpty
                ? target.posterUrl
                : match.video.posterUrl)
          : (target.posterUrl.isEmpty
                ? match.video.posterUrl
                : target.posterUrl),
      backupPosterUrl: useVod
          ? (match.video.posterUrl.isEmpty
                ? match.video.backupPosterUrl
                : target.posterUrl)
          : (target.posterUrl.isEmpty
                ? match.video.backupPosterUrl
                : match.video.posterUrl),
      rating: target.rating,
      rank: target.rank,
    );
  }

  void _reconcile(_Session session) {
    final owners = <String, String>{};
    final retryDuplicates = <CuratedSearchSlot>[];
    for (final slot in session.slots) {
      if (slot._matches.isEmpty) continue;
      final selected = slot._matches
          .where((candidate) => !owners.containsKey(candidate.video.globalId))
          .firstOrNull;
      if (selected == null) {
        slot
          ..matchedVideo = null
          ..status = CuratedSlotStatus.duplicate;
        final lastQuery = slot._matches
            .map((candidate) => candidate.queryIndex)
            .reduce((left, right) => left > right ? left : right);
        if (lastQuery + 1 < slot.catalogItem.searchQueries.length &&
            slot._running == null) {
          retryDuplicates.add(slot);
        }
      } else {
        owners[selected.video.globalId] = slot.slotId;
        slot
          ..matchedVideo = selected.video
          ..status = CuratedSlotStatus.available;
      }
    }
    session.globalIdOwners
      ..clear()
      ..addAll(owners);
    for (final slot in retryDuplicates) {
      Timer.run(() {
        if (_valid(session, slot, slot.generation) && session.attached) {
          unawaited(_startSlot(session, slot));
        }
      });
    }
  }

  bool _valid(_Session session, CuratedSearchSlot slot, int generation) =>
      !_disposed &&
      !session.cancelled &&
      session.key.sourceFingerprint == _sourceFingerprint &&
      slot.generation == generation;
  CuratedFeedEntry _entryFor(CuratedSearchSlot slot) => CuratedFeedEntry(
    catalogItem: slot.catalogItem,
    matchedVideo: slot.matchedVideo,
    status: switch (slot.status) {
      CuratedSlotStatus.available => CuratedMatchStatus.matched,
      CuratedSlotStatus.ambiguous => CuratedMatchStatus.ambiguous,
      CuratedSlotStatus.failed => CuratedMatchStatus.requestFailed,
      _ => CuratedMatchStatus.notFound,
    },
    rawResultCount: slot.rawResultCount,
    query: slot.query,
    candidateTitles: slot.candidateTitles,
  );
  bool _current(int binding, VideoFeed expectedFeed) =>
      !_disposed && binding == _binding && feed == expectedFeed;
  void _detach() {
    final session = _active;
    if (session != null) {
      session
        ..attached = false
        ..lastAccessedAt = DateTime.now();
    }
  }

  _Session? _take(_ViewKey key) {
    final session = _sessions[key];
    if (session == null || session.cancelled) return null;
    final ttl = session.cacheable
        ? viewCacheDuration
        : incompleteSessionDuration;
    if (DateTime.now().difference(session.cachedAt ?? session.lastAccessedAt) >=
        ttl) {
      _remove(key);
      return null;
    }
    return session;
  }

  void _remove(_ViewKey key) {
    final session = _sessions.remove(key);
    if (session == null) return;
    session
      ..cancelled = true
      ..attached = false;
    if (!session.abort.isCompleted) session.abort.complete();
  }

  void _prune() {
    final now = DateTime.now();
    final expired = _sessions.entries
        .where((entry) {
          if (identical(entry.value, _active)) return false;
          final ttl = entry.value.cacheable
              ? viewCacheDuration
              : incompleteSessionDuration;
          return now.difference(
                entry.value.cachedAt ?? entry.value.lastAccessedAt,
              ) >=
              ttl;
        })
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in expired) {
      _remove(key);
    }
    while (_sessions.length > maxCachedViews) {
      final candidates =
          _sessions.entries
              .where((entry) => !identical(entry.value, _active))
              .toList()
            ..sort(
              (a, b) =>
                  a.value.lastAccessedAt.compareTo(b.value.lastAccessedAt),
            );
      if (candidates.isEmpty) break;
      _remove(candidates.first.key);
    }
  }

  void _notifyIfActive(_Session session, {bool immediate = false}) {
    if (identical(session, _active)) _notify(immediate: immediate);
  }

  void _notify({bool immediate = false}) {
    if (_disposed) return;
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      notifyListeners();
      return;
    }
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 16), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _binding++;
    _notifyTimer?.cancel();
    for (final session in _sessions.values) {
      session
        ..cancelled = true
        ..attached = false;
      if (!session.abort.isCompleted) session.abort.complete();
    }
    if (_ownsSearchPool) _searchPool.close();
    super.dispose();
  }
}

class _Session {
  _Session(
    this.key,
    this.snapshot,
    this.forceRefresh, {
    required this.generation,
  });
  final _ViewKey key;
  final TmdbCatalogSnapshot snapshot;
  final bool forceRefresh;
  final int generation;
  final Set<String> refreshedQueries = {};
  final List<CuratedSearchSlot> slots = [];
  final Map<String, String> globalIdOwners = {};
  int cursor = 0;
  bool hasMore = true;
  bool attached = false;
  bool cancelled = false;
  bool searching = false;
  bool cacheable = false;
  bool sourceUnavailable = false;
  int consecutiveErrors = 0;
  String? error;
  DateTime? cachedAt;
  DateTime lastAccessedAt = DateTime.now();
  final Completer<void> abort = Completer<void>();
}

class _SlotCandidate {
  const _SlotCandidate(this.video, this.queryIndex);
  final Video video;
  final int queryIndex;
}

class _SessionCancelled implements Exception {
  const _SessionCancelled();
}

class _ViewKey {
  const _ViewKey(this.sourceFingerprint, this.feed, this.scope, this.revision);
  final String sourceFingerprint;
  final VideoFeed feed;
  final TmdbCatalogScope scope;
  final String revision;
  @override
  bool operator ==(Object other) =>
      other is _ViewKey &&
      sourceFingerprint == other.sourceFingerprint &&
      feed == other.feed &&
      scope == other.scope &&
      revision == other.revision;
  @override
  int get hashCode => Object.hash(sourceFingerprint, feed, scope, revision);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
