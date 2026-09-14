import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/library.dart';
import '../../domain/recommendation.dart';
import '../../domain/video.dart';
import '../../domain/watch_record.dart';
import '../network/json_http_client.dart';
import 'anonymous_subject_store.dart';
import 'backend_recommendation_client.dart';
import 'backend_recommendation_config.dart';
import 'recommendation_client.dart';
import 'recommendation_request.dart';

class RecommendationRepository {
  RecommendationRepository({
    required this.client,
    SharedPreferences? preferences,
    this.freshDuration = const Duration(minutes: 30),
    this.staleDuration = const Duration(hours: 24),
    this.playableCacheDuration = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _preferences = preferences,
       _now = now ?? DateTime.now;

  static const _cacheKey = 'backend_recommendation_cache_v1';
  static const _profileKey = 'backend_recommendation_profile_v1';
  static const _playableCacheKey = 'recommendation_playable_cache_v1';
  static const _maximumPlayableCacheEntries = 6;

  final RecommendationClient client;
  final SharedPreferences? _preferences;
  final Duration freshDuration;
  final Duration staleDuration;
  final Duration playableCacheDuration;
  final DateTime Function() _now;

  Future<RecommendationBatch> fetch({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
    bool forceRefresh = false,
  }) async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final fingerprint = recommendationProfileFingerprint(history, library);
    final cached = _readCache(prefs);
    final sameProfile = prefs.getString(_profileKey) == fingerprint;
    if (!forceRefresh && sameProfile && _isFresh(cached, freshDuration)) {
      return cached!.asCached();
    }
    try {
      final batch = await client.recommend(history: history, library: library);
      await prefs.setString(_cacheKey, jsonEncode(batch.toJson()));
      await prefs.setString(_profileKey, fingerprint);
      return batch;
    } catch (_) {
      if (sameProfile && _isFresh(cached, staleDuration)) {
        return cached!.asCached();
      }
      rethrow;
    }
  }

  Stream<RecommendationStreamEvent> fetchStream({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
    bool forceRefresh = false,
  }) async* {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final fingerprint = recommendationProfileFingerprint(history, library);
    final cached = _readCache(prefs);
    final sameProfile = prefs.getString(_profileKey) == fingerprint;
    if (!forceRefresh && sameProfile && _isFresh(cached, freshDuration)) {
      yield RecommendationStreamDone(cached!.asCached());
      return;
    }
    final current = client;
    if (current is! StreamingRecommendationClient) {
      yield RecommendationStreamDone(
        await fetch(
          history: history,
          library: library,
          forceRefresh: forceRefresh,
        ),
      );
      return;
    }
    final streamingClient = current as StreamingRecommendationClient;
    final request = streamingClient.recommendStream(
      history: history,
      library: library,
    );
    try {
      await for (final event in request.events) {
        if (event case RecommendationStreamDone(:final result)) {
          await prefs.setString(_cacheKey, jsonEncode(result.toJson()));
          await prefs.setString(_profileKey, fingerprint);
        }
        yield event;
      }
    } catch (_) {
      if (sameProfile && _isFresh(cached, staleDuration)) {
        yield const RecommendationStreamReset();
        yield RecommendationStreamDone(cached!.asCached());
        return;
      }
      rethrow;
    } finally {
      await request.cancel();
    }
  }

  Future<RecommendationBatch> fetchNext(String cursor) {
    final current = client;
    if (current is! PaginatedRecommendationClient) {
      throw UnsupportedError('当前推荐客户端不支持分页');
    }
    return current.nextPage(cursor);
  }

  Stream<RecommendationStreamEvent> fetchNextStream(String cursor) async* {
    final current = client;
    if (current is! StreamingRecommendationClient) {
      yield RecommendationStreamDone(await fetchNext(cursor));
      return;
    }
    final streamingClient = current as StreamingRecommendationClient;
    final request = streamingClient.nextPageStream(cursor);
    try {
      yield* request.events;
    } finally {
      await request.cancel();
    }
  }

  Future<void> reportEvent(RecommendationEvent event) {
    final current = client;
    if (current is! PaginatedRecommendationClient) return Future.value();
    return current.reportEvent(event);
  }

  Future<List<Video>?> readPlayableCache({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
    required String sourceFingerprint,
  }) async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final profileFingerprint = recommendationProfileFingerprint(
      history,
      library,
    );
    final now = _now();
    for (final entry in _readPlayableEntries(prefs)) {
      if (entry.profileFingerprint == profileFingerprint &&
          entry.sourceFingerprint == sourceFingerprint &&
          now.difference(entry.cachedAt).abs() < playableCacheDuration &&
          entry.videos.isNotEmpty) {
        return List.unmodifiable(entry.videos);
      }
    }
    return null;
  }

  Future<void> writePlayableCache({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
    required String sourceFingerprint,
    required List<Video> videos,
  }) async {
    if (videos.isEmpty) return;
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final profileFingerprint = recommendationProfileFingerprint(
      history,
      library,
    );
    final now = _now();
    final entries = _readPlayableEntries(prefs)
        .where(
          (entry) =>
              now.difference(entry.cachedAt).abs() < playableCacheDuration &&
              (entry.profileFingerprint != profileFingerprint ||
                  entry.sourceFingerprint != sourceFingerprint),
        )
        .toList();
    entries.add(
      _PlayableRecommendationCacheEntry(
        profileFingerprint: profileFingerprint,
        sourceFingerprint: sourceFingerprint,
        cachedAt: now,
        videos: List.unmodifiable(videos),
      ),
    );
    entries.sort((a, b) => b.cachedAt.compareTo(a.cachedAt));
    await prefs.setString(
      _playableCacheKey,
      jsonEncode(
        entries
            .take(_maximumPlayableCacheEntries)
            .map((entry) => entry.toJson())
            .toList(),
      ),
    );
  }

  RecommendationBatch? _readCache(SharedPreferences prefs) {
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return RecommendationBatch.tryFromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  List<_PlayableRecommendationCacheEntry> _readPlayableEntries(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(_playableCacheKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(_PlayableRecommendationCacheEntry.tryFromJson)
          .whereType<_PlayableRecommendationCacheEntry>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  bool _isFresh(RecommendationBatch? batch, Duration duration) =>
      batch != null && _now().difference(batch.servedAt).abs() < duration;
}

class _PlayableRecommendationCacheEntry {
  const _PlayableRecommendationCacheEntry({
    required this.profileFingerprint,
    required this.sourceFingerprint,
    required this.cachedAt,
    required this.videos,
  });

  final String profileFingerprint;
  final String sourceFingerprint;
  final DateTime cachedAt;
  final List<Video> videos;

  static _PlayableRecommendationCacheEntry? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final profileFingerprint = '${json['profileFingerprint'] ?? ''}';
    final sourceFingerprint = '${json['sourceFingerprint'] ?? ''}';
    final cachedAt = DateTime.tryParse('${json['cachedAt'] ?? ''}');
    final rawVideos = json['videos'];
    if (profileFingerprint.isEmpty ||
        sourceFingerprint.isEmpty ||
        cachedAt == null ||
        rawVideos is! List) {
      return null;
    }
    final videos = rawVideos
        .whereType<Map>()
        .map((item) => Video.fromJson(Map<String, dynamic>.from(item)))
        .where((video) => video.id.isNotEmpty && video.title.trim().isNotEmpty)
        .toList(growable: false);
    if (videos.isEmpty) return null;
    return _PlayableRecommendationCacheEntry(
      profileFingerprint: profileFingerprint,
      sourceFingerprint: sourceFingerprint,
      cachedAt: cachedAt,
      videos: videos,
    );
  }

  Map<String, dynamic> toJson() => {
    'profileFingerprint': profileFingerprint,
    'sourceFingerprint': sourceFingerprint,
    'cachedAt': cachedAt.toIso8601String(),
    'videos': videos.map((video) => video.toJson()).toList(),
  };
}

String recommendationProfileFingerprint(
  List<WatchRecord> history,
  List<FavoriteRecord> library,
) => sha256
    .convert(
      utf8.encode(
        jsonEncode(recommendationPreferencePayload(history, library)),
      ),
    )
    .toString();

final backendRecommendationConfigProvider =
    Provider<BackendRecommendationConfig>(
      (_) => BackendRecommendationConfig.fromEnvironment(),
    );

final recommendationClientProvider = Provider<RecommendationClient>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  final config = ref.watch(backendRecommendationConfigProvider);
  return BackendRecommendationClient(
    httpClient: JsonHttpClient(
      client: client,
      baseUri: config.baseUri,
      timeout: config.timeout,
    ),
    subjectStore: AnonymousSubjectStore(),
  );
});

final recommendationRepositoryProvider = Provider<RecommendationRepository>(
  (ref) =>
      RecommendationRepository(client: ref.watch(recommendationClientProvider)),
);
