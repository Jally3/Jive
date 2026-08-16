import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../domain/playback_selection.dart';
import '../../domain/playback_status.dart';
import 'ad_filter.dart';
import 'cache_index.dart';
import 'cache_io.dart';
import 'cache_manager.dart';
import 'content_key.dart';
import 'download_manager.dart';
import 'hls_parser.dart';
import 'local_proxy.dart';
import 'url_normalizer.dart';

enum PlaybackSessionStatus { preparing, ready, closing, closed, failed }

class PlaybackSessionPreparation {
  const PlaybackSessionPreparation({
    required this.session,
    required this.status,
  });

  final PlaybackSession? session;
  final PlaybackStatus status;
}

class PlaybackSession {
  PlaybackSession._({
    required this.selection,
    required this.sessionId,
    required this.token,
    required this.proxyManifestUrl,
    required this.route,
    this.playlist,
    this.cacheManager,
    this.cacheRef,
    this.timelineMapping,
    this.originalDurationMs = 0,
    this.filterVersion = 0,
    this.timelineVersion = 0,
    this.manifestFingerprint,
  }) : status = PlaybackSessionStatus.ready;

  final PlaybackSelection selection;
  final String sessionId;
  final String token;
  final String proxyManifestUrl;
  final ProxySessionRoute route;
  final HlsMediaPlaylist? playlist;
  final CacheManager? cacheManager;
  CacheRef? cacheRef;
  final TimelineMapping? timelineMapping;
  final int originalDurationMs;
  final int filterVersion;
  final int timelineVersion;
  final String? manifestFingerprint;
  PlaybackSessionStatus status;
  SegmentPrefetcher? _prefetcher;

  static final Random _random = Random.secure();

  static Future<PlaybackSessionPreparation> prepare({
    required PlaybackSelection selection,
    required LocalProxyServer proxy,
    required HlsParser parser,
    required http.Client client,
    CacheManager? cacheManager,
    CacheIndexStore? store,
    Duration timeout = const Duration(seconds: 15),
    void Function(PlaybackFallbackReason reason)? onCacheBypass,
  }) async {
    try {
      final cachedEnabled = cacheManager != null && store != null;
      final contentKey = cachedEnabled
          ? ContentKeyBuilder().build(
              ContentKeyParts(
                sourceId: selection.sourceId,
                sourceVideoId: selection.sourceVideoId,
                playbackLineIdentity: selection.playbackLineIdentity,
                episodeIdentity: selection.episodeIdentity,
              ),
            )
          : null;
      final manifestBaseUrl = urlNormalizer.normalizeToString(
        selection.playbackSource.url,
      );

      if (contentKey != null) {
        final cached = await cacheManager!.findOffline(
          contentKey.hash,
          manifestBaseUrl,
        );
        if (cached != null) {
          final offline = await _buildOfflineSession(
            selection: selection,
            proxy: proxy,
            client: client,
            cacheManager: cacheManager,
            store: store!,
            contentKey: contentKey,
            entry: cached,
            manifestBaseUrl: manifestBaseUrl,
            onCacheBypass: onCacheBypass,
          );
          if (offline != null) {
            return PlaybackSessionPreparation(
              session: offline,
              status: const PlaybackStatus(mode: PlaybackMode.cachePlayback),
            );
          }
        }
      }

      final decision = await parser
          .resolve(selection.playbackSource)
          .timeout(timeout);
      if (!decision.isCacheable || decision.mediaPlaylist == null) {
        return PlaybackSessionPreparation(
          session: null,
          status: PlaybackStatus(
            mode: PlaybackMode.direct,
            reason: _fallbackReasonForHls(decision.reason),
          ),
        );
      }
      final playlist = decision.mediaPlaylist!;
      final timelineMapping = playlist.timelineMapping;
      final filterVersion = timelineMapping == null ? 0 : 1;
      final timelineVersion = timelineMapping == null ? 0 : adTimelineVersion;
      final filteredDurationMs = _totalDurationMs(playlist);
      final originalDurationMs =
          filteredDurationMs + (timelineMapping?.removedMs ?? 0);
      final token = _token();
      final plan = parser.buildProxyPlan(playlist, token);

      String? entryKey;
      CacheRef? cacheRef;
      ResourceFetcher? fetcher;
      String? manifestFingerprint;
      if (contentKey != null) {
        final mgr = cacheManager!;
        final st = store!;
        manifestFingerprint = sha256
            .convert(utf8.encode(playlist.raw))
            .toString();
        final revisionKeyHash =
            'sha256:${sha256.convert(utf8.encode('${playlist.baseUri}|$manifestFingerprint')).toString()}';
        entryKey = '${contentKey.hash}|$revisionKeyHash';
        await mgr.upsertEntry(
          CacheEntry(
            contentKeyVersion: contentKey.version,
            contentKeyHash: contentKey.hash,
            revisionKeyHash: revisionKeyHash,
            manifestFingerprint: manifestFingerprint,
            manifestBaseUrl: manifestBaseUrl,
            filterVersion: filterVersion,
            timelineVersion: timelineVersion,
            sourceId: selection.sourceId,
            sourceVideoId: selection.sourceVideoId,
            title: selection.title,
            playbackLineIdentity: selection.playbackLineIdentity,
            playbackLineName: '',
            episodeIdentity: selection.episodeIdentity,
            episodeId: selection.episode.id,
            episodeName: selection.episode.name,
          ),
        );
        if (timelineMapping != null) {
          await _saveTimeline(
            st,
            contentKey.hash,
            revisionKeyHash,
            manifestFingerprint,
            timelineMapping,
          );
        }
        await st.saveProxyManifest(
          contentKey.hash,
          revisionKeyHash,
          plan.proxyManifest,
        );
        await st.saveSourceManifest(
          contentKey.hash,
          revisionKeyHash,
          decision.sourcePlaylist?.raw ?? playlist.raw,
        );
        await mgr.setExpectations(entryKey, plan.expectedResourceCount);
        cacheRef = await mgr.acquire(entryKey);
        fetcher = ResourceFetcher(
          client: client,
          sessionHeaders: selection.playbackSource.headers,
          manager: mgr,
          store: st,
          entryKey: entryKey,
          contentKeyHash: contentKey.hash,
          revisionKeyHash: revisionKeyHash,
          onCacheBypass: onCacheBypass,
        );
      }

      final route = ProxySessionRoute(
        token: token,
        proxyManifest: plan.proxyManifest,
        resources: plan.resources,
        extByResourceId: plan.extByResourceId,
        sessionHeaders: selection.playbackSource.headers,
        client: client,
        fetcher: fetcher,
      );
      proxy.register(route);
      final session = PlaybackSession._(
        selection: selection,
        sessionId: _token(),
        token: token,
        proxyManifestUrl: proxy.baseUrl(token),
        route: route,
        playlist: playlist,
        cacheManager: cacheManager,
        cacheRef: cacheRef,
        timelineMapping: timelineMapping,
        originalDurationMs: originalDurationMs,
        filterVersion: filterVersion,
        timelineVersion: timelineVersion,
        manifestFingerprint: manifestFingerprint,
      );
      return PlaybackSessionPreparation(
        session: session,
        status: cachedEnabled
            ? const PlaybackStatus(mode: PlaybackMode.streamingAndCaching)
            : const PlaybackStatus(
                mode: PlaybackMode.proxyWithoutCaching,
                reason: PlaybackFallbackReason.cacheUnavailable,
              ),
      );
    } catch (_) {
      return const PlaybackSessionPreparation(
        session: null,
        status: PlaybackStatus(
          mode: PlaybackMode.direct,
          reason: PlaybackFallbackReason.proxyPreparationFailed,
        ),
      );
    }
  }

  static Future<PlaybackSession?> _buildOfflineSession({
    required PlaybackSelection selection,
    required LocalProxyServer proxy,
    required http.Client client,
    required CacheManager cacheManager,
    required CacheIndexStore store,
    required ContentKey contentKey,
    required CacheEntry entry,
    required String manifestBaseUrl,
    void Function(PlaybackFallbackReason reason)? onCacheBypass,
  }) async {
    final raw = await store.loadProxyManifest(
      entry.contentKeyHash,
      entry.revisionKeyHash,
    );
    if (raw == null || raw.isEmpty) return null;
    final token = _token();
    final proxyManifest = _replaceToken(raw, token);
    final catalog = await cacheManager.resourceCatalog(entry.key);
    if (catalog.isEmpty) return null;
    final resources = <String, Uri>{};
    final extByResourceId = <String, String>{};
    catalog.forEach((id, record) {
      resources[id] = Uri.parse('offline:$id');
      extByResourceId[id] = record.ext;
    });
    TimelineMapping? mapping;
    if (entry.filterVersion > 0) {
      mapping = await _loadTimelineMapping(
        store,
        entry.contentKeyHash,
        entry.revisionKeyHash,
      );
    }
    final filteredMs = _extinfDurationMs(proxyManifest);
    final originalMs = filteredMs + (mapping?.removedMs ?? 0);
    final cacheRef = await cacheManager.acquire(entry.key);
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: selection.playbackSource.headers,
      manager: cacheManager,
      store: store,
      entryKey: entry.key,
      contentKeyHash: entry.contentKeyHash,
      revisionKeyHash: entry.revisionKeyHash,
      onCacheBypass: onCacheBypass,
    );
    final route = ProxySessionRoute(
      token: token,
      proxyManifest: proxyManifest,
      resources: resources,
      extByResourceId: extByResourceId,
      sessionHeaders: selection.playbackSource.headers,
      client: client,
      fetcher: fetcher,
    );
    proxy.register(route);
    return PlaybackSession._(
      selection: selection,
      sessionId: _token(),
      token: token,
      proxyManifestUrl: proxy.baseUrl(token),
      route: route,
      cacheManager: cacheManager,
      cacheRef: cacheRef,
      timelineMapping: mapping,
      originalDurationMs: originalMs,
      filterVersion: entry.filterVersion,
      timelineVersion: entry.timelineVersion,
      manifestFingerprint: entry.manifestFingerprint,
    );
  }

  SegmentPrefetcher? get prefetcher => _prefetcher;

  SegmentPrefetcher? buildPrefetcher() {
    final existing = _prefetcher;
    if (existing != null) return existing;
    final fetcher = route.fetcher;
    final segments = playlist?.segments;
    if (fetcher == null || segments == null || segments.isEmpty) return null;
    final created = SegmentPrefetcher(fetcher: fetcher, segments: segments);
    _prefetcher = created;
    return created;
  }

  Future<void> close(LocalProxyServer proxy) async {
    if (status == PlaybackSessionStatus.closed ||
        status == PlaybackSessionStatus.closing) {
      return;
    }
    status = PlaybackSessionStatus.closing;
    _prefetcher?.cancel();
    route.closing = true;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (route.activeReads > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    proxy.unregister(token);
    final ref = cacheRef;
    cacheRef = null;
    if (ref != null) await ref.dispose();
    await cacheManager?.flush();
    status = PlaybackSessionStatus.closed;
  }

  static String _replaceToken(String raw, String newToken) =>
      raw.replaceAllMapped(
        RegExp(r'/play/[^/]+/res/'),
        (_) => '/play/$newToken/res/',
      );

  static Future<TimelineMapping?> _loadTimelineMapping(
    CacheIndexStore store,
    String contentKeyHash,
    String revisionKeyHash,
  ) async {
    final file = File(
      '${store.entryDir(contentKeyHash, revisionKeyHash).path}/$cacheTimelineFileName',
    );
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['removedRanges'] is! List) return null;
      final ranges = <RemovedRange>[];
      for (final item in (decoded['removedRanges'] as List)) {
        if (item is! Map) continue;
        final start = item['startMs'];
        final end = item['endMs'];
        if (start is int && end is int) {
          ranges.add(RemovedRange(start, end));
        }
      }
      return ranges.isEmpty ? null : TimelineMapping(ranges);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveTimeline(
    CacheIndexStore store,
    String contentKeyHash,
    String revisionKeyHash,
    String manifestFingerprint,
    TimelineMapping mapping,
  ) async {
    final file = File(
      '${store.entryDir(contentKeyHash, revisionKeyHash).path}/$cacheTimelineFileName',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'manifestFingerprint': manifestFingerprint,
        'filterVersion': adFilterVersion,
        'timelineVersion': adTimelineVersion,
        'removedRanges': [
          for (final range in mapping.ranges)
            {'startMs': range.startMs, 'endMs': range.endMs},
        ],
      }),
      flush: true,
    );
  }

  static int _totalDurationMs(HlsMediaPlaylist playlist) {
    var total = 0;
    for (final segment in playlist.segments) {
      final duration = segment.duration;
      if (duration != null) total += (duration * 1000).round();
    }
    return total;
  }

  static int _extinfDurationMs(String raw) {
    var total = 0;
    for (final match in RegExp(r'#EXTINF:\s*([\d.]+)').allMatches(raw)) {
      final value = double.tryParse(match.group(1) ?? '');
      if (value != null && value > 0) total += (value * 1000).round();
    }
    return total;
  }

  static PlaybackFallbackReason _fallbackReasonForHls(String? reason) {
    final text = reason ?? '';
    if (text.contains('直播')) return PlaybackFallbackReason.liveStream;
    if (text.contains('加密') || text.contains('DRM')) {
      return PlaybackFallbackReason.encryptedStream;
    }
    if (text.contains('HTTP')) return PlaybackFallbackReason.manifestHttpError;
    if (text.contains('请求失败') || text.contains('manifest')) {
      return PlaybackFallbackReason.manifestRequestFailed;
    }
    if (text.contains('标签') || text.contains('变体')) {
      return PlaybackFallbackReason.unsupportedHls;
    }
    return PlaybackFallbackReason.unsupportedHls;
  }

  static String _token() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
