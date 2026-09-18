import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../domain/playback_selection.dart';
import '../../domain/playback_status.dart';
import './ad_filter.dart';
import '../cache/cache_index.dart';
import '../cache/cache_io.dart';
import '../cache/cache_manager.dart';
import '../cache/content_key.dart';
import '../download/download_manager.dart';
import './hls_parser.dart';
import './local_proxy.dart';
import '../cache/url_normalizer.dart';

/// 播放会话从准备到释放的生命周期状态。
enum PlaybackSessionStatus { preparing, ready, closing, closed, failed }

/// 会话准备结果：可能成功得到代理会话，也可能携带直连回退状态。
class PlaybackSessionPreparation {
  /// [session] 为 null 表示应根据 [status] 走直连或显示失败原因。
  const PlaybackSessionPreparation({
    required this.session,
    required this.status,
  });

  final PlaybackSession? session;
  final PlaybackStatus status;
}

/// 一次播放选择对应的本地代理、缓存引用、清单和时间轴生命周期。
class PlaybackSession {
  /// 私有构造器只接收已完成准备的资源；新会话统一通过 [prepare] 创建。
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
    this.adFilterReport,
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
  final AdFilterReport? adFilterReport;
  final int originalDurationMs;
  final int filterVersion;
  final int timelineVersion;
  final String? manifestFingerprint;
  PlaybackSessionStatus status;
  SegmentPrefetcher? _prefetcher;

  static final Random _random = Random.secure();

  /// 为 [selection] 准备可播放会话。
  ///
  /// [proxy]/[parser]/[client] 分别负责本地服务、HLS 解析和远端请求；
  /// [cacheManager] 与 [store] 必须同时提供才启用缓存；[offlineOnly] 为 true
  /// 时只尝试完整离线缓存；[timeout] 限制清单解析耗时；[onCacheBypass]
  /// 用于上报因缓存异常而改走网络的原因。
  ///
  /// 执行顺序为：完整离线缓存 -> 离线模式回退 -> 在线 HLS 解析 ->
  /// 建立代理与可选缓存。任何未预期错误都安全回退直连。
  static Future<PlaybackSessionPreparation> prepare({
    required PlaybackSelection selection,
    required LocalProxyServer proxy,
    required HlsParser parser,
    required http.Client client,
    CacheManager? cacheManager,
    CacheIndexStore? store,
    bool offlineOnly = false,
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

      if (offlineOnly) {
        return const PlaybackSessionPreparation(
          session: null,
          status: PlaybackStatus(
            mode: PlaybackMode.direct,
            reason: PlaybackFallbackReason.cacheUnavailable,
          ),
        );
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
        final revisionKeyHash = hlsRevisionKeyHash(
          playlist.baseUri,
          manifestFingerprint,
        );
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
          encryptedSegments: playlist.hasEncryption,
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
        adFilterReport: playlist.adFilterReport,
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

  /// 从已完成的缓存条目构建不访问媒体源站的代理会话。
  ///
  /// [entry] 提供 manifest revision 与过滤版本；若代理清单或资源目录缺失，
  /// 返回 null，让调用方继续尝试在线播放。
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
    if (catalog.isEmpty) {
      return null;
    }
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

  /// 延迟创建分片预取器并在会话内复用。
  ///
  /// [windowSize] 返回从当前播放点向前预取的目标时长，可随网络动态变化。
  /// 无缓存 fetcher、无在线清单或无分片时返回 null。
  SegmentPrefetcher? buildPrefetcher({Duration Function()? windowSize}) {
    final existing = _prefetcher;
    if (existing != null) return existing;
    final fetcher = route.fetcher;
    final segments = playlist?.segments;
    if (fetcher == null || segments == null || segments.isEmpty) return null;
    final created = SegmentPrefetcher(
      fetcher: fetcher,
      segments: segments,
      windowSize: windowSize,
    );
    _prefetcher = created;
    return created;
  }

  /// 平稳关闭会话：停止预取、等待在途读取、注销路由并释放缓存引用。
  ///
  /// 最多等待在途请求 2 秒，重复关闭是幂等的。
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

  /// 用新会话 [newToken] 替换持久化代理清单中的旧 token。
  static String _replaceToken(String raw, String newToken) =>
      raw.replaceAllMapped(
        RegExp(r'/play/[^/]+/res/'),
        (_) => '/play/$newToken/res/',
      );

  /// 从缓存目录加载被删除广告时间段；缺失、损坏或空数据均返回 null。
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

  /// 将 [mapping] 与清单指纹、规则版本一起保存，供离线会话恢复时间轴。
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

  /// 汇总结构化清单全部分片时长，返回毫秒。
  static int _totalDurationMs(HlsMediaPlaylist playlist) {
    var total = 0;
    for (final segment in playlist.segments) {
      final duration = segment.duration;
      if (duration != null) total += (duration * 1000).round();
    }
    return total;
  }

  /// 直接从 manifest 文本汇总 EXTINF 时长，供离线清单使用。
  static int _extinfDurationMs(String raw) {
    var total = 0;
    for (final match in RegExp(r'#EXTINF:\s*([\d.]+)').allMatches(raw)) {
      final value = double.tryParse(match.group(1) ?? '');
      if (value != null && value > 0) total += (value * 1000).round();
    }
    return total;
  }

  /// 将 HLS 解析器的文本原因映射为稳定的播放器回退枚举。
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

  /// 生成 128 位随机十六进制 token，用于隔离代理会话和 URL 路由。
  static String _token() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
