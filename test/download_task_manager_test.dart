import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/data/cache/download_task_manager.dart';
import 'package:jive/data/cache/hls_parser.dart';
import 'package:jive/data/cache/local_proxy.dart';
import 'package:jive/data/cache/playback_session.dart';
import 'package:jive/domain/playback_selection.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:jive/domain/video.dart';

const _manifest = '''
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

const _aesManifest = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-KEY:METHOD=AES-128,URI="enc.key",IV=0x00000000000000000000000000000000
#EXTINF:4.0,
segment.ts
#EXT-X-ENDLIST
''';

class _FakeDiskSpace implements DiskSpaceProvider {
  @override
  Future<int> availableBytes() async => 20 * (1 << 30);
  @override
  Future<int?> platformCacheLimitBytes() async => null;
  @override
  Future<int?> totalCapacityBytes() async => 64 * (1 << 30);
}

PlaybackSelection _selection() => PlaybackSelection(
  sourceId: 'source',
  sourceVideoId: 'video',
  title: '影片',
  playbackLineIdentity: 'line',
  episodeIdentity: 'episode',
  episode: const Episode(
    id: '1',
    name: '第1集',
    identity: 'episode',
    url: 'https://cdn.example.com/movie/index.m3u8',
  ),
  playbackSource: PlaybackSource(
    url: Uri.parse('https://cdn.example.com/movie/index.m3u8'),
    format: PlaybackFormat.hls,
  ),
);

PlaybackSelection _selectionFor(int index) {
  final episode = Episode(
    id: '$index',
    name: '第$index集',
    identity: 'episode-$index',
    url: 'https://cdn.example.com/movie/$index/index.m3u8',
  );
  return PlaybackSelection(
    sourceId: 'source',
    sourceVideoId: 'video',
    title: '影片',
    playbackLineIdentity: 'line',
    episodeIdentity: episode.identity,
    episode: episode,
    playbackSource: PlaybackSource(
      url: Uri.parse(episode.url),
      format: PlaybackFormat.hls,
    ),
  );
}

void main() {
  test('AES-128 key and encrypted segments remain playable offline', () async {
    final directory = Directory.systemTemp.createTempSync(
      'jive_download_aes_test',
    );
    final store = CacheIndexStore(directory);
    final cache = CacheManager(store: store, diskSpace: _FakeDiskSpace());
    await cache.initialize();
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      if (request.url.path.endsWith('.m3u8')) {
        return http.Response(_aesManifest, 200);
      }
      if (request.url.path.endsWith('enc.key')) {
        return http.Response.bytes(List<int>.generate(16, (i) => i), 200);
      }
      return http.Response('encrypted-segment', 200);
    });
    final manager = DownloadTaskManager(
      store: store,
      cacheManager: cache,
      client: client,
      resolveSelection: (_) async => _selection(),
    );
    await manager.initialize();
    await manager.enqueue(_selection());
    for (var i = 0; i < 100; i++) {
      if (manager.tasks.single.status == DownloadTaskStatus.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final completed = manager.tasks.single;
    expect(completed.status, DownloadTaskStatus.completed);
    expect(completed.expectedResourceCount, 2);
    expect(requested.any((url) => url.endsWith('/enc.key')), isTrue);
    final entry = await cache.getEntry(
      '${completed.contentKeyHash}|${completed.revisionKeyHash}',
    );
    final catalog = await cache.resourceCatalog(entry!.key);
    final keyRecord = catalog.values.singleWhere(
      (record) => record.ext == 'key',
    );
    expect(keyRecord.size, 16);
    final playable = await store.loadProxyManifest(
      entry.contentKeyHash,
      entry.revisionKeyHash,
    );
    expect(playable, contains('#EXT-X-KEY:METHOD=AES-128'));
    expect(playable, contains('/res/sha256:'));
    expect(playable, isNot(contains('URI="enc.key"')));

    final proxy = LocalProxyServer();
    await proxy.start();
    final offline = await PlaybackSession.prepare(
      selection: _selection(),
      proxy: proxy,
      parser: HlsParser(
        client: MockClient((_) async => throw StateError('offline')),
      ),
      client: MockClient((_) async => throw StateError('offline')),
      cacheManager: cache,
      store: store,
    );
    expect(offline.status.mode.name, 'cachePlayback');
    expect(offline.session, isNotNull);
    final keyPath = RegExp(
      r'URI="(/play/[^\s"]+/res/sha256:[0-9a-f]{64})"',
    ).firstMatch(offline.session!.route.proxyManifest)?.group(1);
    expect(keyPath, isNotNull);
    final localClient = http.Client();
    final keyResponse = await localClient.get(
      Uri.parse('http://127.0.0.1:${proxy.port}$keyPath'),
    );
    expect(keyResponse.statusCode, 200);
    expect(keyResponse.bodyBytes, hasLength(16));
    localClient.close();
    await offline.session!.close(proxy);
    await proxy.close();
    await manager.dispose();
    await cache.flush();
    directory.deleteSync(recursive: true);
  });

  test('paused task finalizes from saved manifest without network', () async {
    final directory = Directory.systemTemp.createTempSync(
      'jive_download_offline_resume_test',
    );
    final store = CacheIndexStore(directory);
    final cache = CacheManager(store: store, diskSpace: _FakeDiskSpace());
    await cache.initialize();
    final segmentStarted = Completer<void>();
    final releaseSegment = Completer<void>();
    final firstClient = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) {
        return http.Response(
          '#EXTM3U\n#EXTINF:4.0,\nsegment.ts\n#EXT-X-ENDLIST\n',
          200,
        );
      }
      if (!segmentStarted.isCompleted) segmentStarted.complete();
      await releaseSegment.future;
      return http.Response('segment', 200);
    });
    final firstManager = DownloadTaskManager(
      store: store,
      cacheManager: cache,
      client: firstClient,
      resolveSelection: (_) async => null,
    );
    await firstManager.initialize();
    final task = await firstManager.enqueue(_selection());
    await segmentStarted.future;
    await firstManager.pause(task.taskId);
    releaseSegment.complete();
    for (var i = 0; i < 100; i++) {
      if (firstManager.tasks.single.status == DownloadTaskStatus.paused) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(firstManager.tasks.single.status, DownloadTaskStatus.paused);
    await firstManager.dispose();
    await cache.flush();

    final restoredCache = CacheManager(
      store: store,
      diskSpace: _FakeDiskSpace(),
    );
    await restoredCache.initialize();
    var networkHits = 0;
    final restoredManager = DownloadTaskManager(
      store: store,
      cacheManager: restoredCache,
      client: MockClient((_) async {
        networkHits++;
        throw StateError('offline');
      }),
      resolveSelection: (_) async => null,
    );
    await restoredManager.initialize();
    await restoredManager.resume(task.taskId);
    for (var i = 0; i < 100; i++) {
      if (restoredManager.tasks.single.status == DownloadTaskStatus.completed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(restoredManager.tasks.single.status, DownloadTaskStatus.completed);
    expect(networkHits, 0);
    await restoredManager.dispose();
    await restoredCache.flush();
    directory.deleteSync(recursive: true);
  });

  test('download concurrency is bounded across tasks', () async {
    final directory = Directory.systemTemp.createTempSync(
      'jive_download_concurrency_test',
    );
    final store = CacheIndexStore(directory);
    final cache = CacheManager(store: store, diskSpace: _FakeDiskSpace());
    await cache.initialize();
    var activeSegments = 0;
    var maxActiveSegments = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('.m3u8')) {
        return http.Response(
          '#EXTM3U\n#EXTINF:4.0,\nsegment.ts\n#EXT-X-ENDLIST\n',
          200,
        );
      }
      activeSegments++;
      if (activeSegments > maxActiveSegments) {
        maxActiveSegments = activeSegments;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      activeSegments--;
      return http.Response('segment', 200);
    });
    final manager = DownloadTaskManager(
      store: store,
      cacheManager: cache,
      client: client,
      resolveSelection: (_) async => null,
      concurrency: 2,
    );
    await manager.initialize();
    for (var i = 0; i < 4; i++) {
      await manager.enqueue(_selectionFor(i));
    }
    expect(
      manager.tasks.where((task) => task.status == DownloadTaskStatus.queued),
      isNotEmpty,
    );
    for (var i = 0; i < 200; i++) {
      if (manager.tasks.every(
        (task) => task.status == DownloadTaskStatus.completed,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      manager.tasks.every(
        (task) => task.status == DownloadTaskStatus.completed,
      ),
      isTrue,
    );
    expect(maxActiveSegments, lessThanOrEqualTo(2));
    await manager.dispose();
    await cache.flush();
    directory.deleteSync(recursive: true);
  });

  test(
    'download saves raw resources then filters locally for offline playback',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'jive_download_test',
      );
      final store = CacheIndexStore(directory);
      final cache = CacheManager(store: store, diskSpace: _FakeDiskSpace());
      await cache.initialize();
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.toString());
        if (request.url.path.endsWith('.m3u8')) {
          return http.Response(_manifest, 200);
        }
        return http.Response('segment:${request.url.path}', 200);
      });
      final manager = DownloadTaskManager(
        store: store,
        cacheManager: cache,
        client: client,
        resolveSelection: (_) async => _selection(),
      );
      await manager.initialize();
      final task = await manager.enqueue(_selection());

      DownloadTask current = task;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        current = manager.tasks.firstWhere(
          (item) => item.taskId == task.taskId,
        );
        if (current.status == DownloadTaskStatus.completed ||
            current.status == DownloadTaskStatus.failed) {
          break;
        }
      }
      // ignore: avoid_print

      expect(current.status, DownloadTaskStatus.completed);
      // Hybrid strategy downloads the original resources first. Filtering is
      // local and happens only after all raw resources have been committed.
      expect(requested.where((url) => url.contains('/ads/')), isNotEmpty);
      final entry = await cache.getEntry(
        '${current.contentKeyHash}|${current.revisionKeyHash}',
      );
      expect(entry?.offlinePlayable, isTrue);
      expect(entry?.finalizationRequired, isFalse);
      expect(entry?.filterVersion, 1);
      final source = await store.loadSourceManifest(
        current.contentKeyHash!,
        current.revisionKeyHash!,
      );
      final playable = await store.loadProxyManifest(
        current.contentKeyHash!,
        current.revisionKeyHash!,
      );
      expect(source, contains('/ads/0001.ts'));
      expect(playable, isNot(contains('/ads/0001.ts')));
      expect(
        await File(
          '${store.entryDir(current.contentKeyHash!, current.revisionKeyHash!).path}/timeline.json',
        ).readAsString(),
        contains('"filterVersion":1'),
      );

      final proxy = LocalProxyServer();
      await proxy.start();
      final offline = await PlaybackSession.prepare(
        selection: _selection(),
        proxy: proxy,
        parser: HlsParser(
          client: MockClient((_) async => throw StateError('offline')),
        ),
        client: MockClient((_) async => throw StateError('offline')),
        cacheManager: cache,
        store: store,
      );
      expect(offline.status.mode.name, 'cachePlayback');
      expect(offline.session, isNotNull);
      expect(offline.session!.route.proxyManifest, isNot(contains('/ads/')));
      final localClient = http.Client();
      final manifestResponse = await localClient.get(
        Uri.parse(offline.session!.proxyManifestUrl),
      );
      expect(manifestResponse.statusCode, 200);
      final resourcePath = RegExp(
        r'(/play/[^\s]+/res/sha256:[0-9a-f]{64})',
      ).firstMatch(manifestResponse.body)?.group(1);
      expect(resourcePath, isNotNull);
      final resourceResponse = await localClient.get(
        Uri.parse('http://127.0.0.1:${proxy.port}${resourcePath!}'),
      );
      expect(resourceResponse.statusCode, 200);
      expect(resourceResponse.body, isNotEmpty);
      localClient.close();
      await offline.session!.close(proxy);
      await proxy.close();
      await manager.dispose();
      await cache.flush();

      final catalog = await cache.resourceCatalog(entry!.key);
      final missing = catalog.entries.first;
      await store
          .resourceFile(
            entry.contentKeyHash,
            entry.revisionKeyHash,
            missing.key,
            missing.value.ext,
          )
          .delete();
      final restoredCache = CacheManager(
        store: store,
        diskSpace: _FakeDiskSpace(),
      );
      await restoredCache.initialize();
      final restoredManager = DownloadTaskManager(
        store: store,
        cacheManager: restoredCache,
        client: MockClient((_) async => throw StateError('offline')),
        resolveSelection: (_) async => null,
      );
      await restoredManager.initialize();
      final restoredTask = restoredManager.tasks.single;
      expect(restoredTask.status, DownloadTaskStatus.paused);
      expect(
        restoredTask.completedResourceCount,
        entry.expectedResourceCount - 1,
      );
      await restoredManager.dispose();
      await restoredCache.flush();
      directory.deleteSync(recursive: true);
    },
  );
}
