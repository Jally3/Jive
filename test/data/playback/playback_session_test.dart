import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/playback/ad_filter.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/data/cache/content_key.dart';
import 'package:jive/data/playback/hls_parser.dart';
import 'package:jive/data/playback/local_proxy.dart';
import 'package:jive/data/playback/playback_session.dart';
import 'package:jive/domain/playback_selection.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:jive/domain/playback_status.dart';
import 'package:jive/domain/video.dart';

const _gb = 1 << 30;

class _FakeDiskSpace implements DiskSpaceProvider {
  @override
  Future<int> availableBytes() async => 20 * _gb;
  @override
  Future<int?> platformCacheLimitBytes() async => null;
  @override
  Future<int?> totalCapacityBytes() async => 64 * _gb;
}

final _segmentId = 'sha256:${'a' * 64}';

PlaybackSelection _selection() => PlaybackSelection(
  sourceId: 's',
  sourceVideoId: 'v',
  title: '影片',
  playbackLineIdentity: 'line',
  episodeIdentity: 'ep',
  episode: const Episode(
    id: '1',
    name: '第1集',
    url: 'https://cdn.example.com/a.m3u8',
    identity: 'ep',
  ),
  playbackSource: PlaybackSource(
    url: Uri.parse('https://cdn.example.com/a.m3u8'),
    format: PlaybackFormat.hls,
  ),
);

void main() {
  late Directory tempDir;
  late CacheIndexStore store;
  late CacheManager manager;
  late LocalProxyServer proxy;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jive_session_test');
    store = CacheIndexStore(tempDir);
    manager = CacheManager(store: store, diskSpace: _FakeDiskSpace());
    await manager.initialize();
    proxy = LocalProxyServer();
    await proxy.start();
  });

  tearDown(() async {
    await manager.flush();
    await proxy.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('full cache offline hit does not contact the network', () async {
    final selection = _selection();
    final contentKey = ContentKeyBuilder().build(
      ContentKeyParts(
        sourceId: selection.sourceId,
        sourceVideoId: selection.sourceVideoId,
        playbackLineIdentity: selection.playbackLineIdentity,
        episodeIdentity: selection.episodeIdentity,
      ),
    );
    final entry = await manager.upsertEntry(
      CacheEntry(
        contentKeyVersion: contentKey.version,
        contentKeyHash: contentKey.hash,
        revisionKeyHash: 'rk',
        manifestFingerprint: 'fp',
        manifestBaseUrl: 'https://cdn.example.com/a.m3u8',
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
    await manager.setExpectations(entry.key, 1);
    final lease = await manager.reserve(entry.key, 100);
    await lease?.commitResource(resourceId: _segmentId, size: 100, ext: 'ts');
    final resFile = store.resourceFile(contentKey.hash, 'rk', _segmentId, 'ts');
    await resFile.parent.create(recursive: true);
    await resFile.writeAsBytes(List.filled(100, 0));
    await store.saveProxyManifest(
      contentKey.hash,
      'rk',
      '#EXTM3U\n#EXTINF:4.0,\n/play/oldtoken/res/$_segmentId\n#EXT-X-ENDLIST\n',
    );

    // 任何网络请求都抛错：离线命中不应访问远端。
    final throwing = MockClient(
      (request) async => throw StateError('no network'),
    );
    final preparation = await PlaybackSession.prepare(
      selection: selection,
      proxy: proxy,
      parser: HlsParser(client: throwing),
      client: throwing,
      cacheManager: manager,
      store: store,
    );

    final session = preparation.session;
    expect(preparation.status.mode, PlaybackMode.cachePlayback);
    expect(session, isNotNull);
    expect(session!.route.fetcher, isNotNull);
    expect(session.proxyManifestUrl, contains(session.token));
    expect(
      session.route.proxyManifest,
      contains('/play/${session.token}/res/$_segmentId'),
    );

    // 离线会话关闭后释放缓存引用。
    await session.close(proxy);
  });

  test(
    'online prepare persists the proxy manifest for later offline use',
    () async {
      final selection = _selection();
      final client = MockClient((request) async {
        return http.Response(
          '#EXTM3U\n#EXTINF:4.0,\nhttps://cdn.example.com/seg0.ts\n#EXT-X-ENDLIST\n',
          200,
        );
      });
      final preparation = await PlaybackSession.prepare(
        selection: selection,
        proxy: proxy,
        parser: HlsParser(client: client),
        client: client,
        cacheManager: manager,
        store: store,
      );
      final session = preparation.session;
      expect(preparation.status.mode, PlaybackMode.streamingAndCaching);
      expect(session, isNotNull);
      await session!.close(proxy);
      await manager.flush();

      // 再次初始化后应能找到离线条目且代理 manifest 已落盘。
      final restored = CacheManager(store: store, diskSpace: _FakeDiskSpace());
      await restored.initialize();
      final contentKey = ContentKeyBuilder().build(
        ContentKeyParts(
          sourceId: selection.sourceId,
          sourceVideoId: selection.sourceVideoId,
          playbackLineIdentity: selection.playbackLineIdentity,
          episodeIdentity: selection.episodeIdentity,
        ),
      );
      final hit = await restored.findOffline(
        contentKey.hash,
        'https://cdn.example.com/a.m3u8',
      );
      // 未下载任何资源，不应离线可播（但条目存在）。
      expect(hit, isNull);
      expect(await restored.stats(), isNotNull);
    },
  );

  test(
    'online prepare with ad filter persists filtered manifest and timeline',
    () async {
      final selection = _selection();
      const media = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:4.0,
https://cdn.example.com/movie/0000.ts
#EXTINF:4.0,
https://cdn.example.com/movie/0001.ts
#EXT-X-DISCONTINUITY
#EXTINF:1.7,
https://cdn.example.com/ads/0001.ts
#EXTINF:1.7,
https://cdn.example.com/ads/0002.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.0,
https://cdn.example.com/movie/0002.ts
#EXTINF:4.0,
https://cdn.example.com/movie/0003.ts
#EXT-X-ENDLIST
''';
      final client = MockClient((request) async => http.Response(media, 200));
      final preparation = await PlaybackSession.prepare(
        selection: selection,
        proxy: proxy,
        parser: HlsParser(
          client: client,
          adFilter: const AdFilter(enabled: true),
        ),
        client: client,
        cacheManager: manager,
        store: store,
      );

      final session = preparation.session;
      expect(preparation.status.mode, PlaybackMode.streamingAndCaching);
      expect(session, isNotNull);
      final mapping = session!.timelineMapping;
      expect(mapping, isNotNull);
      expect(session.filterVersion, 1);
      expect(session.timelineVersion, adTimelineVersion);
      // 过滤后 4 个正片分片共 16000ms，移除 2 个广告分片共 3400ms。
      expect(session.originalDurationMs, 19400);
      expect(mapping!.removedMs, 3400);
      // 过滤轴 8100ms ↔ 原始轴 11500ms（广告块位于原始轴 8000~11400ms）。
      expect(
        mapping.filteredToSource(const Duration(milliseconds: 8100)),
        const Duration(milliseconds: 11500),
      );
      expect(
        mapping.sourceToFiltered(const Duration(milliseconds: 11500)),
        const Duration(milliseconds: 8100),
      );
      // 代理 manifest 为过滤版，不含广告分片地址。
      expect(session.route.proxyManifest, isNot(contains('ads/')));

      // 落盘：代理 manifest 为过滤版，源 manifest 保留广告，时间轴已保存。
      final fetcher = session.route.fetcher!;
      final ck = fetcher.contentKeyHash!;
      final rk = fetcher.revisionKeyHash!;
      final savedProxy = await store.loadProxyManifest(ck, rk);
      expect(savedProxy, isNot(contains('ads/')));
      final savedSource = await store.loadSourceManifest(ck, rk);
      expect(savedSource, contains('ads/0001.ts'));
      final timelineFile = File(
        '${store.entryDir(ck, rk).path}/$cacheTimelineFileName',
      );
      expect(await timelineFile.exists(), isTrue);

      await session.close(proxy);
    },
  );
}
