import 'dart:async';
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
        return http.Response('Gsegment-data-1234', 200);
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
      expect(await _collect(first.body), 'Gsegment-data-1234');

      final stats = await manager.stats();
      expect(stats.entries.single.completeBytes, greaterThan(0));
      expect(store.resourceFile('ck1', 'rk1', id, 'ts').existsSync(), isTrue);

      final second = await fetcher.fetch(
        origin: Uri.parse('https://cdn.example.com/a.ts'),
        resourceId: id,
        ext: 'ts',
      );
      expect(second.fromCache, isTrue);
      expect(await _collect(second.body), 'Gsegment-data-1234');
      expect(originHits, 1);
    },
  );

  test('cached resource serves a sub range with 206', () async {
    final client = MockClient(
      (request) async => http.Response('G123456789', 200),
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
      (request) async => http.Response('G123456789', 200),
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

  test(
    'ranged request on uncached resource caches the full body and slices',
    () async {
      var originHits = 0;
      final client = MockClient((request) async {
        originHits++;
        // 完整资源 10 字节（合法的 fMP4 box 头）；Range 未命中时先全量写穿缓存。
        return http.Response('0000ftypXX', 200);
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
        origin: Uri.parse('https://cdn.example.com/a.m4s'),
        resourceId: id,
        ext: 'm4s',
        downstreamHeaders: {'range': 'bytes=4-7'},
      );
      expect(first.statusCode, 206);
      expect(first.headers['content-range'], 'bytes 4-7/10');
      expect(await _collect(first.body), 'ftyp');
      // 完整资源已提交进缓存。
      final record = await manager.resourceRecord(created.key, id);
      expect(record?.complete, isTrue);
      expect(record?.size, 10);

      // 第二次 Range 请求直接命中缓存，不再回源。
      final second = await fetcher.fetch(
        origin: Uri.parse('https://cdn.example.com/a.m4s'),
        resourceId: id,
        ext: 'm4s',
        downstreamHeaders: {'range': 'bytes=0-3'},
      );
      expect(second.statusCode, 206);
      expect(second.fromCache, isTrue);
      expect(await _collect(second.body), '0000');
      expect(originHits, 1);
    },
  );

  test('over quota fetch streams through without caching', () async {
    manager = CacheManager(
      store: store,
      diskSpace: _FakeDiskSpace(2 * _gb, total: 64 * _gb),
    );
    await manager.initialize();
    final client = MockClient(
      (request) async => http.Response('Gpayload', 200),
    );
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
    expect(await _collect(result.body), 'Gpayload');
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
        client: MockClient((_) async => http.Response('Gpayload', 200)),
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
        return http.Response('Gdata', 200);
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

  test('truncated body (content-length mismatch) is not committed', () async {
    var originHits = 0;
    final client = MockClient((request) async {
      originHits++;
      // 声明 100 字节但只给 10 字节：截断响应。
      return http.Response(
        'G123456789',
        200,
        headers: {'content-length': '100'},
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
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    await _collect(result.body);
    // 截断内容不得提交为完整资源；下次请求重新回源。
    final record = await manager.resourceRecord(created.key, id);
    expect(record?.complete, isNot(true));
    final second = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    expect(second.fromCache, isFalse);
    await _collect(second.body);
    expect(originHits, 2);
  });

  test('html error page for a media segment is not committed', () async {
    var originHits = 0;
    final client = MockClient((request) async {
      originHits++;
      return http.Response('<html>error</html>', 200);
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
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    await _collect(result.body);
    // 魔数不匹配（TS 缺 0x47 同步字节），不提交缓存。
    final record = await manager.resourceRecord(created.key, id);
    expect(record?.complete, isNot(true));
    expect(originHits, 1);
  });

  test('encrypted segments skip the magic check', () async {
    final client = MockClient(
      // 密文没有 0x47 同步字节，也不应被拒绝。
      (request) async => http.Response('ciphertext!!', 200),
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
      encryptedSegments: true,
    );
    final id = 'sha256:${'a' * 64}';
    final result = await fetcher.fetch(
      origin: Uri.parse('https://cdn.example.com/a.ts'),
      resourceId: id,
      ext: 'ts',
    );
    await _collect(result.body);
    final record = await manager.resourceRecord(created.key, id);
    expect(record?.complete, isTrue);
  });

  test(
    'in-flight write after entry deletion leaves no dirs, files or records',
    () async {
      final bodyController = StreamController<List<int>>();
      final client = MockClient.streaming((request, headers) async {
        return http.StreamedResponse(
          bodyController.stream,
          200,
          headers: {'content-length': '6'},
        );
      });
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
      bodyController.add('G12345'.codeUnits);
      // 写入在途时用户删除该条目
      expect(await manager.deleteEntry(created.key), DeleteResult.deleted);
      await bodyController.close();
      // 已流出的字节仍送达播放器，回源播放不受影响
      expect(await _collect(result.body), 'G12345');

      expect(bypassReason, PlaybackFallbackReason.cacheWriteFailed);
      // 不重建已删目录，不落正式文件，不留记录
      expect(store.entryDir('ck1', 'rk1').existsSync(), isFalse);
      expect(store.resourceFile('ck1', 'rk1', id, 'ts').existsSync(), isFalse);
      expect(await manager.resourceRecord(created.key, id), isNull);
      expect((await manager.stats()).entryCount, 0);
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
