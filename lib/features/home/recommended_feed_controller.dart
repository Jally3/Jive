import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/content/video_matcher.dart';
import '../../data/recommendation/backend_recommendation_client.dart';
import '../../data/recommendation/recommendation_client.dart';
import '../../data/recommendation/recommendation_repository.dart';
import '../../data/video_repository.dart';
import '../../domain/library.dart';
import '../../domain/recommendation.dart';
import '../../domain/video.dart';
import '../../domain/vod_source.dart';
import '../../domain/watch_record.dart';
import 'curated_vod_search_pool.dart';

enum RecommendedCandidateStatus {
  queued,
  searching,
  available,
  notFound,
  ambiguous,
  failed,
}

class RecommendedCandidateSlot {
  RecommendedCandidateSlot({
    required this.candidate,
    required this.pageIndex,
    required this.candidatePosition,
    required this.sessionId,
  });

  RecommendationCandidate candidate;
  int pageIndex;
  final int candidatePosition;
  String? sessionId;
  bool committed = false;
  bool exposureReported = false;
  bool outcomeReported = false;
  RecommendedCandidateStatus status = RecommendedCandidateStatus.queued;
  Video? matchedVideo;
  String evidenceQuery = '';
  int rawResultCount = 0;
  List<String> candidateTitles = const [];
  Object? lastError;

  String get query => evidenceQuery.isEmpty ? candidate.title : evidenceQuery;
}

class RecommendedFeedController extends ChangeNotifier {
  RecommendedFeedController({
    required this.recommendationRepository,
    required this.videoRepository,
    required this.source,
    required CuratedVodSearchPool searchPool,
    this.matcher = const VideoMatcher(),
    this.maxCandidates = 24,
    this.targetCount = 12,
    this.maxConcurrentSearches = 3,
    this.maxQueriesPerCandidate = 2,
    this.maxSearchRequests = 30,
  }) : _searchPool = searchPool,
       _sourceFingerprint = curatedVodSourceFingerprint(source);

  final RecommendationRepository recommendationRepository;
  final VideoRepository videoRepository;
  VodSource source;
  final VideoMatcher matcher;
  final int maxCandidates;
  final int targetCount;
  final int maxConcurrentSearches;
  final int maxQueriesPerCandidate;
  final int maxSearchRequests;
  final CuratedVodSearchPool _searchPool;
  String _sourceFingerprint;

  final List<Video> items = [];
  final List<RecommendationCandidate> candidates = [];
  final List<RecommendedCandidateSlot> slots = [];
  final Map<int, Video> _matches = {};
  bool generating = false;
  bool matching = false;
  bool loadingMore = false;
  bool streaming = false;
  bool fromCache = false;
  bool playableFromCache = false;
  bool coldStart = false;
  String? error;
  int searched = 0;
  int notFound = 0;
  int ambiguous = 0;
  int failed = 0;
  int searchRequests = 0;
  Duration generationDuration = Duration.zero;
  Duration matchingDuration = Duration.zero;
  String? sessionId;
  int pageIndex = 0;
  String? nextCursor;
  bool hasMore = false;

  int _generation = 0;
  int _sourceSwitchEpoch = 0;
  bool _disposed = false;
  Future<void>? _initialRequest;
  Future<void>? _moreRequest;
  StreamIterator<RecommendationStreamEvent>? _streamIterator;
  _StreamingPageWork? _pageWork;
  bool _viewActive = true;
  String? _requestingCursor;
  List<WatchRecord> _history = const [];
  List<FavoriteRecord> _library = const [];

  bool get loading => generating || matching || loadingMore;
  bool get fetchingMore => loadingMore && !matching;
  bool get matchingMore => loadingMore && matching;
  bool get hasLoadedState =>
      generating ||
      streaming ||
      matching ||
      loadingMore ||
      items.isNotEmpty ||
      candidates.isNotEmpty ||
      slots.isNotEmpty ||
      coldStart ||
      error != null ||
      pageIndex > 0;

  bool isProvisionalVideo(Video video) {
    final work = _pageWork;
    if (work == null || work.committed) return false;
    return _matches.entries.any(
      (entry) =>
          entry.key >= work.matchStart &&
          entry.value.globalId == video.globalId,
    );
  }

  List<RecommendedCandidateSlot> get unavailableSlots {
    final result = slots
        .where(
          (slot) =>
              slot.status == RecommendedCandidateStatus.notFound ||
              slot.status == RecommendedCandidateStatus.ambiguous ||
              slot.status == RecommendedCandidateStatus.failed,
        )
        .toList(growable: false);
    result.sort((a, b) {
      int priority(RecommendedCandidateStatus status) => switch (status) {
        RecommendedCandidateStatus.ambiguous => 0,
        RecommendedCandidateStatus.notFound => 1,
        RecommendedCandidateStatus.failed => 2,
        _ => 3,
      };
      return priority(a.status).compareTo(priority(b.status));
    });
    return result;
  }

  Future<void> loadInitial({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
    bool forceRefresh = false,
  }) {
    final pending = _initialRequest;
    if (pending != null) return pending;
    late Future<void> tracked;
    tracked =
        _loadInitial(
          history: history,
          library: library,
          forceRefresh: forceRefresh,
        ).whenComplete(() {
          if (identical(_initialRequest, tracked)) _initialRequest = null;
        });
    _initialRequest = tracked;
    return tracked;
  }

  Future<void> _loadInitial({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
    required bool forceRefresh,
  }) async {
    await _cancelActiveStream();
    _history = List.unmodifiable(history);
    _library = List.unmodifiable(library);
    final generation = ++_generation;
    _reset();
    generating = true;
    _notify();
    if (!forceRefresh) {
      List<Video>? cachedVideos;
      try {
        cachedVideos = await recommendationRepository.readPlayableCache(
          history: history,
          library: library,
          sourceFingerprint: _sourceFingerprint,
        );
      } catch (_) {
        // 本地缓存不可用不能阻断推荐主链路。
      }
      if (!_current(generation)) return;
      if (cachedVideos != null) {
        items.addAll(cachedVideos);
        playableFromCache = true;
        generating = false;
        _notify();
        return;
      }
    }
    final watch = Stopwatch()..start();
    try {
      await _consumeRecommendationStream(
        recommendationRepository.fetchStream(
          history: history,
          library: library,
          forceRefresh: forceRefresh,
        ),
        generation: generation,
        append: false,
      );
      if (_current(generation)) generationDuration = watch.elapsed;
    } catch (exception) {
      if (_current(generation)) {
        error = '$exception';
        generating = false;
        _notify();
      }
    }
  }

  Future<void> refresh({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) => loadInitial(history: history, library: library, forceRefresh: true);

  Future<void> loadMore() {
    final cursor = nextCursor;
    if (!hasMore || cursor == null || loadingMore) {
      return _moreRequest ?? Future.value();
    }
    if (_requestingCursor == cursor && _moreRequest != null) {
      return _moreRequest!;
    }
    final generation = _generation;
    late Future<void> tracked;
    _requestingCursor = cursor;
    tracked = _loadMore(generation, cursor).whenComplete(() {
      if (identical(_moreRequest, tracked)) {
        _moreRequest = null;
        _requestingCursor = null;
      }
    });
    _moreRequest = tracked;
    return tracked;
  }

  Future<void> _loadMore(int generation, String cursor) async {
    loadingMore = true;
    error = null;
    _notify();
    try {
      if (recommendationRepository.client is StreamingRecommendationClient) {
        await _consumeRecommendationStream(
          recommendationRepository.fetchNextStream(cursor),
          generation: generation,
          append: true,
        );
      } else {
        final batch = await recommendationRepository.fetchNext(cursor);
        if (!_current(generation)) return;
        await _acceptBatch(generation, batch, append: true);
      }
    } on RecommendationApiException catch (exception) {
      if (!_current(generation)) return;
      error = exception.message;
      if (exception.isExpiredCursor ||
          exception.code == 'INVALID_RECOMMENDATION_CURSOR') {
        hasMore = false;
        nextCursor = null;
        sessionId = null;
        // Keep the old list visible while creating a clean session. Only a
        // successful new first page replaces it; it is never appended.
        try {
          final replacement = await recommendationRepository.fetch(
            history: _history,
            library: _library,
            forceRefresh: true,
          );
          if (_current(generation)) {
            _reset();
            await _acceptBatch(generation, replacement, append: false);
          }
        } catch (_) {
          // The original cursor error remains actionable in the UI.
        }
      }
    } catch (exception) {
      if (_current(generation)) error = '$exception';
    } finally {
      if (_current(generation)) {
        loadingMore = false;
        _notify();
      }
    }
  }

  Future<void> _consumeRecommendationStream(
    Stream<RecommendationStreamEvent> stream, {
    required int generation,
    required bool append,
  }) async {
    final iterator = StreamIterator(stream);
    _streamIterator = iterator;
    try {
      while (await iterator.moveNext()) {
        if (!_current(generation)) return;
        final event = iterator.current;
        switch (event) {
          case RecommendationStreamStart():
            if (_pageWork != null) {
              throw const RecommendationApiException(
                statusCode: 200,
                code: 'INVALID_NDJSON_STREAM',
                message: '推荐流状态无效',
              );
            }
            streaming = true;
            matching = false;
            _pageWork = _StreamingPageWork(
              append: append,
              candidateStart: candidates.length,
              slotStart: slots.length,
              matchStart: candidates.length,
              searched: searched,
              notFound: notFound,
              ambiguous: ambiguous,
              failed: failed,
              searchRequests: searchRequests,
              budget: _PageSearchBudget(maxSearchRequests, targetCount),
            );
            _notify();
          case RecommendationStreamItem(:final index, :final item):
            final work = _pageWork;
            if (work == null || index != work.slots.length + 1) {
              throw const RecommendationApiException(
                statusCode: 200,
                code: 'INVALID_NDJSON_STREAM',
                message: '推荐流候选顺序无效',
              );
            }
            final slot = RecommendedCandidateSlot(
              candidate: item,
              pageIndex: 0,
              candidatePosition: index,
              sessionId: null,
            );
            work.slots.add(slot);
            candidates.add(item);
            slots.add(slot);
            matching = true;
            _launchStreamingSearch(generation, work, slot);
            _notify();
          case RecommendationStreamReset():
            _rollbackStreamingPage();
            streaming = false;
            matching = false;
            _notify();
          case RecommendationStreamDone(:final result):
            final work = _pageWork;
            if (work == null) {
              generating = false;
              loadingMore = false;
              await _acceptBatch(generation, result, append: append);
              continue;
            }
            if (!_sameStreamCandidates(work, result.items)) {
              throw const RecommendationApiException(
                statusCode: 200,
                code: 'INVALID_NDJSON_STREAM',
                message: '推荐流最终结果与增量候选不一致',
              );
            }
            work.committed = true;
            for (var i = 0; i < work.slots.length; i++) {
              final slot = work.slots[i];
              slot
                ..candidate = result.items[i]
                ..pageIndex = result.page.index
                ..sessionId = result.sessionId
                ..committed = true;
              candidates[work.candidateStart + i] = result.items[i];
              _reportCommittedOutcome(slot);
            }
            fromCache = result.fromCache;
            coldStart = result.isColdStart;
            sessionId = result.sessionId;
            pageIndex = result.page.index;
            nextCursor = result.page.nextCursor;
            hasMore = result.page.hasMore && !_cursorExpired(result);
            generating = false;
            streaming = false;
            loadingMore = false;
            _launchQueuedStreamingSearches(generation, work);
            _finishStreamingWorkIfIdle(generation, work);
            _notify();
        }
      }
    } catch (_) {
      if (_current(generation)) _rollbackStreamingPage();
      rethrow;
    } finally {
      if (identical(_streamIterator, iterator)) _streamIterator = null;
      await iterator.cancel();
    }
  }

  bool _sameStreamCandidates(
    _StreamingPageWork work,
    List<RecommendationCandidate> authoritative,
  ) {
    if (work.slots.length != authoritative.length) return false;
    for (var i = 0; i < authoritative.length; i++) {
      if (work.slots[i].candidate.identity != authoritative[i].identity) {
        return false;
      }
    }
    return true;
  }

  void _launchStreamingSearch(
    int generation,
    _StreamingPageWork work,
    RecommendedCandidateSlot slot,
  ) {
    if (work.cancelled ||
        !_viewActive ||
        work.activeSearches >= maxConcurrentSearches) {
      return;
    }
    if (slot.status != RecommendedCandidateStatus.queued ||
        !work.budget.hasMatchCapacity) {
      return;
    }
    work.activeSearches++;
    final index = work.matchStart + work.slots.indexOf(slot);
    unawaited(
      _searchCandidate(
        generation,
        index,
        slot,
        work.budget,
        streamWork: work,
      ).whenComplete(() {
        work.activeSearches--;
        if (!_current(generation)) return;
        _launchQueuedStreamingSearches(generation, work);
        _finishStreamingWorkIfIdle(generation, work);
      }),
    );
  }

  void _launchQueuedStreamingSearches(int generation, _StreamingPageWork work) {
    if (work.cancelled || !_viewActive || !_current(generation)) return;
    for (final slot in work.slots) {
      if (work.activeSearches >= maxConcurrentSearches) break;
      _launchStreamingSearch(generation, work, slot);
    }
  }

  void _finishStreamingWorkIfIdle(int generation, _StreamingPageWork work) {
    if (work.cancelled || !work.committed || work.activeSearches != 0) return;
    final hasQueuedWork =
        work.budget.hasMatchCapacity &&
        work.slots.any(
          (slot) => slot.status == RecommendedCandidateStatus.queued,
        );
    if (hasQueuedWork) return;
    matching = false;
    if (items.isNotEmpty) {
      unawaited(
        recommendationRepository.writePlayableCache(
          history: _history,
          library: _library,
          sourceFingerprint: _sourceFingerprint,
          videos: items,
        ),
      );
    }
    if (identical(_pageWork, work)) _pageWork = null;
    _notify();
  }

  void _reportCommittedOutcome(RecommendedCandidateSlot slot) {
    if (!slot.committed) return;
    if (_viewActive && !slot.exposureReported && slot.matchedVideo != null) {
      slot.exposureReported = true;
      _event(slot, RecommendationEventType.candidateExposed);
    }
    if (slot.outcomeReported) return;
    switch (slot.status) {
      case RecommendedCandidateStatus.available:
        _event(slot, RecommendationEventType.vodMatched);
      case RecommendedCandidateStatus.notFound:
        _event(slot, RecommendationEventType.vodNotFound);
      case RecommendedCandidateStatus.ambiguous:
        _event(slot, RecommendationEventType.vodAmbiguous);
      case RecommendedCandidateStatus.failed:
        _event(slot, RecommendationEventType.vodSearchFailed);
      case RecommendedCandidateStatus.queued ||
          RecommendedCandidateStatus.searching:
        return;
    }
    slot.outcomeReported = true;
  }

  void _rollbackStreamingPage() {
    final work = _pageWork;
    if (work == null || work.committed) return;
    work.cancelled = true;
    for (final lease in work.leases.toList()) {
      lease.release();
    }
    work.leases.clear();
    candidates.removeRange(work.candidateStart, candidates.length);
    slots.removeRange(work.slotStart, slots.length);
    _matches.removeWhere((index, _) => index >= work.matchStart);
    searched = work.searched;
    notFound = work.notFound;
    ambiguous = work.ambiguous;
    failed = work.failed;
    searchRequests = work.searchRequests;
    _rebuildItems();
    _pageWork = null;
    streaming = false;
    matching = false;
  }

  Future<void> _cancelActiveStream() async {
    final iterator = _streamIterator;
    _streamIterator = null;
    if (iterator != null) await iterator.cancel();
    final work = _pageWork;
    if (work != null && work.committed) {
      work.cancelled = true;
      for (final lease in work.leases.toList()) {
        lease.release();
      }
      work.leases.clear();
      _pageWork = null;
      matching = false;
    } else {
      _rollbackStreamingPage();
    }
  }

  void setViewActive(bool active) {
    if (_viewActive == active) return;
    _viewActive = active;
    final work = _pageWork;
    if (active) {
      for (final slot in slots) {
        if (slot.committed && slot.matchedVideo != null) {
          _reportCommittedOutcome(slot);
        }
      }
      if (work != null) {
        _launchQueuedStreamingSearches(_generation, work);
      }
    }
    _notify();
  }

  Future<void> switchVodSource(VodSource nextSource) async {
    final nextFingerprint = curatedVodSourceFingerprint(nextSource);
    if (nextFingerprint == _sourceFingerprint) return;
    final switchEpoch = ++_sourceSwitchEpoch;
    // Source changes are observed while HomePage is building. Defer notifier
    // mutations so listeners never call setState during that build.
    await Future<void>.value();
    if (_disposed || switchEpoch != _sourceSwitchEpoch) return;

    final currentWork = _pageWork;
    final hasCommittedAndPending =
        currentWork != null &&
        !currentWork.committed &&
        slots.take(currentWork.slotStart).any((slot) => slot.committed);
    if (hasCommittedAndPending) {
      // An unfinished continuation page has no committed Cursor of its own.
      // Roll it back while retaining every previously committed page.
      await _cancelActiveStream();
      if (_disposed || switchEpoch != _sourceSwitchEpoch) return;
    } else if (currentWork != null) {
      currentWork.cancelled = true;
      for (final lease in currentWork.leases.toList()) {
        lease.release();
      }
      currentWork.leases.clear();
    }

    source = nextSource;
    _sourceFingerprint = nextFingerprint;
    playableFromCache = false;
    error = null;
    searched = 0;
    notFound = 0;
    ambiguous = 0;
    failed = 0;
    searchRequests = 0;
    matchingDuration = Duration.zero;
    _matches.clear();
    items.clear();

    for (final slot in slots) {
      slot
        ..status = RecommendedCandidateStatus.queued
        ..matchedVideo = null
        ..evidenceQuery = ''
        ..rawResultCount = 0
        ..candidateTitles = const []
        ..lastError = null
        ..exposureReported = false
        ..outcomeReported = false;
    }

    if (slots.isEmpty) {
      if (currentWork != null && !hasCommittedAndPending) {
        _pageWork = _StreamingPageWork(
          append: currentWork.append,
          candidateStart: currentWork.candidateStart,
          slotStart: currentWork.slotStart,
          matchStart: currentWork.matchStart,
          searched: 0,
          notFound: 0,
          ambiguous: 0,
          failed: 0,
          searchRequests: 0,
          budget: _PageSearchBudget(maxSearchRequests, targetCount),
        );
      } else {
        _pageWork = null;
      }
      _notify();
      return;
    }

    final work = _StreamingPageWork(
      append: false,
      candidateStart: 0,
      slotStart: 0,
      matchStart: 0,
      searched: 0,
      notFound: 0,
      ambiguous: 0,
      failed: 0,
      searchRequests: 0,
      budget: _PageSearchBudget(maxSearchRequests, targetCount),
    );
    work.slots.addAll(slots);
    work.committed = slots.every((slot) => slot.committed);
    _pageWork = work;
    matching = true;
    _launchQueuedStreamingSearches(_generation, work);
    _finishStreamingWorkIfIdle(_generation, work);
    _notify();
  }

  Future<void> _acceptBatch(
    int generation,
    RecommendationBatch batch, {
    required bool append,
  }) async {
    fromCache = batch.fromCache;
    coldStart = batch.isColdStart;
    sessionId = batch.sessionId;
    pageIndex = batch.page.index;
    nextCursor = batch.page.nextCursor;
    hasMore = batch.page.hasMore && !_cursorExpired(batch);
    if (coldStart) {
      matching = false;
      _notify();
      return;
    }

    final seen = candidates.map((item) => item.identity).toSet();
    final pageCandidates =
        <({RecommendationCandidate candidate, int position})>[];
    final rawCandidates = batch.items.take(maxCandidates).toList();
    for (var position = 0; position < rawCandidates.length; position++) {
      final candidate = rawCandidates[position];
      if (seen.add(candidate.identity)) {
        pageCandidates.add((candidate: candidate, position: position + 1));
      }
    }
    final offset = candidates.length;
    candidates.addAll(pageCandidates.map((entry) => entry.candidate));
    final pageSlots = [
      for (final entry in pageCandidates)
        RecommendedCandidateSlot(
          candidate: entry.candidate,
          pageIndex: batch.page.index,
          candidatePosition: entry.position,
          sessionId: batch.sessionId,
        )..committed = true,
    ];
    slots.addAll(pageSlots);
    if (pageCandidates.isEmpty) {
      _notify();
      return;
    }
    matching = true;
    _notify();
    final matchWatch = Stopwatch()..start();
    final budget = _PageSearchBudget(maxSearchRequests, targetCount);
    var cursor = 0;
    Future<void> worker() async {
      while (_current(generation) && budget.hasMatchCapacity) {
        final localIndex = cursor++;
        if (localIndex >= pageCandidates.length) return;
        await _searchCandidate(
          generation,
          offset + localIndex,
          pageSlots[localIndex],
          budget,
        );
      }
    }

    await Future.wait([
      for (var i = 0; i < maxConcurrentSearches; i++) worker(),
    ]);
    if (_current(generation)) {
      matchingDuration += matchWatch.elapsed;
      matching = false;
      loadingMore = false;
      if (items.isNotEmpty) {
        try {
          await recommendationRepository.writePlayableCache(
            history: _history,
            library: _library,
            sourceFingerprint: _sourceFingerprint,
            videos: items,
          );
        } catch (_) {
          // 写缓存失败只影响下次复用，不能把本次成功匹配变成错误。
        }
      }
      if (!_current(generation)) return;
      _notify();
    }
  }

  Future<bool> _searchCandidate(
    int generation,
    int index,
    RecommendedCandidateSlot slot,
    _PageSearchBudget budget, {
    _StreamingPageWork? streamWork,
  }) async {
    bool active() => _current(generation) && !(streamWork?.cancelled ?? false);
    final matchingSource = source;
    final matchingFingerprint = _sourceFingerprint;
    final candidate = slot.candidate;
    var sawAmbiguous = false;
    var sawFailure = false;
    for (final query in candidate.searchTarget.searchQueries.take(
      maxQueriesPerCandidate,
    )) {
      if (!active() || !budget.take()) break;
      searchRequests++;
      slot
        ..status = RecommendedCandidateStatus.searching
        ..lastError = null;
      _notify();
      final lease = _searchPool.acquire(
        sourceFingerprint: matchingFingerprint,
        query: query,
        loader: (abortTrigger) => videoRepository is CancellableVideoRepository
            ? (videoRepository as CancellableVideoRepository)
                  .fetchPageCancellable(
                    matchingSource,
                    page: 1,
                    keyword: query,
                    abortTrigger: abortTrigger,
                  )
            : videoRepository.fetchPage(
                matchingSource,
                page: 1,
                keyword: query,
              ),
      );
      streamWork?.leases.add(lease);
      try {
        final pooled = await lease.future;
        if (!active()) return false;
        final resultCount = pooled.page.total ?? pooled.page.items.length;
        if (slot.evidenceQuery.isEmpty || resultCount > slot.rawResultCount) {
          slot
            ..evidenceQuery = query
            ..rawResultCount = resultCount
            ..candidateTitles = pooled.page.items
                .map((video) => video.title.trim())
                .where((title) => title.isNotEmpty)
                .take(5)
                .toList(growable: false);
        }
        final result = matcher.matchTarget(
          candidate.searchTarget,
          pooled.page.items,
        );
        if (result.outcome == VideoMatchOutcome.matched) {
          if (!budget.claimMatch()) {
            slot.status = RecommendedCandidateStatus.queued;
            return false;
          }
          _matches[index] = result.match!.video;
          slot
            ..status = RecommendedCandidateStatus.available
            ..matchedVideo = result.match!.video;
          _rebuildItems();
          searched++;
          _reportCommittedOutcome(slot);
          _notify();
          return true;
        }
        sawAmbiguous |= result.outcome == VideoMatchOutcome.ambiguous;
      } catch (exception) {
        if (active()) {
          sawFailure = true;
          slot.lastError = exception;
        }
      } finally {
        streamWork?.leases.remove(lease);
        lease.release();
      }
    }
    if (!active()) return false;
    searched++;
    if (sawAmbiguous) {
      ambiguous++;
      slot.status = RecommendedCandidateStatus.ambiguous;
    } else if (sawFailure) {
      failed++;
      slot.status = RecommendedCandidateStatus.failed;
    } else {
      notFound++;
      slot.status = RecommendedCandidateStatus.notFound;
    }
    _reportCommittedOutcome(slot);
    _notify();
    return false;
  }

  void reportManualEvent(
    RecommendedCandidateSlot slot,
    RecommendationEventType type,
  ) => _event(slot, type);

  void _event(RecommendedCandidateSlot slot, RecommendationEventType type) {
    final session = slot.sessionId;
    if (session == null) return;
    unawaited(
      recommendationRepository.reportEvent(
        RecommendationEvent(
          sessionId: session,
          pageIndex: slot.pageIndex,
          candidatePosition: slot.candidatePosition,
          type: type,
          occurredAt: DateTime.now(),
        ),
      ),
    );
  }

  bool _cursorExpired(RecommendationBatch batch) {
    final expiry = batch.expiresAt;
    return expiry != null && !DateTime.now().isBefore(expiry);
  }

  void _reset() {
    items.clear();
    candidates.clear();
    slots.clear();
    _matches.clear();
    searched = 0;
    notFound = 0;
    ambiguous = 0;
    failed = 0;
    searchRequests = 0;
    error = null;
    matching = false;
    loadingMore = false;
    streaming = false;
    fromCache = false;
    playableFromCache = false;
    coldStart = false;
    sessionId = null;
    pageIndex = 0;
    nextCursor = null;
    hasMore = false;
    matchingDuration = Duration.zero;
  }

  void _rebuildItems() {
    final seen = <String>{};
    final ordered = _matches.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    items
      ..clear()
      ..addAll(
        ordered
            .map((entry) => entry.value)
            .where((video) => seen.add(video.globalId)),
      );
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _sourceSwitchEpoch++;
    unawaited(_cancelActiveStream());
    super.dispose();
  }
}

class _StreamingPageWork {
  _StreamingPageWork({
    required this.append,
    required this.candidateStart,
    required this.slotStart,
    required this.matchStart,
    required this.searched,
    required this.notFound,
    required this.ambiguous,
    required this.failed,
    required this.searchRequests,
    required this.budget,
  });

  final bool append;
  final int candidateStart;
  final int slotStart;
  final int matchStart;
  final int searched;
  final int notFound;
  final int ambiguous;
  final int failed;
  final int searchRequests;
  final _PageSearchBudget budget;
  final List<RecommendedCandidateSlot> slots = [];
  final Set<CuratedVodSearchLease> leases = {};
  int activeSearches = 0;
  bool committed = false;
  bool cancelled = false;
}

class _PageSearchBudget {
  _PageSearchBudget(this.remaining, this.remainingMatches);
  int remaining;
  int remainingMatches;
  bool get hasMatchCapacity => remaining > 0 && remainingMatches > 0;
  bool take() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }

  bool claimMatch() {
    if (remainingMatches <= 0) return false;
    remainingMatches--;
    return true;
  }
}
