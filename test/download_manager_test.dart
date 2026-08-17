import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_io.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/data/cache/download_manager.dart';
import 'package:jive/data/cache/hls_parser.dart';

const _gb = 1 << 30;

class _FakeDiskSpace implements DiskSpaceProvider {
  _FakeDiskSpace(this._available, {this.total});

  final int _available;
  int? total;
  int? platformLimit;

  @override
  Future<int> availableBytes() async => _available;
  @override
  Future<int?> platformCacheLimitBytes() async => platformLimit;
  @override
  Future<int?> totalCapacityBytes() async => total;
}

void main() {
  late Directory tempDir;
  late CacheManager manager;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jive_prefetch_test');
    manager = CacheManager(
      store: CacheIndexStore(tempDir),
      diskSpace: _FakeDiskSpace(20 * _gb, total: 64 * _gb),
    );
    await manager.initialize();
  });

  tearDown(() async {
    await manager.flush();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('prefetches segments from the given position and caches them', () async {
    final fetched = <String>[];
    final client = MockClient((request) async {
      fetched.add(request.url.path);
      return http.Response('Gpayload-${request.url.pathSegments.last}', 200);
    });
    final created = await manager.upsertEntry(
      CacheEntry(
        contentKeyVersion: 1,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
        manifestFingerprint: 'fp',
        sourceId: 's',
        sourceVideoId: 'v',
        title: '影片',
        playbackLineIdentity: 'line',
        playbackLineName: '',
        episodeIdentity: 'ep',
        episodeId: '1',
        episodeName: '第1集',
        expectedResourceCount: 5,
      ),
    );
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: manager.store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final segments = <HlsSegment>[
      for (var i = 0; i < 10; i++)
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/m/seg$i.ts'),
          duration: 4,
        ),
    ];
    final prefetcher = SegmentPrefetcher(
      fetcher: fetcher,
      segments: segments,
      concurrency: 3,
    );
    await prefetcher.prefetch(
      fromPosition: const Duration(seconds: 16),
      lookahead: 5,
    );
    expect(fetched, hasLength(5));
    expect(fetched.first, '/m/seg4.ts');
    expect(fetched.last, '/m/seg8.ts');

    final stats = await manager.stats();
    expect(stats.entries.single.committedResourceCount, 5);
  });

  test('cancel stops further prefetch batches', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('Gdata', 200);
    });
    final created = await manager.upsertEntry(
      CacheEntry(
        contentKeyVersion: 1,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
        manifestFingerprint: 'fp',
        sourceId: 's',
        sourceVideoId: 'v',
        title: '影片',
        playbackLineIdentity: 'line',
        playbackLineName: '',
        episodeIdentity: 'ep',
        episodeId: '1',
        episodeName: '第1集',
      ),
    );
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: manager.store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final segments = [
      for (var i = 0; i < 20; i++)
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/m/seg$i.ts'),
          duration: 4,
        ),
    ];
    final prefetcher = SegmentPrefetcher(
      fetcher: fetcher,
      segments: segments,
      concurrency: 5,
    );
    final future = prefetcher.prefetch(lookahead: 20);
    prefetcher.cancel();
    await future;
    expect(requests, lessThan(20));
  });

  test('resume continues from the cursor and skips already cached', () async {
    final fetched = <String>[];
    final client = MockClient((request) async {
      fetched.add(request.url.path);
      return http.Response('Gdata', 200);
    });
    final created = await manager.upsertEntry(
      CacheEntry(
        contentKeyVersion: 1,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
        manifestFingerprint: 'fp',
        sourceId: 's',
        sourceVideoId: 'v',
        title: '影片',
        playbackLineIdentity: 'line',
        playbackLineName: '',
        episodeIdentity: 'ep',
        episodeId: '1',
        episodeName: '第1集',
        expectedResourceCount: 10,
      ),
    );
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: manager.store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final segments = [
      for (var i = 0; i < 10; i++)
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/m/seg$i.ts'),
          duration: 4,
        ),
    ];
    final prefetcher = SegmentPrefetcher(
      fetcher: fetcher,
      segments: segments,
      concurrency: 5,
    );
    await prefetcher.prefetch(lookahead: 4);
    expect(fetched, hasLength(4));
    fetched.clear();
    prefetcher.pause();
    await prefetcher.prefetch(lookahead: 4);
    expect(fetched, isEmpty);
    prefetcher.resume();
    await prefetcher.prefetch(lookahead: 4);
    expect(fetched, isNotEmpty);
    expect(fetched.first, '/m/seg4.ts');
  });

  test('updatePosition re-anchors the prefetch window after seek', () async {
    final fetched = <String>[];
    final client = MockClient((request) async {
      fetched.add(request.url.path);
      return http.Response('Gdata', 200);
    });
    final created = await manager.upsertEntry(
      CacheEntry(
        contentKeyVersion: 1,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
        manifestFingerprint: 'fp',
        sourceId: 's',
        sourceVideoId: 'v',
        title: '影片',
        playbackLineIdentity: 'line',
        playbackLineName: '',
        episodeIdentity: 'ep',
        episodeId: '1',
        episodeName: '第1集',
      ),
    );
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: manager.store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final segments = [
      for (var i = 0; i < 20; i++)
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/m/seg$i.ts'),
          duration: 4,
        ),
    ];
    final prefetcher = SegmentPrefetcher(
      fetcher: fetcher,
      segments: segments,
      concurrency: 5,
      windowSize: () => 2,
    );
    await prefetcher.prefetch(fromPosition: Duration.zero);
    expect(fetched, ['/m/seg0.ts', '/m/seg1.ts']);
    fetched.clear();

    // seek 到 32s（第 8 片，4s/片）：窗口重排到第 8、9 片。
    await prefetcher.updatePosition(const Duration(seconds: 32));
    expect(fetched, ['/m/seg8.ts', '/m/seg9.ts']);
    fetched.clear();

    // 周期性进度上报：窗口随播放位置前移。
    await prefetcher.updatePosition(const Duration(seconds: 44));
    expect(fetched, ['/m/seg11.ts', '/m/seg12.ts']);
  });

  test('zero window disables prefetching', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('Gdata', 200);
    });
    final created = await manager.upsertEntry(
      CacheEntry(
        contentKeyVersion: 1,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
        manifestFingerprint: 'fp',
        sourceId: 's',
        sourceVideoId: 'v',
        title: '影片',
        playbackLineIdentity: 'line',
        playbackLineName: '',
        episodeIdentity: 'ep',
        episodeId: '1',
        episodeName: '第1集',
      ),
    );
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: manager.store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    var window = 0;
    final prefetcher = SegmentPrefetcher(
      fetcher: fetcher,
      segments: [
        HlsSegment(uri: Uri.parse('https://cdn.example.com/m/seg0.ts')),
      ],
      windowSize: () => window,
    );
    await prefetcher.prefetch(fromPosition: Duration.zero);
    expect(requests, 0);

    // 窗口恢复（如网络切回 Wi-Fi）后再次调度即可预取。
    window = 5;
    await prefetcher.updatePosition(Duration.zero);
    expect(requests, 1);
  });
}
