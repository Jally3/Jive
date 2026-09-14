import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/recommendation/ark_recommendation_client.dart';
import 'package:jive/data/recommendation/recommendation_client.dart';
import 'package:jive/data/recommendation/recommendation_repository.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/library.dart';
import 'package:jive/domain/recommendation.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:jive/features/home/curated_vod_search_pool.dart';
import 'package:jive/features/home/recommended_feed_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _source = VodSource(
  id: 'test',
  name: '测试源',
  baseUri: Uri.parse('https://example.com'),
  adapterType: 'test',
);

final _secondSource = VodSource(
  id: 'test-2',
  name: '测试源二',
  baseUri: Uri.parse('https://two.example.com'),
  adapterType: 'test',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('keeps model order while matching candidates against VOD', () async {
    final pool = CuratedVodSearchPool();
    addTearDown(pool.close);
    final controller = RecommendedFeedController(
      recommendationRepository: RecommendationRepository(
        client: _StaticRecommendationClient(),
        preferences: await SharedPreferences.getInstance(),
      ),
      videoRepository: _SearchVideoRepository(),
      source: _source,
      searchPool: pool,
      targetCount: 2,
    );
    addTearDown(controller.dispose);

    await controller.loadInitial(history: const [], library: const []);

    expect(controller.error, isNull);
    expect(controller.hasLoadedState, isTrue);
    expect(controller.items.map((item) => item.title), ['影片甲', '影片乙']);
    expect(controller.searched, 2);
    expect(controller.searchRequests, 2);
  });

  test(
    'reports real candidate progress while VOD matching is in flight',
    () async {
      final pool = CuratedVodSearchPool(maxConcurrentRequests: 1);
      addTearDown(pool.close);
      final videoRepository = _ControlledSearchVideoRepository();
      final controller = RecommendedFeedController(
        recommendationRepository: RecommendationRepository(
          client: _StaticRecommendationClient(),
          preferences: await SharedPreferences.getInstance(),
        ),
        videoRepository: videoRepository,
        source: _source,
        searchPool: pool,
        targetCount: 2,
        maxConcurrentSearches: 1,
      );
      addTearDown(controller.dispose);

      final loading = controller.loadInitial(
        history: const [],
        library: const [],
      );
      await videoRepository.waitForCalls(1);

      expect(controller.generating, isFalse);
      expect(controller.matching, isTrue);
      expect(controller.candidates, hasLength(2));
      expect(controller.searched, 0);
      expect(controller.items, isEmpty);

      videoRepository.completeNext();
      await videoRepository.waitForCalls(2);

      expect(controller.matching, isTrue);
      expect(controller.searched, 1);
      expect(controller.items, hasLength(1));

      videoRepository.completeNext();
      await loading;

      expect(controller.matching, isFalse);
      expect(controller.searched, 2);
      expect(controller.items, hasLength(2));
    },
  );

  test('shows a streamed VOD match before done commits the page', () async {
    final pool = CuratedVodSearchPool(maxConcurrentRequests: 1);
    addTearDown(pool.close);
    final streamClient = _StreamingRecommendationClient();
    final videoRepository = _ControlledSearchVideoRepository();
    final controller = RecommendedFeedController(
      recommendationRepository: RecommendationRepository(
        client: streamClient,
        preferences: await SharedPreferences.getInstance(),
      ),
      videoRepository: videoRepository,
      source: _source,
      searchPool: pool,
      maxConcurrentSearches: 1,
    );
    addTearDown(controller.dispose);

    final loading = controller.loadInitial(
      history: const [],
      library: const [],
    );
    await streamClient.waitUntilListened();
    streamClient.add(
      const RecommendationStreamStart(
        requestId: 'req-stream',
        clientRequestId: 'client-stream',
        mode: RecommendationMode.personalized,
        source: RecommendationSource.llm,
      ),
    );
    streamClient.add(
      const RecommendationStreamItem(
        index: 1,
        item: RecommendationCandidate(
          title: '影片甲',
          mediaType: TmdbMediaType.movie,
        ),
      ),
    );
    await videoRepository.waitForCalls(1);
    videoRepository.completeNext();
    await Future<void>.delayed(Duration.zero);

    expect(controller.streaming, isTrue);
    expect(controller.items.map((item) => item.title), ['影片甲']);
    expect(controller.sessionId, isNull);

    streamClient.add(
      RecommendationStreamDone(
        RecommendationBatch(
          requestId: 'req-stream',
          clientRequestId: 'client-stream',
          items: const [
            RecommendationCandidate(
              title: '影片甲',
              mediaType: TmdbMediaType.movie,
            ),
          ],
          generatedAt: DateTime.now(),
          sessionId: 'session-stream',
        ),
      ),
    );
    await streamClient.close();
    await loading;

    expect(controller.streaming, isFalse);
    expect(controller.sessionId, 'session-stream');
    expect(controller.items.map((item) => item.title), ['影片甲']);
  });

  test('tab hiding keeps the stream and resumes queued VOD matching', () async {
    final pool = CuratedVodSearchPool(maxConcurrentRequests: 1);
    addTearDown(pool.close);
    final streamClient = _StreamingRecommendationClient();
    final videoRepository = _ControlledSearchVideoRepository();
    final controller = RecommendedFeedController(
      recommendationRepository: RecommendationRepository(
        client: streamClient,
        preferences: await SharedPreferences.getInstance(),
      ),
      videoRepository: videoRepository,
      source: _source,
      searchPool: pool,
      maxConcurrentSearches: 1,
    );
    addTearDown(controller.dispose);

    final loading = controller.loadInitial(
      history: const [],
      library: const [],
    );
    await streamClient.waitUntilListened();
    streamClient.add(
      const RecommendationStreamStart(
        requestId: 'req-stream',
        clientRequestId: 'client-stream',
        mode: RecommendationMode.personalized,
        source: RecommendationSource.llm,
      ),
    );
    await _waitUntil(() => controller.streaming);
    controller.setViewActive(false);
    streamClient.add(
      const RecommendationStreamItem(
        index: 1,
        item: RecommendationCandidate(
          title: '影片甲',
          mediaType: TmdbMediaType.movie,
        ),
      ),
    );
    await _waitUntil(() => controller.candidates.length == 1);

    expect(videoRepository.calls, 0);
    expect(controller.streaming, isTrue);

    controller.setViewActive(true);
    await videoRepository.waitForCalls(1);
    videoRepository.completeNext();
    streamClient.add(
      RecommendationStreamDone(
        RecommendationBatch(
          requestId: 'req-stream',
          clientRequestId: 'client-stream',
          items: const [
            RecommendationCandidate(
              title: '影片甲',
              mediaType: TmdbMediaType.movie,
            ),
          ],
          generatedAt: DateTime.now(),
          sessionId: 'session-stream',
        ),
      ),
    );
    await streamClient.close();
    await loading;

    expect(controller.items.map((item) => item.title), ['影片甲']);
    expect(controller.sessionId, 'session-stream');
  });

  test(
    'reuses current-source playable cache without calling recommendations',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final client = _CountingRecommendationClient();
      final recommendationRepository = RecommendationRepository(
        client: client,
        preferences: preferences,
        freshDuration: Duration.zero,
      );
      final videoRepository = _CountingVideoRepository();
      final firstPool = CuratedVodSearchPool();
      addTearDown(firstPool.close);
      final first = RecommendedFeedController(
        recommendationRepository: recommendationRepository,
        videoRepository: videoRepository,
        source: _source,
        searchPool: firstPool,
        targetCount: 2,
      );
      await first.loadInitial(history: const [], library: const []);
      first.dispose();

      expect(client.calls, 1);
      expect(videoRepository.calls, 2);

      final secondPool = CuratedVodSearchPool();
      addTearDown(secondPool.close);
      final second = RecommendedFeedController(
        recommendationRepository: recommendationRepository,
        videoRepository: videoRepository,
        source: _source,
        searchPool: secondPool,
        targetCount: 2,
      );
      addTearDown(second.dispose);
      await second.loadInitial(history: const [], library: const []);

      expect(client.calls, 1);
      expect(videoRepository.calls, 2);
      expect(second.playableFromCache, isTrue);
      expect(second.candidates, isEmpty);
      expect(second.items.map((item) => item.title), ['影片甲', '影片乙']);

      await second.refresh(history: const [], library: const []);
      expect(client.calls, 2);
      expect(videoRepository.calls, 4);
      expect(second.playableFromCache, isFalse);
    },
  );

  test(
    'coalesces the same cursor and appends the next page in order',
    () async {
      final pool = CuratedVodSearchPool();
      addTearDown(pool.close);
      final client = _PagedRecommendationClient();
      final controller = RecommendedFeedController(
        recommendationRepository: RecommendationRepository(
          client: client,
          preferences: await SharedPreferences.getInstance(),
        ),
        videoRepository: _SearchVideoRepository(),
        source: _source,
        searchPool: pool,
        targetCount: 2,
      );
      addTearDown(controller.dispose);
      await controller.loadInitial(history: const [], library: const []);

      final first = controller.loadMore();
      final second = controller.loadMore();

      expect(identical(first, second), isTrue);
      expect(client.nextCalls, 1);
      expect(controller.fetchingMore, isTrue);
      expect(controller.matchingMore, isFalse);
      client.completeNext();
      await first;
      expect(controller.fetchingMore, isFalse);
      expect(controller.items.map((item) => item.title), ['影片甲', '影片乙']);
      expect(controller.hasMore, isFalse);
      expect(controller.pageIndex, 2);
    },
  );

  test('cold start does not search the VOD source', () async {
    final pool = CuratedVodSearchPool();
    addTearDown(pool.close);
    final repository = _CountingVideoRepository();
    final controller = RecommendedFeedController(
      recommendationRepository: RecommendationRepository(
        client: _ColdStartRecommendationClient(),
        preferences: await SharedPreferences.getInstance(),
      ),
      videoRepository: repository,
      source: _source,
      searchPool: pool,
    );
    addTearDown(controller.dispose);

    await controller.loadInitial(history: const [], library: const []);

    expect(controller.coldStart, isTrue);
    expect(repository.calls, 0);
    expect(controller.items, isEmpty);
  });

  test(
    'switching VOD source preserves recommendation session and rematches',
    () async {
      final pool = CuratedVodSearchPool();
      addTearDown(pool.close);
      final client = _SessionRecommendationClient();
      final videoRepository = _CountingVideoRepository();
      final controller = RecommendedFeedController(
        recommendationRepository: RecommendationRepository(
          client: client,
          preferences: await SharedPreferences.getInstance(),
        ),
        videoRepository: videoRepository,
        source: _source,
        searchPool: pool,
        targetCount: 2,
      );
      addTearDown(controller.dispose);
      await controller.loadInitial(history: const [], library: const []);
      final identities = controller.candidates
          .map((candidate) => candidate.identity)
          .toList();

      await controller.switchVodSource(_secondSource);
      await _waitUntil(() => !controller.matching);

      expect(client.calls, 1);
      expect(controller.sessionId, 'session-stable');
      expect(controller.nextCursor, 'cursor-stable');
      expect(
        controller.candidates.map((candidate) => candidate.identity),
        identities,
      );
      expect(controller.items, hasLength(2));
      expect(
        controller.items.every((video) => video.sourceId == _secondSource.id),
        isTrue,
      );
      expect(videoRepository.calls, 4);
    },
  );

  test('keeps per-candidate evidence for manual confirmation', () async {
    final pool = CuratedVodSearchPool();
    addTearDown(pool.close);
    final controller = RecommendedFeedController(
      recommendationRepository: RecommendationRepository(
        client: _StaticRecommendationClient(),
        preferences: await SharedPreferences.getInstance(),
      ),
      videoRepository: _NoMatchVideoRepository(),
      source: _source,
      searchPool: pool,
    );
    addTearDown(controller.dispose);

    await controller.loadInitial(history: const [], library: const []);

    expect(controller.items, isEmpty);
    expect(controller.unavailableSlots, hasLength(2));
    expect(
      controller.unavailableSlots.first.status,
      RecommendedCandidateStatus.notFound,
    );
    expect(controller.unavailableSlots.first.rawResultCount, 1);
    expect(controller.unavailableSlots.first.candidateTitles, ['完全不同']);
  });
}

class _StaticRecommendationClient implements RecommendationClient {
  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) async => RecommendationBatch(
    items: const [
      RecommendationCandidate(title: '影片甲', mediaType: TmdbMediaType.movie),
      RecommendationCandidate(title: '影片乙', mediaType: TmdbMediaType.movie),
    ],
    generatedAt: DateTime.now(),
  );
}

class _StreamingRecommendationClient
    implements RecommendationClient, StreamingRecommendationClient {
  _StreamingRecommendationClient() {
    _controller = StreamController<RecommendationStreamEvent>(
      onListen: _listened.complete,
    );
  }

  final _listened = Completer<void>();
  late final StreamController<RecommendationStreamEvent> _controller;

  Future<void> waitUntilListened() => _listened.future;
  void add(RecommendationStreamEvent event) => _controller.add(event);
  Future<void> close() => _controller.close();

  @override
  RecommendationStreamRequest recommendStream({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) => RecommendationStreamRequest(
    events: _controller.stream,
    cancel: () async {},
  );

  @override
  RecommendationStreamRequest nextPageStream(String cursor) =>
      throw UnimplementedError();

  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) => throw UnimplementedError();
}

class _CountingRecommendationClient extends _StaticRecommendationClient {
  int calls = 0;

  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) {
    calls++;
    return super.recommend(history: history, library: library);
  }
}

class _SessionRecommendationClient implements RecommendationClient {
  int calls = 0;

  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) async {
    calls++;
    return RecommendationBatch(
      items: const [
        RecommendationCandidate(title: '影片甲', mediaType: TmdbMediaType.movie),
        RecommendationCandidate(title: '影片乙', mediaType: TmdbMediaType.movie),
      ],
      generatedAt: DateTime.now(),
      sessionId: 'session-stable',
      page: const RecommendationPage(
        index: 1,
        hasMore: true,
        nextCursor: 'cursor-stable',
      ),
    );
  }
}

class _SearchVideoRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [
      Video(id: keyword!, sourceId: source.id, title: keyword, category: '电影片'),
    ],
    page: 1,
    pageCount: 1,
  );

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

class _ControlledSearchVideoRepository extends _SearchVideoRepository {
  final List<({String keyword, Completer<VideoPage> completer})> _pending = [];
  final List<Completer<void>> _callWaiters = [];

  int get calls => _pending.length;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    final completer = Completer<VideoPage>();
    _pending.add((keyword: keyword!, completer: completer));
    for (final waiter in _callWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _callWaiters.clear();
    return completer.future;
  }

  Future<void> waitForCalls(int count) async {
    while (_pending.length < count) {
      final waiter = Completer<void>();
      _callWaiters.add(waiter);
      await waiter.future;
    }
  }

  void completeNext() {
    final request = _pending.firstWhere((item) => !item.completer.isCompleted);
    request.completer.complete(
      VideoPage(
        items: [
          Video(
            id: request.keyword,
            sourceId: _source.id,
            title: request.keyword,
            category: '电影片',
          ),
        ],
        page: 1,
        pageCount: 1,
      ),
    );
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  while (!condition()) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _PagedRecommendationClient implements PaginatedRecommendationClient {
  final _next = Completer<RecommendationBatch>();
  int nextCalls = 0;

  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) async => RecommendationBatch(
    items: const [
      RecommendationCandidate(title: '影片甲', mediaType: TmdbMediaType.movie),
    ],
    generatedAt: DateTime.now(),
    sessionId: 'session',
    page: const RecommendationPage(
      index: 1,
      hasMore: true,
      nextCursor: 'cursor-2',
    ),
  );

  @override
  Future<RecommendationBatch> nextPage(String cursor) {
    nextCalls++;
    return _next.future;
  }

  void completeNext() => _next.complete(
    RecommendationBatch(
      items: const [
        RecommendationCandidate(title: '影片乙', mediaType: TmdbMediaType.movie),
      ],
      generatedAt: DateTime.now(),
      sessionId: 'session',
      page: const RecommendationPage(index: 2),
    ),
  );

  @override
  Future<void> reportEvent(RecommendationEvent event) async {}
}

class _ColdStartRecommendationClient implements RecommendationClient {
  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) async => RecommendationBatch(
    items: const [],
    generatedAt: DateTime.now(),
    mode: RecommendationMode.coldStart,
    source: RecommendationSource.none,
  );
}

class _CountingVideoRepository extends _SearchVideoRepository {
  int calls = 0;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    calls++;
    return super.fetchPage(
      source,
      page: page,
      categoryId: categoryId,
      keyword: keyword,
    );
  }
}

class _NoMatchVideoRepository extends _SearchVideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: const [Video(id: 'other', title: '完全不同', category: '电影片')],
    page: 1,
    pageCount: 1,
    total: 1,
  );
}
