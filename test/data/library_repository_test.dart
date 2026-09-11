import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/library_repository.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/library.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const video = Video(
    id: '1',
    title: '影片',
    posterUrl: 'poster',
    typeId: 20,
    category: '电影',
    episodes: [Episode(id: 'ep', name: '正片', url: 'https://secret')],
  );
  final now = DateTime.utc(2026, 8, 12);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'favorites persist snapshots without playback urls and deduplicate',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repository = LibraryRepository(preferences: prefs);
      await repository.saveFavorite(
        FavoriteRecord(video: video, createdAt: now, updatedAt: now),
      );
      await repository.saveFavorite(
        FavoriteRecord(
          video: video,
          createdAt: now.add(const Duration(days: 1)),
          updatedAt: now.add(const Duration(days: 1)),
        ),
      );
      final records = await repository.loadFavorites();
      expect(records, hasLength(1));
      expect(records.single.createdAt, now);
      expect(records.single.video.episodes, isEmpty);
      expect(
        prefs.getString(LibraryRepository.libraryKey),
        isNot(contains('secret')),
      );
    },
  );

  test('corrupt json and incomplete items are ignored', () async {
    SharedPreferences.setMockInitialValues({
      LibraryRepository.favoritesKey: '[broken',
    });
    final repository = LibraryRepository(
      preferences: await SharedPreferences.getInstance(),
    );
    expect(await repository.loadFavorites(), isEmpty);
  });

  test('legacy favorites migrate as saved and not followed', () async {
    final legacy = FavoriteRecord(video: video, createdAt: now, updatedAt: now);
    SharedPreferences.setMockInitialValues({
      LibraryRepository.favoritesKey: '[${jsonEncode(legacy.toJson())}]',
    });
    final repository = LibraryRepository(
      preferences: await SharedPreferences.getInstance(),
    );
    final records = await repository.loadFavorites();
    expect(records, hasLength(1));
    expect(records.single.isFavorite, isTrue);
    expect(records.single.isFollowing, isFalse);
  });

  test('stopping follow can keep the independent favorite state', () async {
    final repository = LibraryRepository(
      preferences: await SharedPreferences.getInstance(),
    );
    final container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final controller = container.read(favoriteControllerProvider.notifier);
    await container.read(favoriteControllerProvider.future);

    await controller.follow(
      video.copyWith(category: '电视剧', episodes: _episodes(2)),
    );
    await controller.stopFollowing(video.globalId, keepFavorite: true);

    final record = container
        .read(favoriteControllerProvider)
        .requireValue
        .single;
    expect(record.isFavorite, isTrue);
    expect(record.isFollowing, isFalse);
  });

  test(
    'follow check only treats a larger episode count as an unread update',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repository = LibraryRepository(preferences: prefs);
      final videos = _ChangingVideoRepository();
      final source = VodSource(
        id: 'storm',
        name: '测试源',
        baseUri: Uri.parse('https://example.com/api'),
        adapterType: 'test',
      );
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repository),
          videoRepositoryProvider.overrideWithValue(videos),
          vodSourceRegistryProvider.overrideWith(
            (_) async => VodSourceRegistry([source], const {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(favoriteControllerProvider.notifier);
      await container.read(favoriteControllerProvider.future);
      await controller.follow(
        video.copyWith(category: '电视剧', remarks: '更新中', episodes: _episodes(2)),
      );
      expect(
        container
            .read(favoriteControllerProvider)
            .requireValue
            .single
            .isFavorite,
        isTrue,
      );
      videos.episodeNameSuffix = '（修正）';
      await controller.checkForUpdates(force: true);
      var record = container
          .read(favoriteControllerProvider)
          .requireValue
          .single;
      expect(record.unreadAddedCount, 0);

      videos.episodeNameSuffix = '';
      videos.episodeCount = 3;
      await controller.checkForUpdates(force: true);
      record = container.read(favoriteControllerProvider).requireValue.single;
      expect(videos.forceRefresh, isTrue);
      expect(record.unreadAddedCount, 1);
      expect(record.latestEpisodeLabel, '第3集');
      await controller.checkForUpdates(force: true);
      record = container.read(favoriteControllerProvider).requireValue.single;
      expect(record.unreadAddedCount, 1);
      await controller.markViewed(video.globalId);
      record = container.read(favoriteControllerProvider).requireValue.single;
      expect(record.hasUnreadUpdate, isFalse);

      videos.episodeCount = 2;
      await controller.checkForUpdates(force: true);
      record = container.read(favoriteControllerProvider).requireValue.single;
      expect(record.hasUnreadUpdate, isFalse);
      expect(record.acknowledgedEpisodeCount, 3);

      videos.episodeCount = 3;
      await controller.checkForUpdates(force: true);
      record = container.read(favoriteControllerProvider).requireValue.single;
      expect(record.hasUnreadUpdate, isFalse);
    },
  );
}

List<Episode> _episodes(int count) => List.generate(
  count,
  (index) => Episode(
    id: '${index + 1}',
    name: '第${index + 1}集',
    url: 'https://example.com/$index',
  ),
);

class _ChangingVideoRepository implements VideoRepository {
  int episodeCount = 2;
  String episodeNameSuffix = '';
  bool forceRefresh = false;

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async {
    this.forceRefresh = forceRefresh;
    return Video(
      id: ref.sourceVideoId,
      title: '影片',
      sourceId: source.id,
      category: '电视剧',
      remarks: '更新中',
      episodes: [
        for (final episode in _episodes(episodeCount))
          Episode(
            id: '${episode.id}$episodeNameSuffix',
            name: '${episode.name}$episodeNameSuffix',
            url: episode.url,
          ),
      ],
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => const VideoPage(items: [], page: 1, pageCount: 1);

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}
