import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_io.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/domain/playback_status.dart';

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

CacheEntry entry(String tag) => CacheEntry(
  contentKeyVersion: 1,
  contentKeyHash: 'ck$tag',
  revisionKeyHash: 'rk$tag',
  manifestFingerprint: 'fp',
  sourceId: 's',
  sourceVideoId: 'v',
  title: '影片$tag',
  playbackLineIdentity: 'line',
  playbackLineName: '线路1',
  episodeIdentity: 'ep',
  episodeId: '1',
  episodeName: '第1集',
  expectedResourceCount: 2,
);

void main() {
  late Directory tempDir;
  late CacheIndexStore store;
  late CacheManager manager;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jive_cache_io_test');
    store = CacheIndexStore(tempDir);
    manager = CacheManager(
      store: store,
      diskSpace: _FakeDiskSpace(20 * _gb, total: 64 * _gb),
    );
    await manager.initialize();
  });

  tearDown(() async {
    await manager.flush();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'full 200 fetch is cached and a second fetch serves from disk',
    () async {
      var originHits = 0;
      final client = MockClient((request) async {
        originHits++;
        return http.Response('segment-data-1234', 200);
      });
      final created = await manager.upsertEntry(entry('1'));
      final fetcher = ResourceFetcher(
        client: client,
        sessionHeaders: const {},
        manager: manager,
        store: store,
        entryKey: created.key,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
      );
      final id = 'sha256:${'a' * 64}';
      final first = await fetcher.fetch(
        origin: Uri.parse('https://cdn.example.com/a.ts'),
        resourceId: id,
        ext: 'ts',
      );
      expect(first.fromCache, isFalse);
      expect(await _collect(first.body), 'segment-data-1234');

      final stats = await manager.stats();
      expect(stats.entries.single.completeBytes, greaterThan(0));
      expect(store.resourceFile('ck1', 'rk1', id, 'ts').existsSync(), isTrue);

      final second = await fetcher.fetch(
        origin: Uri.parse('https://cdn.example.com/a.ts'),
        resourceId: id,
        ext: 'ts',
      );
      expect(second.fromCache, isTrue);
      expect(await _collect(second.body), 'segment-data-1234');
      expect(originHits, 1);
    },
  );

  test('cached resource serves a sub range with 206', () async {
    final client = MockClient(
      (request) async => http.Response('0123456789', 200),
    );
    final created = await manager.upsertEntry(entry('1'));
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final id = 'sha256:${'a' * 64}';
    final first = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    await _collect(first.body);
    final ranged = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
      downstreamHeaders: {'range': 'bytes=2-5'},
    );
    expect(ranged.statusCode, 206);
    expect(ranged.headers['content-range'], 'bytes 2-5/10');
    expect(await _collect(ranged.body), '2345');
  });

  test('invalid range on cached resource returns 416', () async {
    final client = MockClient(
      (request) async => http.Response('0123456789', 200),
    );
    final created = await manager.upsertEntry(entry('1'));
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final id = 'sha256:${'a' * 64}';
    final first = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    await _collect(first.body);
    final ranged = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
      downstreamHeaders: {'range': 'bytes=100-200'},
    );
    expect(ranged.statusCode, 416);
  });

  test('ranged requests pass through without being cached', () async {
    var originHits = 0;
    final client = MockClient((request) async {
      originHits++;
      return http.Response(
        'abcdef',
        206,
        headers: {'content-range': 'bytes 0-5/100'},
      );
    });
    final created = await manager.upsertEntry(entry('1'));
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
    );
    final id = 'sha256:${'a' * 64}';
    final result = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.m4s'),
      resourceId: id,
      ext: 'm4s',
      downstreamHeaders: {'range': 'bytes=0-5'},
    );
    expect(result.statusCode, 206);
    expect(await _collect(result.body), 'abcdef');
    expect(originHits, 1);
    final record = await manager.resourceRecord(created.key, id);
    expect(record, isNull);
  });

  test('over quota fetch streams through without caching', () async {
    manager = CacheManager(
      store: store,
      diskSpace: _FakeDiskSpace(2 * _gb, total: 64 * _gb),
    );
    await manager.initialize();
    final client = MockClient((request) async => http.Response('payload', 200));
    final created = await manager.upsertEntry(entry('1'));
    PlaybackFallbackReason? bypassReason;
    final fetcher = ResourceFetcher(
      client: client,
      sessionHeaders: const {},
      manager: manager,
      store: store,
      entryKey: created.key,
      contentKeyHash: 'ck1',
      revisionKeyHash: 'rk1',
      onCacheBypass: (reason) => bypassReason = reason,
    );
    final id = 'sha256:${'a' * 64}';
    final result = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    expect(await _collect(result.body), 'payload');
    expect(bypassReason, PlaybackFallbackReason.cacheQuotaExceeded);
    final record = await manager.resourceRecord(created.key, id);
    expect(record, isNull);
  });

  test(
    'explicit download reports quota exhaustion instead of bypassing',
    () async {
      manager = CacheManager(
        store: store,
        diskSpace: _FakeDiskSpace(2 * _gb, total: 64 * _gb),
      );
      await manager.initialize();
      final created = await manager.upsertEntry(entry('1'));
      final fetcher = ResourceFetcher(
        client: MockClient((_) async => http.Response('payload', 200)),
        sessionHeaders: const {},
        manager: manager,
        store: store,
        entryKey: created.key,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
        failOnCacheUnavailable: true,
      );

      expect(
        () => fetcher.fetch(
          origin: Uri.parse('https://cdn.example.com/a.ts'),
          resourceId: 'sha256:${'b' * 64}',
          ext: 'ts',
        ),
        throwsA(isA<CacheQuotaException>()),
      );
    },
  );

  test(
    'concurrent identical fetches are deduplicated by single flight',
    () async {
      var originHits = 0;
      final client = MockClient((request) async {
        originHits++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response('data', 200);
      });
      final created = await manager.upsertEntry(entry('1'));
      final fetcher = ResourceFetcher(
        client: client,
        sessionHeaders: const {},
        manager: manager,
        store: store,
        entryKey: created.key,
        contentKeyHash: 'ck1',
        revisionKeyHash: 'rk1',
      );
      final id = 'sha256:${'a' * 64}';
      final results = await Future.wait([
        fetcher.fetch(
          origin: Uri.parse('https://cdn.example.com/a.ts'),
          resourceId: id,
          ext: 'ts',
        ),
        fetcher.fetch(
          origin: Uri.parse('https://cdn.example.com/a.ts'),
          resourceId: id,
          ext: 'ts',
        ),
      ]);
      expect(identical(results[0], results[1]), isTrue);
      await _collect(results[0].body);
      expect(originHits, 1);
    },
  );
}

Future<String> _collect(Stream<List<int>> stream) async {
  final buffer = StringBuffer();
  await for (final chunk in stream) {
    buffer.write(String.fromCharCodes(chunk));
  }
  return buffer.toString();
}
