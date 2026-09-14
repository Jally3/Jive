import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/recommendation/ark_recommendation_client.dart';
import 'package:jive/data/recommendation/recommendation_repository.dart';
import 'package:jive/domain/library.dart';
import 'package:jive/domain/recommendation.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reuses a fresh response for the same preference profile', () async {
    final client = _FakeRecommendationClient();
    final repository = RecommendationRepository(
      client: client,
      preferences: await SharedPreferences.getInstance(),
    );

    final first = await repository.fetch(history: const [], library: const []);
    final second = await repository.fetch(history: const [], library: const []);

    expect(client.calls, 1);
    expect(first.fromCache, isFalse);
    expect(second.fromCache, isTrue);
    expect(second.items.single.title, '测试影片');
  });

  test('force refresh bypasses the fresh cache', () async {
    final client = _FakeRecommendationClient();
    final repository = RecommendationRepository(
      client: client,
      preferences: await SharedPreferences.getInstance(),
    );

    await repository.fetch(history: const [], library: const []);
    await repository.fetch(
      history: const [],
      library: const [],
      forceRefresh: true,
    );

    expect(client.calls, 2);
  });

  test(
    'playable cache is isolated by VOD source and expires after 30 minutes',
    () async {
      var now = DateTime(2026, 9, 14, 12);
      final repository = RecommendationRepository(
        client: _FakeRecommendationClient(),
        preferences: await SharedPreferences.getInstance(),
        now: () => now,
      );
      const videos = [Video(id: '1', sourceId: 'source-a', title: '测试影片')];

      await repository.writePlayableCache(
        history: const [],
        library: const [],
        sourceFingerprint: 'source-a-fingerprint',
        videos: videos,
      );

      expect(
        await repository.readPlayableCache(
          history: const [],
          library: const [],
          sourceFingerprint: 'source-a-fingerprint',
        ),
        hasLength(1),
      );
      expect(
        await repository.readPlayableCache(
          history: const [],
          library: const [],
          sourceFingerprint: 'source-b-fingerprint',
        ),
        isNull,
      );

      now = now.add(const Duration(minutes: 30));
      expect(
        await repository.readPlayableCache(
          history: const [],
          library: const [],
          sourceFingerprint: 'source-a-fingerprint',
        ),
        isNull,
      );
    },
  );
}

class _FakeRecommendationClient implements RecommendationClient {
  int calls = 0;

  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) async {
    calls++;
    return RecommendationBatch(
      items: const [
        RecommendationCandidate(title: '测试影片', mediaType: TmdbMediaType.movie),
      ],
      generatedAt: DateTime.now(),
    );
  }
}
