import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/tmdb_catalog.dart';

void main() {
  test('snapshot parses groups, drops unknown ids and assigns group rank', () {
    final snapshot = TmdbCatalogSnapshot.fromJson({
      'schemaVersion': 1,
      'feed': 'popular',
      'revision': 'r1',
      'generatedAt': '2026-09-10T13:44:10.853Z',
      'expiresAt': '2026-09-14T13:44:10.853Z',
      'stale': true,
      'groups': {
        'all': ['tmdb:movie:1', 'missing', 'tmdb:tv:2'],
        'movie': ['tmdb:movie:1'],
      },
      'items': {
        'tmdb:movie:1': {
          'tmdbId': 1,
          'mediaType': 'movie',
          'category': 'movie',
          'localizedTitle': '电影',
          'originalTitle': 'Movie',
          'posterPath': '/poster.jpg',
          'rating': 8.2,
        },
        'tmdb:tv:2': {
          'tmdbId': 2,
          'mediaType': 'tv',
          'category': 'tv',
          'localizedTitle': '剧集',
          'originalTitle': 'Show',
        },
      },
    });

    final items = snapshot.itemsFor(TmdbCatalogScope.all);
    expect(items.map((item) => item.tmdbId), [1, 2]);
    expect(items.map((item) => item.rank), [1, 2]);
    expect(items.first.posterUrl, 'https://image.tmdb.org/t/p/w500/poster.jpg');
    expect(snapshot.generatedAt, isNotNull);
    expect(snapshot.expiresAt, isNotNull);
    expect(snapshot.stale, isTrue);
    expect(snapshot.supportedScopes, {
      TmdbCatalogScope.all,
      TmdbCatalogScope.movie,
    });
    expect(
      snapshot.supportedScopes.contains(TmdbCatalogScope.animation),
      isFalse,
    );
  });

  test('an explicitly empty group is still a supported scope', () {
    final snapshot = TmdbCatalogSnapshot.fromJson({
      'schemaVersion': 1,
      'feed': 'top_rated',
      'revision': 'r1',
      'groups': {
        'all': ['tmdb:movie:1'],
        'animation': <String>[],
      },
      'items': {
        'tmdb:movie:1': {
          'tmdbId': 1,
          'mediaType': 'movie',
          'localizedTitle': '电影',
        },
      },
    });

    expect(
      snapshot.supportedScopes.contains(TmdbCatalogScope.animation),
      isTrue,
    );
    expect(snapshot.itemsFor(TmdbCatalogScope.animation), isEmpty);
  });

  test('rejects an unsupported schema version', () {
    expect(
      () => TmdbCatalogSnapshot.fromJson({
        'schemaVersion': 2,
        'feed': 'popular',
        'groups': <String, Object?>{},
        'items': <String, Object?>{},
      }),
      throwsFormatException,
    );
  });
}
