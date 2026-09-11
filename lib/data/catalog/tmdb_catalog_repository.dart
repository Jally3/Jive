import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/tmdb_catalog.dart';
import '../../domain/video_feed.dart';

class TmdbCatalogException implements Exception {
  const TmdbCatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class TmdbCatalogRepository {
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  });
}

/// Optional capability used to refresh a cached or bundled snapshot after it
/// has already rendered.
abstract interface class TmdbCatalogRevalidator {
  Future<TmdbCatalogSnapshot> revalidateFeed(
    VideoFeed feed, {
    bool ignoreFreshness = false,
  });
}

class AssetTmdbCatalogRepository implements TmdbCatalogRepository {
  AssetTmdbCatalogRepository({
    AssetBundle? bundle,
    this.manifestAsset = 'assets/tmdb/v1/manifest.json',
  }) : bundle = bundle ?? rootBundle;

  final AssetBundle bundle;
  final String manifestAsset;
  final Map<VideoFeed, TmdbCatalogSnapshot> _memory = {};

  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    if (!RemoteTmdbCatalogRepository.isCurated(feed)) {
      throw const TmdbCatalogException('该栏目不是 TMDB 榜单');
    }
    final cached = _memory[feed];
    if (!forceRefresh && cached != null) return cached;
    try {
      final manifest = _decodeAsset(await bundle.loadString(manifestAsset));
      if (_asInt(manifest['schemaVersion']) != 1) {
        throw const TmdbCatalogException('本地榜单索引版本不受支持');
      }
      final feeds = manifest['feeds'];
      final entry = feeds is Map
          ? feeds[RemoteTmdbCatalogRepository.feedKey(feed)]
          : null;
      final path = entry is Map ? '${entry['path'] ?? ''}'.trim() : '';
      if (path.isEmpty || path.startsWith('/') || path.contains('..')) {
        throw const TmdbCatalogException('本地榜单索引缺少合法路径');
      }
      final base = manifestAsset.substring(
        0,
        manifestAsset.lastIndexOf('/') + 1,
      );
      final snapshot = TmdbCatalogSnapshot.fromJson(
        _decodeAsset(await bundle.loadString('$base$path')),
      );
      if (snapshot.feed != feed ||
          ('${entry?['revision'] ?? ''}'.isNotEmpty &&
              snapshot.revision != '${entry?['revision']}')) {
        throw const TmdbCatalogException('本地榜单版本不一致');
      }
      _memory[feed] = snapshot;
      return snapshot;
    } on TmdbCatalogException {
      rethrow;
    } catch (error) {
      throw TmdbCatalogException('加载本地榜单失败：$error');
    }
  }

  Map<String, dynamic> _decodeAsset(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw const TmdbCatalogException('本地榜单 JSON 无效');
  }
}

class RemoteTmdbCatalogRepository
    implements TmdbCatalogRepository, TmdbCatalogRevalidator {
  RemoteTmdbCatalogRepository(
    this.client, {
    Uri? catalogUri,
    SharedPreferences? preferences,
    TmdbCatalogRepository? fallback,
    this.timeout = const Duration(seconds: 10),
    this.freshness = const Duration(minutes: 5),
  }) : catalogUri =
           catalogUri ??
           Uri.parse('https://hey-rickytse.com/api/tmdb/v1/catalog'),
       _preferences = preferences,
       _fallback = fallback;

  final http.Client client;
  final Uri catalogUri;
  final Duration timeout;
  final Duration freshness;
  final SharedPreferences? _preferences;
  final TmdbCatalogRepository? _fallback;
  final Map<VideoFeed, TmdbCatalogSnapshot> _memory = {};
  final Map<VideoFeed, Future<TmdbCatalogSnapshot>> _inflight = {};
  final Map<VideoFeed, DateTime> _validatedAt = {};
  final Map<VideoFeed, DateTime> _retryAfter = {};
  final Map<VideoFeed, int> _failureCounts = {};

  Future<SharedPreferences> get _prefs async =>
      _preferences ?? await SharedPreferences.getInstance();

  @override
  Future<TmdbCatalogSnapshot> fetchFeed(
    VideoFeed feed, {
    bool forceRefresh = false,
  }) async {
    _ensureCurated(feed);
    if (forceRefresh) {
      return revalidateFeed(feed, ignoreFreshness: true);
    }
    final available = await _availableSnapshot(feed);
    if (available != null) return available;
    return revalidateFeed(feed);
  }

  @override
  Future<TmdbCatalogSnapshot> revalidateFeed(
    VideoFeed feed, {
    bool ignoreFreshness = false,
  }) {
    _ensureCurated(feed);
    final running = _inflight[feed];
    if (running != null) return running;
    final future = _revalidate(feed, ignoreFreshness: ignoreFreshness);
    _inflight[feed] = future;
    return future.whenComplete(() => _inflight.remove(feed));
  }

  Future<TmdbCatalogSnapshot> _revalidate(
    VideoFeed feed, {
    required bool ignoreFreshness,
  }) async {
    final cached = await _availableSnapshot(feed);
    final now = DateTime.now();
    final validatedAt = await _readValidatedAt(feed);
    if (!ignoreFreshness &&
        cached != null &&
        validatedAt != null &&
        now.difference(validatedAt) < freshness) {
      return cached;
    }
    final retryAfter = await _readRetryAfter(feed);
    if (cached != null && retryAfter != null && now.isBefore(retryAfter)) {
      return cached;
    }

    final preferences = await _prefs;
    final etag = preferences.getString(_etagKey(feed));
    final headers = <String, String>{};
    if (etag != null && etag.isNotEmpty) headers['If-None-Match'] = etag;
    try {
      final uri = _feedUri(feed);
      if (uri.scheme != 'https' || uri.host.isEmpty) {
        throw const TmdbCatalogException('榜单地址必须使用 HTTPS');
      }
      final response = await client.get(uri, headers: headers).timeout(timeout);
      final requestId = response.headers['x-request-id'];
      if (response.statusCode == 304) {
        if (cached == null) {
          throw const TmdbCatalogException('榜单返回 304，但本地没有可用缓存');
        }
        await _markValidated(feed, now);
        await _clearBackoff(feed);
        return cached;
      }
      if (response.statusCode == 429) {
        await _setRateLimit(feed, response.headers['retry-after']);
        throw TmdbCatalogException(_statusMessage(429, requestId));
      }
      if (response.statusCode >= 500) {
        await _setFailureBackoff(feed);
        throw TmdbCatalogException(
          _statusMessage(response.statusCode, requestId),
        );
      }
      if (response.statusCode != 200) {
        throw TmdbCatalogException(
          _statusMessage(response.statusCode, requestId),
        );
      }
      final raw = utf8.decode(response.bodyBytes);
      final snapshot = TmdbCatalogSnapshot.fromJson(
        _decodeMap(response.bodyBytes),
      );
      if (snapshot.feed != feed) {
        throw const TmdbCatalogException('榜单响应与请求栏目不一致');
      }
      _memory[feed] = snapshot;
      await preferences.setString(_cacheKey(feed), raw);
      final responseEtag = response.headers['etag'];
      if (responseEtag == null || responseEtag.isEmpty) {
        await preferences.remove(_etagKey(feed));
      } else {
        await preferences.setString(_etagKey(feed), responseEtag);
      }
      await _markValidated(feed, now);
      await _clearBackoff(feed);
      return snapshot;
    } on TmdbCatalogException catch (_) {
      final fallback = await _availableSnapshot(feed);
      if (fallback != null) return fallback;
      rethrow;
    } catch (error) {
      await _setFailureBackoff(feed);
      final fallback = await _availableSnapshot(feed);
      if (fallback != null) return fallback;
      throw TmdbCatalogException('加载在线榜单失败：$error');
    }
  }

  Future<TmdbCatalogSnapshot?> _availableSnapshot(VideoFeed feed) async {
    final memoryCached = _memory[feed];
    if (memoryCached != null) return memoryCached;
    final persisted = await _loadCached(feed);
    if (persisted != null) {
      _memory[feed] = persisted;
      return persisted;
    }
    final fallback = _fallback;
    if (fallback == null) return null;
    try {
      final snapshot = await fallback.fetchFeed(feed);
      _memory[feed] = snapshot;
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<TmdbCatalogSnapshot?> _loadCached(VideoFeed feed) async {
    try {
      final raw = (await _prefs).getString(_cacheKey(feed));
      if (raw == null) return null;
      final snapshot = TmdbCatalogSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      return snapshot.feed == feed ? snapshot : null;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> _readValidatedAt(VideoFeed feed) async {
    final memoryValue = _validatedAt[feed];
    if (memoryValue != null) return memoryValue;
    final milliseconds = (await _prefs).getInt(_validatedKey(feed));
    if (milliseconds == null) return null;
    return _validatedAt[feed] = DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
    );
  }

  Future<DateTime?> _readRetryAfter(VideoFeed feed) async {
    final memoryValue = _retryAfter[feed];
    if (memoryValue != null) return memoryValue;
    final milliseconds = (await _prefs).getInt(_retryKey(feed));
    if (milliseconds == null) return null;
    return _retryAfter[feed] = DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
    );
  }

  Future<void> _markValidated(VideoFeed feed, DateTime value) async {
    _validatedAt[feed] = value;
    await (await _prefs).setInt(
      _validatedKey(feed),
      value.millisecondsSinceEpoch,
    );
  }

  Future<void> _setRateLimit(VideoFeed feed, String? header) async {
    final seconds = int.tryParse(header ?? '') ?? 60;
    await _setRetryAfter(feed, DateTime.now().add(Duration(seconds: seconds)));
  }

  Future<void> _setFailureBackoff(VideoFeed feed) async {
    final failures = (_failureCounts[feed] ?? 0) + 1;
    _failureCounts[feed] = failures;
    final delay = switch (failures) {
      1 => const Duration(seconds: 30),
      2 => const Duration(minutes: 2),
      _ => const Duration(minutes: 10),
    };
    await _setRetryAfter(feed, DateTime.now().add(delay));
  }

  Future<void> _setRetryAfter(VideoFeed feed, DateTime value) async {
    _retryAfter[feed] = value;
    await (await _prefs).setInt(_retryKey(feed), value.millisecondsSinceEpoch);
  }

  Future<void> _clearBackoff(VideoFeed feed) async {
    _failureCounts.remove(feed);
    _retryAfter.remove(feed);
    await (await _prefs).remove(_retryKey(feed));
  }

  Uri _feedUri(VideoFeed feed) => catalogUri.replace(
    queryParameters: {...catalogUri.queryParameters, 'feed': feedKey(feed)},
  );

  Map<String, dynamic> _decodeMap(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw const TmdbCatalogException('榜单 JSON 无效');
  }

  void _ensureCurated(VideoFeed feed) {
    if (!isCurated(feed)) {
      throw const TmdbCatalogException('该栏目不是 TMDB 榜单');
    }
  }

  static bool isCurated(VideoFeed feed) =>
      feed == VideoFeed.newReleases ||
      feed == VideoFeed.popular ||
      feed == VideoFeed.topRated;

  static String feedKey(VideoFeed feed) => switch (feed) {
    VideoFeed.newReleases => 'latest',
    VideoFeed.popular => 'popular',
    VideoFeed.topRated => 'top_rated',
    VideoFeed.updated => 'updated',
  };

  static String _cacheKey(VideoFeed feed) =>
      'tmdb_catalog_feed_cache_v1_${feedKey(feed)}';
  static String _etagKey(VideoFeed feed) =>
      'tmdb_catalog_feed_etag_v1_${feedKey(feed)}';
  static String _validatedKey(VideoFeed feed) =>
      'tmdb_catalog_feed_validated_v1_${feedKey(feed)}';
  static String _retryKey(VideoFeed feed) =>
      'tmdb_catalog_feed_retry_v1_${feedKey(feed)}';

  String _statusMessage(int statusCode, String? requestId) =>
      '榜单请求失败（$statusCode）${requestId == null ? '' : '，请求 ID：$requestId'}';
}

int _asInt(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

final tmdbCatalogRepositoryProvider = Provider<TmdbCatalogRepository>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return RemoteTmdbCatalogRepository(
    client,
    fallback: AssetTmdbCatalogRepository(),
  );
});
