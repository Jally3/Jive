import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/catalog/tmdb_catalog_repository.dart';
import 'package:jive/data/content/video_matcher.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/video_feed.dart';
import 'package:jive/domain/video_search_target.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/home/curated_feed_controller.dart';

void main() {
  test(
    'keeps the first twenty Catalog slots without scanning for replacements',
    () async {
      final videoRepository = _HalfMatchVideoRepository();
      final controller = CuratedFeedController(
        catalogRepository: _FakeCatalogRepository(30),
        videoRepository: videoRepository,
        source: _source,
      );
      addTearDown(controller.dispose);

      await controller.selectFeed(VideoFeed.popular);

      expect(controller.slots, hasLength(20));
      expect(controller.items, hasLength(10));
      expect(videoRepository.calls, 20);
      expect(controller.items.first.rank, 2);
      expect(controller.items.last.rank, 20);
      expect(controller.hasMore, isTrue);
    },
  );

  test('scope change restarts from the selected ordered group', () async {
    final controller = CuratedFeedController(
      catalogRepository: _FakeCatalogRepository(30),
      videoRepository: _AllMatchVideoRepository(),
      source: _source,
    );
    addTearDown(controller.dispose);
    await controller.selectFeed(VideoFeed.topRated);

    await controller.selectScope(TmdbCatalogScope.animation);

    expect(controller.items, hasLength(1));
    expect(controller.items.single.title, '影片2');
    expect(controller.items.single.rank, 1);
  });

  test('feed changes preserve the selected scope', () async {
    final controller = CuratedFeedController(
      catalogRepository: _FakeCatalogRepository(30),
      videoRepository: _AllMatchVideoRepository(),
      source: _source,
      scope: TmdbCatalogScope.animation,
    );
    addTearDown(controller.dispose);

    await controller.selectFeed(VideoFeed.popular);
    await controller.selectFeed(VideoFeed.topRated);

    expect(controller.scope, TmdbCatalogScope.animation);
    expect(controller.items.single.title, '影片2');
  });

  test('supported empty scope remains selected and renders empty', () async {
    final videoRepository = _CountingAllMatchVideoRepository();
    final controller = CuratedFeedController(
      catalogRepository: _ScopeCatalogRepository(animationIds: const []),
      videoRepository: videoRepository,
      source: _source,
      scope: TmdbCatalogScope.animation,
    );
    addTearDown(controller.dispose);

    await controller.selectFeed(VideoFeed.topRated);

    expect(controller.scope, TmdbCatalogScope.animation);
    expect(controller.items, isEmpty);
    expect(controller.hasMore, isFalse);
    expect(videoRepository.calls, 0);
  });

  test('missing scope falls back to all', () async {
    final controller = CuratedFeedController(
      catalogRepository: _ScopeCatalogRepository(),
      videoRepository: _AllMatchVideoRepository(),
      source: _source,
      scope: TmdbCatalogScope.animation,
    );
    addTearDown(controller.dispose);

    await controller.selectFeed(VideoFeed.topRated);

    expect(controller.scope, TmdbCatalogScope.all);
    expect(controller.items.single.title, '影片1');
  });

  test('switching back to a curated feed restores matched results', () async {
    final videoRepository = _CountingAllMatchVideoRepository();
    final controller = CuratedFeedController(
      catalogRepository: _FakeCatalogRepository(10),
      videoRepository: videoRepository,
      source: _source,
      targetCount: 2,
      maxCandidatesPerLoad: 2,
    );
    addTearDown(controller.dispose);

    await controller.selectFeed(VideoFeed.popular);
    await controller.selectFeed(VideoFeed.topRated);
    expect(videoRepository.calls, 2);

    await controller.selectFeed(VideoFeed.popular);

    expect(videoRepository.calls, 2);
    expect(controller.items.map((item) => item.title), ['影片1', '影片2']);
    expect(controller.hasMore, isTrue);
  });

  test('scope results are cached independently', () async {
    final videoRepository = _CountingAllMatchVideoRepository();
    final controller = CuratedFeedController(
      catalogRepository: _FakeCatalogRepository(10),
      videoRepository: videoRepository,
      source: _source,
      targetCount: 2,
      maxCandidatesPerLoad: 2,
    );
    addTearDown(controller.dispose);

    await controller.selectFeed(VideoFeed.popular);
    await controller.selectScope(TmdbCatalogScope.animation);
    expect(videoRepository.calls, 2);

    await controller.selectScope(TmdbCatalogScope.all);

    expect(videoRepository.calls, 2);
    expect(controller.items.map((item) => item.title), ['影片1', '影片2']);
  });

  test(
    'cross-feed reuse rematerializes feed-specific rank and metadata',
    () async {
      final videoRepository = _CountingAllMatchVideoRepository();
      final controller = CuratedFeedController(
        catalogRepository: _CrossFeedCatalogRepository(),
        videoRepository: videoRepository,
        source: _source,
        targetCount: 2,
        maxCandidatesPerLoad: 2,
      );
      addTearDown(controller.dispose);

      await controller.selectFeed(VideoFeed.popular);
      expect(videoRepository.calls, 2);
      expect(controller.items.last.rank, 2);

      await controller.selectFeed(VideoFeed.topRated);

      expect(videoRepository.calls, 2);
      expect(controller.items.single.rank, 1);
      expect(controller.items.single.rating, 9.6);
      expect(
        controller.items.single.posterUrl,
        'https://image.tmdb.org/t/p/w500/top-rated.jpg',
      );
    },
  );

  test(
    'cross-feed switch joins identical searches already in flight',
    () async {
      final videoRepository = _ControlledVideoRepository();
      final controller = CuratedFeedController(
        catalogRepository: _FakeCatalogRepository(2),
        videoRepository: videoRepository,
        source: _source,
        targetCount: 2,
        maxCandidatesPerLoad: 2,
        maxConcurrentSearches: 2,
      );
      addTearDown(controller.dispose);

      final popularLoad = controller.selectFeed(VideoFeed.popular);
      await _waitFor(() => videoRepository.pendingCount('影片') == 2);
      final topRatedLoad = controller.selectFeed(VideoFeed.topRated);
      await Future<void>.delayed(Duration.zero);

      expect(videoRepository.callCount('影片'), 2);
      videoRepository.completePrefix('影片');
      await Future.wait([popularLoad, topRatedLoad]);

      expect(videoRepository.callCount('影片'), 2);
      expect(controller.items, hasLength(2));
    },
  );

  test('publishes Catalog slots before individual searches complete', () async {
    final videoRepository = _ControlledVideoRepository();
    final controller = CuratedFeedController(
      catalogRepository: _FakeCatalogRepository(3),
      videoRepository: videoRepository,
      source: _source,
      maxCandidatesPerLoad: 3,
      maxConcurrentSearches: 2,
    );
    addTearDown(controller.dispose);

    final load = controller.selectFeed(VideoFeed.popular);
    await _waitFor(() => controller.slots.length == 3);
    expect(controller.slots.map((slot) => slot.catalogItem.rank), [1, 2, 3]);
    expect(controller.items, isEmpty);

    await _waitFor(() => videoRepository.pendingCount('影片') == 2);
    videoRepository.complete('影片2');
    await _waitFor(
      () => controller.slots[1].status == CuratedSlotStatus.available,
    );
    expect(controller.slots[0].status, CuratedSlotStatus.searching);
    expect(controller.items.single.rank, 2);

    videoRepository.completePrefix('影片');
    await load;
  });

  test(
    'higher Catalog rank deterministically owns a duplicate VOD result',
    () async {
      final repository = _ControlledVideoRepository();
      final controller = CuratedFeedController(
        catalogRepository: _FakeCatalogRepository(2),
        videoRepository: repository,
        source: _source,
        matcher: const _AlwaysMatchMatcher(),
        maxCandidatesPerLoad: 2,
        maxConcurrentSearches: 2,
      );
      addTearDown(controller.dispose);

      final load = controller.selectFeed(VideoFeed.popular);
      await _waitFor(() => repository.pendingCount('影片') == 2);
      repository.complete('影片2', id: 'shared');
      await _waitFor(
        () => controller.slots[1].status == CuratedSlotStatus.available,
      );
      repository.complete('影片1', id: 'shared');
      await load;

      expect(controller.slots[0].status, CuratedSlotStatus.available);
      expect(controller.slots[1].status, CuratedSlotStatus.duplicate);
      expect(controller.items.single.rank, 1);
    },
  );

  test('switching away mid-load resumes the same session on return', () async {
    final videoRepository = _ControlledVideoRepository();
    final controller = CuratedFeedController(
      catalogRepository: _FeedSpecificCatalogRepository(),
      videoRepository: videoRepository,
      source: _source,
      targetCount: 2,
      maxCandidatesPerLoad: 2,
      maxConcurrentSearches: 2,
    );
    addTearDown(controller.dispose);

    final popularLoad = controller.selectFeed(VideoFeed.popular);
    await _waitFor(() => videoRepository.pendingCount('popular') == 2);

    final topRatedLoad = controller.selectFeed(VideoFeed.topRated);
    await _waitFor(() => videoRepository.pendingCount('topRated') == 1);
    videoRepository.completePrefix('popular');
    await popularLoad;
    await _waitFor(() => videoRepository.pendingCount('topRated') == 2);

    final resumedLoad = controller.selectFeed(VideoFeed.popular);
    await resumedLoad;

    expect(videoRepository.callCount('popular'), 2);
    expect(controller.items.map((video) => video.title), [
      'popular-1',
      'popular-2',
    ]);
    expect(controller.searched, 2);

    videoRepository.completePrefix('topRated');
    await topRatedLoad;
    expect(controller.searched, 2);
  });

  test('manual refresh bypasses the matched view cache', () async {
    final catalogRepository = _FakeCatalogRepository(10);
    final videoRepository = _CountingAllMatchVideoRepository();
    final controller = CuratedFeedController(
      catalogRepository: catalogRepository,
      videoRepository: videoRepository,
      source: _source,
      targetCount: 2,
      maxCandidatesPerLoad: 2,
    );
    addTearDown(controller.dispose);
    await controller.selectFeed(VideoFeed.popular);
    expect(videoRepository.calls, 2);

    catalogRepository.revision = 'r2';
    await controller.refresh();

    expect(videoRepository.calls, 4);
  });

  test('keeps not found and request failed entries separate', () async {
    final controller = CuratedFeedController(
      catalogRepository: _FakeCatalogRepository(3),
      videoRepository: _MixedResultVideoRepository(),
      source: _source,
      targetCount: 3,
      maxCandidatesPerLoad: 3,
    );
    addTearDown(controller.dispose);

    await controller.selectFeed(VideoFeed.popular);

    expect(controller.items.map((video) => video.title), ['影片1']);
    expect(controller.unavailableEntries, hasLength(1));
    expect(
      controller.unavailableEntries.single.catalogItem.localizedTitle,
      '影片2',
    );
    expect(controller.unavailableEntries.single.rawResultCount, 13);
    expect(controller.unavailableEntries.single.query, '影片2');
    expect(controller.unavailableEntries.single.candidateTitles, ['完全无关的候选']);
    expect(controller.failedEntries, hasLength(1));
    expect(controller.failedEntries.single.catalogItem.localizedTitle, '影片3');
    expect(controller.failedEntries.single.rawResultCount, 0);
    expect(controller.failedEntries.single.query, '影片3');
  });

  test(
    'keeps the Chinese evidence query when the English fallback is empty',
    () async {
      final repository = _ChineseEvidenceVideoRepository();
      final controller = CuratedFeedController(
        catalogRepository: _BilingualCatalogRepository(),
        videoRepository: repository,
        source: _source,
      );
      addTearDown(controller.dispose);

      await controller.selectFeed(VideoFeed.popular);

      expect(repository.calls, ['瑞克和莫蒂', 'Rick and Morty']);
      expect(controller.unavailableEntries, hasLength(1));
      final entry = controller.unavailableEntries.single;
      expect(entry.query, '瑞克和莫蒂');
      expect(entry.rawResultCount, 9);
      expect(entry.candidateTitles, ['瑞克和莫蒂第九季', '瑞克和莫蒂第八季']);
      expect(controller.slots.single.currentQuery, 'Rick and Morty');
      expect(controller.slots.single.evidenceQuery, '瑞克和莫蒂');
    },
  );

  test('variety fallback presents the matched VOD season metadata', () async {
    final controller = CuratedFeedController(
      catalogRepository: _VarietyCatalogRepository(),
      videoRepository: _VarietyVideoRepository(),
      source: _source,
      feed: VideoFeed.popular,
      scope: TmdbCatalogScope.variety,
    );
    addTearDown(controller.dispose);

    await controller.loadInitial();

    expect(controller.unavailableEntries, isEmpty);
    expect(controller.items, hasLength(1));
    expect(controller.items.single.title, '花儿与少年 第八季');
    expect(controller.items.single.year, '2026');
    expect(controller.items.single.posterUrl, 'https://vod.test/season-8.jpg');
    expect(
      controller.items.single.backupPosterUrl,
      'https://image.tmdb.org/t/p/w500/tmdb-parent.jpg',
    );
    expect(controller.items.single.rank, 1);
  });
}

final _source = VodSource(
  id: 'source',
  name: 'Source',
  baseUri: Uri.parse('https://example.com'),
  adapterType: 'test',
);

class _FakeCatalogRepository implements TmdbCatalogRepository {
  _FakeCatalogRepository(this.count);
  final int count;
  String revision = 'r1';

  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    final items = {
      for (var i = 1; i <= count; i++)
        'tmdb:movie:$i': TmdbCatalogItem(
          tmdbId: i,
          mediaType: TmdbMediaType.movie,
          category: i == 2 ? 'animation' : 'movie',
          localizedTitle: '影片$i',
          originalTitle: '影片$i',
        ),
    };
    return TmdbCatalogSnapshot(
      feed: feed,
      revision: revision,
      supportedScopes: const {TmdbCatalogScope.all, TmdbCatalogScope.animation},
      groups: {
        TmdbCatalogScope.all: items.keys.toList(),
        TmdbCatalogScope.animation: ['tmdb:movie:2'],
      },
      items: items,
    );
  }
}

class _ScopeCatalogRepository implements TmdbCatalogRepository {
  _ScopeCatalogRepository({this.animationIds});

  final List<String>? animationIds;

  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    const id = 'tmdb:movie:1';
    return TmdbCatalogSnapshot(
      feed: feed,
      revision: 'scope-test',
      supportedScopes: {
        TmdbCatalogScope.all,
        if (animationIds != null) TmdbCatalogScope.animation,
      },
      groups: {
        TmdbCatalogScope.all: const [id],
        if (animationIds != null) TmdbCatalogScope.animation: animationIds!,
      },
      items: const {
        id: TmdbCatalogItem(
          tmdbId: 1,
          mediaType: TmdbMediaType.movie,
          category: 'movie',
          localizedTitle: '影片1',
          originalTitle: '影片1',
        ),
      },
    );
  }
}

class _FeedSpecificCatalogRepository implements TmdbCatalogRepository {
  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    final prefix = feed.name;
    final items = {
      for (var index = 1; index <= 2; index++)
        'tmdb:movie:$prefix-$index': TmdbCatalogItem(
          tmdbId: index,
          mediaType: TmdbMediaType.movie,
          category: 'movie',
          localizedTitle: '$prefix-$index',
          originalTitle: '$prefix-$index',
        ),
    };
    return TmdbCatalogSnapshot(
      feed: feed,
      revision: 'controlled-$prefix',
      supportedScopes: const {TmdbCatalogScope.all},
      groups: {TmdbCatalogScope.all: items.keys.toList()},
      items: items,
    );
  }
}

class _CrossFeedCatalogRepository implements TmdbCatalogRepository {
  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    final topRated = feed == VideoFeed.topRated;
    final shared = TmdbCatalogItem(
      tmdbId: 1,
      mediaType: TmdbMediaType.movie,
      category: 'movie',
      localizedTitle: '共享影片',
      originalTitle: '共享影片',
      rating: topRated ? 9.6 : 6.2,
      posterPath: topRated ? '/top-rated.jpg' : '/popular.jpg',
    );
    const other = TmdbCatalogItem(
      tmdbId: 2,
      mediaType: TmdbMediaType.movie,
      category: 'movie',
      localizedTitle: '其他影片',
      originalTitle: '其他影片',
    );
    final items = {shared.globalId: shared, other.globalId: other};
    return TmdbCatalogSnapshot(
      feed: feed,
      revision: feed.name,
      supportedScopes: const {TmdbCatalogScope.all},
      groups: {
        TmdbCatalogScope.all: topRated
            ? [shared.globalId]
            : [other.globalId, shared.globalId],
      },
      items: items,
    );
  }
}

class _ControlledVideoRepository extends _AllMatchVideoRepository {
  final Map<String, Completer<VideoPage>> _pending = {};
  final List<String> calls = [];

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    calls.add(keyword!);
    return (_pending[keyword] ??= Completer<VideoPage>()).future;
  }

  int pendingCount(String prefix) =>
      _pending.keys.where((keyword) => keyword.startsWith(prefix)).length;

  int callCount(String prefix) =>
      calls.where((keyword) => keyword.startsWith(prefix)).length;

  void completePrefix(String prefix) {
    for (final entry in _pending.entries.where(
      (entry) => entry.key.startsWith(prefix),
    )) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          VideoPage(
            items: [Video(id: entry.key, title: entry.key, category: '电影片')],
            page: 1,
            pageCount: 1,
          ),
        );
      }
    }
  }

  void complete(String keyword, {String? id}) {
    final pending = _pending[keyword];
    if (pending == null || pending.isCompleted) return;
    pending.complete(
      VideoPage(
        items: [Video(id: id ?? keyword, title: keyword, category: '电影片')],
        page: 1,
        pageCount: 1,
      ),
    );
  }
}

class _AlwaysMatchMatcher extends VideoMatcher {
  const _AlwaysMatchMatcher();

  @override
  VideoMatchResult matchTarget(VideoSearchTarget target, List<Video> results) =>
      VideoMatchResult.matched(VideoMatch(video: results.first, score: 999));
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

class _VarietyCatalogRepository implements TmdbCatalogRepository {
  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    const id = 'tmdb:tv:121876';
    return const TmdbCatalogSnapshot(
      feed: VideoFeed.popular,
      revision: 'variety-test',
      supportedScopes: {TmdbCatalogScope.all, TmdbCatalogScope.variety},
      groups: {
        TmdbCatalogScope.all: [id],
        TmdbCatalogScope.variety: [id],
      },
      items: {
        id: TmdbCatalogItem(
          tmdbId: 121876,
          mediaType: TmdbMediaType.tv,
          category: 'variety',
          localizedTitle: '花儿与少年',
          originalTitle: '花儿与少年',
          releaseDate: '2014-04-25',
          posterPath: '/tmdb-parent.jpg',
        ),
      },
    );
  }
}

class _AllMatchVideoRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [Video(id: keyword!, title: keyword, category: '电影片')],
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

class _CountingAllMatchVideoRepository extends _AllMatchVideoRepository {
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

class _HalfMatchVideoRepository extends _AllMatchVideoRepository {
  int calls = 0;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    calls++;
    final number = int.parse(keyword!.substring(2));
    return VideoPage(
      items: number.isEven
          ? [Video(id: '$number', title: keyword, category: '电影片')]
          : const [],
      page: 1,
      pageCount: 1,
    );
  }
}

class _MixedResultVideoRepository extends _AllMatchVideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    if (keyword == '影片3') throw const VideoDataException('请求失败');
    if (keyword == '影片2') {
      return const VideoPage(
        items: [Video(id: 'unrelated', title: '完全无关的候选', category: '电影片')],
        page: 1,
        pageCount: 2,
        total: 13,
      );
    }
    return super.fetchPage(
      source,
      page: page,
      categoryId: categoryId,
      keyword: keyword,
    );
  }
}

class _BilingualCatalogRepository implements TmdbCatalogRepository {
  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async => const TmdbCatalogSnapshot(
    feed: VideoFeed.popular,
    revision: 'bilingual',
    supportedScopes: {TmdbCatalogScope.all},
    groups: {
      TmdbCatalogScope.all: ['tmdb:tv:60625'],
    },
    items: {
      'tmdb:tv:60625': TmdbCatalogItem(
        tmdbId: 60625,
        mediaType: TmdbMediaType.tv,
        category: 'animation',
        localizedTitle: '瑞克和莫蒂',
        originalTitle: 'Rick and Morty',
        releaseDate: '2013-12-02',
      ),
    },
  );
}

class _ChineseEvidenceVideoRepository extends _AllMatchVideoRepository {
  final List<String> calls = [];

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    calls.add(keyword!);
    if (keyword == 'Rick and Morty') {
      return const VideoPage(items: [], page: 1, pageCount: 1);
    }
    return const VideoPage(
      items: [
        Video(id: 'season-9', title: '瑞克和莫蒂第九季'),
        Video(id: 'season-8', title: '瑞克和莫蒂第八季'),
      ],
      page: 1,
      pageCount: 1,
      total: 9,
    );
  }
}

class _VarietyVideoRepository extends _AllMatchVideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => const VideoPage(
    items: [
      Video(
        id: '8',
        title: '花儿与少年 第八季',
        category: '综艺',
        year: '2026',
        posterUrl: 'https://vod.test/season-8.jpg',
      ),
      Video(
        id: 'special',
        title: '花儿与少年 第九季 会员彩蛋',
        category: '综艺',
        year: '2027',
      ),
      Video(id: '6', title: '花儿与少年 第六季', category: '综艺', year: '2024'),
    ],
    page: 1,
    pageCount: 1,
  );
}
