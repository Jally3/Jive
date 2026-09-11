import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/catalog/tmdb_catalog_repository.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/domain/video_feed.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('bundled production snapshots are complete and loadable', () async {
    final repository = AssetTmdbCatalogRepository();

    for (final feed in const [
      VideoFeed.newReleases,
      VideoFeed.popular,
      VideoFeed.topRated,
    ]) {
      final snapshot = await repository.fetchFeed(feed);
      expect(snapshot.itemsFor(TmdbCatalogScope.all), hasLength(200));
      expect(snapshot.itemsFor(TmdbCatalogScope.movie), isNotEmpty);
      expect(snapshot.itemsFor(TmdbCatalogScope.tv), isNotEmpty);
      expect(snapshot.itemsFor(TmdbCatalogScope.animation), isNotEmpty);
      expect(snapshot.itemsFor(TmdbCatalogScope.variety), isNotEmpty);
    }
  });

  test(
    'loads a feed directly from the catalog API and caches its ETag',
    () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode(_feedJson)),
          200,
          headers: {'etag': 'W/"r1-popular"'},
        );
      });
      final preferences = await SharedPreferences.getInstance();
      final repository = RemoteTmdbCatalogRepository(
        client,
        catalogUri: Uri.parse('https://example.com/api/tmdb/v1/catalog'),
        preferences: preferences,
      );

      final result = await repository.fetchFeed(VideoFeed.popular);

      expect(result.revision, 'r1');
      expect(result.itemsFor(TmdbCatalogScope.all).single.localizedTitle, '影片');
      expect(captured.url.path, '/api/tmdb/v1/catalog');
      expect(captured.url.queryParameters['feed'], 'popular');
      expect(
        preferences.getString('tmdb_catalog_feed_etag_v1_popular'),
        'W/"r1-popular"',
      );
    },
  );

  test('uses last complete cached feed when forced refresh fails', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'tmdb_catalog_feed_cache_v1_popular',
      jsonEncode(_feedJson),
    );
    final repository = RemoteTmdbCatalogRepository(
      MockClient((_) async => http.Response('down', 503)),
      catalogUri: Uri.parse('https://example.com/api/tmdb/v1/catalog'),
      preferences: preferences,
    );

    final result = await repository.fetchFeed(
      VideoFeed.popular,
      forceRefresh: true,
    );

    expect(result.revision, 'r1');
  });

  test('sends the stored ETag and reuses the cached body on 304', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'tmdb_catalog_feed_cache_v1_popular',
      jsonEncode(_feedJson),
    );
    await preferences.setString(
      'tmdb_catalog_feed_etag_v1_popular',
      'W/"r1-popular"',
    );
    late http.Request captured;
    final repository = RemoteTmdbCatalogRepository(
      MockClient((request) async {
        captured = request;
        return http.Response('', 304);
      }),
      catalogUri: Uri.parse('https://example.com/api/tmdb/v1/catalog'),
      preferences: preferences,
    );

    final result = await repository.fetchFeed(
      VideoFeed.popular,
      forceRefresh: true,
    );

    expect(captured.headers['If-None-Match'], 'W/"r1-popular"');
    expect(result.revision, 'r1');
    expect(
      preferences.getInt('tmdb_catalog_feed_validated_v1_popular'),
      isNotNull,
    );
  });

  test('coalesces concurrent refreshes for the same feed', () async {
    final gate = Completer<void>();
    var calls = 0;
    final repository = RemoteTmdbCatalogRepository(
      MockClient((_) async {
        calls++;
        await gate.future;
        return http.Response.bytes(utf8.encode(jsonEncode(_feedJson)), 200);
      }),
      catalogUri: Uri.parse('https://example.com/api/tmdb/v1/catalog'),
      preferences: await SharedPreferences.getInstance(),
    );

    final first = repository.revalidateFeed(VideoFeed.popular);
    final second = repository.revalidateFeed(VideoFeed.popular);
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(calls, 1);
    expect(results.map((item) => item.revision), everyElement('r1'));
  });

  test('honors Retry-After while a cached feed remains available', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'tmdb_catalog_feed_cache_v1_popular',
      jsonEncode(_feedJson),
    );
    var calls = 0;
    final repository = RemoteTmdbCatalogRepository(
      MockClient((_) async {
        calls++;
        return http.Response('limited', 429, headers: {'retry-after': '60'});
      }),
      catalogUri: Uri.parse('https://example.com/api/tmdb/v1/catalog'),
      preferences: preferences,
    );

    await repository.fetchFeed(VideoFeed.popular, forceRefresh: true);
    await repository.fetchFeed(VideoFeed.popular, forceRefresh: true);

    expect(calls, 1);
    expect(
      preferences.getInt('tmdb_catalog_feed_retry_v1_popular'),
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
  });

  test('loads the selected feed from bundled manifest assets', () async {
    final bundle = _FakeAssetBundle({
      'assets/tmdb/v1/manifest.json': jsonEncode({
        'schemaVersion': 1,
        'feeds': {
          'popular': {'revision': 'r1', 'path': 'revisions/r1/popular.json'},
        },
      }),
      'assets/tmdb/v1/revisions/r1/popular.json': jsonEncode(_feedJson),
    });
    final repository = AssetTmdbCatalogRepository(bundle: bundle);

    final result = await repository.fetchFeed(VideoFeed.popular);

    expect(result.revision, 'r1');
    expect(bundle.loaded, [
      'assets/tmdb/v1/manifest.json',
      'assets/tmdb/v1/revisions/r1/popular.json',
    ]);
  });
}

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this.assets);
  final Map<String, String> assets;
  final List<String> loaded = [];

  @override
  Future<ByteData> load(String key) async {
    loaded.add(key);
    final bytes = utf8.encode(assets[key]!);
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

final _feedJson = {
  'schemaVersion': 1,
  'revision': 'r1',
  'feed': 'popular',
  'groups': {
    'all': ['tmdb:movie:1'],
  },
  'items': {
    'tmdb:movie:1': {
      'tmdbId': 1,
      'mediaType': 'movie',
      'category': 'movie',
      'localizedTitle': '影片',
      'originalTitle': 'Movie',
    },
  },
};
