import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_manager.dart';

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

const _gb = 1 << 30;
const _mb = 1 << 20;

CacheEntry entry(
  String tag, {
  CacheEntryStatus status = CacheEntryStatus.partial,
}) => CacheEntry(
  contentKeyVersion: 1,
  contentKeyHash: 'ck$tag',
  revisionKeyHash: 'rk$tag',
  manifestFingerprint: 'fp$tag',
  sourceId: 's',
  sourceVideoId: 'v',
  title: '影片$tag',
  playbackLineIdentity: 'line$tag',
  playbackLineName: '线路1',
  episodeIdentity: 'ep$tag',
  episodeId: '1',
  episodeName: '正片',
  status: status,
  createdAtMs: 0,
  updatedAtMs: 0,
  lastAccessMs: 0,
);

void main() {
  late Directory tempDir;
  late CacheIndexStore store;
  late _FakeDiskSpace disk;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jive_cache_manager_test');
    store = CacheIndexStore(tempDir);
    disk = _FakeDiskSpace(20 * _gb, total: 64 * _gb);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('computeEffectiveQuota', () {
    test('uses available space minus safety reserve without a fixed cap', () {
      expect(
        computeEffectiveQuota(availableBytes: 20 * _gb, jiveCacheBytes: 0),
        20 * _gb,
      );
      expect(
        computeEffectiveQuota(availableBytes: 100 * _gb, jiveCacheBytes: 0),
        100 * _gb,
      );
      expect(
        computeEffectiveQuota(availableBytes: 2 * _gb, jiveCacheBytes: 0),
        2 * _gb,
      );
    });

    test('respects system safety reserve', () {
      final quota = computeEffectiveQuota(
        availableBytes: 4 * _gb,
        jiveCacheBytes: 0,
        totalCapacity: 64 * _gb,
      );
      expect(quota, 4 * _gb - (64 * _gb * 5) ~/ 100);
      final zero = computeEffectiveQuota(
        availableBytes: 2 * _gb,
        jiveCacheBytes: 0,
        totalCapacity: 64 * _gb,
      );
      expect(zero, 0);
    });

    test('does not apply temporary platform cache quota', () {
      final quota = computeEffectiveQuota(
        availableBytes: 20 * _gb,
        jiveCacheBytes: 0,
        totalCapacity: 64 * _gb,
        platformCacheLimit: 500 * _mb,
      );
      expect(quota, 20 * _gb - (64 * _gb * 5) ~/ 100);
    });

    test('counts existing cache toward manageable space', () {
      final withCache = computeEffectiveQuota(
        availableBytes: 20 * _gb,
        jiveCacheBytes: 1 * _gb,
        totalCapacity: 64 * _gb,
      );
      final withoutCache = computeEffectiveQuota(
        availableBytes: 20 * _gb,
        jiveCacheBytes: 0,
        totalCapacity: 64 * _gb,
      );
      expect(withCache, greaterThan(withoutCache));
    });
  });

  group('CacheManager', () {
    test('initialize restores entries from state files', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      await manager.upsertEntry(entry('1'));
      final restored = CacheManager(store: store, diskSpace: disk);
      await restored.initialize();
      expect(restored.stats().then((s) => s.entryCount), completion(1));
    });

    test('reserve then commit accumulates bytes and completeness', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final created = await manager.upsertEntry(entry('1'));
      await manager.setExpectations(created.key, 2);

      final lease = await manager.reserve(created.key, 400 * _mb);
      expect(lease, isNotNull);
      await lease!.commitResource(
        resourceId: '0000',
        size: 400 * _mb,
        ext: 'ts',
      );
      final stats = await manager.stats();
      expect(stats.completeBytes, 400 * _mb);
      expect(stats.usedBytes, 400 * _mb);
      expect(stats.entries.single.offlinePlayable, isFalse);

      final secondLease = await manager.reserve(created.key, 300 * _mb);
      await secondLease?.commitResource(
        resourceId: '0001',
        size: 300 * _mb,
        ext: 'ts',
      );
      final after = await manager.stats();
      expect(after.entries.single.offlinePlayable, isTrue);
      expect(after.entries.single.status, CacheEntryStatus.complete);
      expect(after.reservedBytes, 0);
    });

    test('explicit entries stay offline-ineligible until finalized', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final created = await manager.upsertEntry(entry('explicit'));
      await store.saveSourceManifest('ckexplicit', 'rkexplicit', '#EXTM3U');
      await store.saveProxyManifest('ckexplicit', 'rkexplicit', '#EXTM3U');
      await manager.setExpectations(created.key, 1, requireFinalization: true);
      final lease = await manager.reserve(created.key, 100);
      await lease!.commitResource(
        resourceId: 'sha256:${'f' * 64}',
        size: 100,
        ext: 'ts',
      );

      expect((await manager.getEntry(created.key))!.offlinePlayable, isFalse);
      expect(await manager.finalizeEntry(created.key), isTrue);
      expect((await manager.getEntry(created.key))!.offlinePlayable, isTrue);
    });

    test('canceled lease releases reserved capacity', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final created = await manager.upsertEntry(entry('1'));
      final lease = await manager.reserve(created.key, 300 * _mb);
      expect(await manager.stats(), isNotNull);
      expect((await manager.stats()).reservedBytes, 300 * _mb);
      await lease!.cancel();
      expect((await manager.stats()).reservedBytes, 0);
    });

    test('reserve fails when quota exhausted and nothing evictable', () async {
      disk = _FakeDiskSpace(2 * _gb, total: 64 * _gb);
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final created = await manager.upsertEntry(entry('1'));
      final lease = await manager.reserve(created.key, 4 * _gb);
      expect(lease, isNull);
    });

    test('evicts oldest partial cache before complete cache', () async {
      disk = _FakeDiskSpace(6 * _gb + 500 * _mb, total: 64 * _gb);
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();

      final oldPartial = await manager.upsertEntry(entry('old'));
      final oldLease = await manager.reserve(oldPartial.key, 700 * _mb);
      await oldLease?.commitResource(
        resourceId: '0',
        size: 700 * _mb,
        ext: 'ts',
      );
      await manager.touch(oldPartial.key);

      final newPartial = await manager.upsertEntry(entry('new'));
      final newLease = await manager.reserve(newPartial.key, 700 * _mb);
      await newLease?.commitResource(
        resourceId: '0',
        size: 700 * _mb,
        ext: 'ts',
      );

      final complete = await manager.upsertEntry(
        entry('done', status: CacheEntryStatus.complete),
      );
      await manager.setExpectations(complete.key, 1);
      final completeLease = await manager.reserve(complete.key, 700 * _mb);
      await completeLease?.commitResource(
        resourceId: '0',
        size: 700 * _mb,
        ext: 'ts',
      );

      expect((await manager.stats()).entryCount, 3);
      final lease = await manager.reserve(oldPartial.key, 1500 * _mb);
      expect(lease, isNotNull);
      await lease?.cancel();

      final stats = await manager.stats();
      expect(stats.entryCount, 2);
      expect(
        stats.entries.map((e) => e.title),
        containsAll(['影片old', '影片done']),
      );
      expect(stats.entries.map((e) => e.title), isNot(contains('影片new')));
    });

    test('referenced entries are never evicted', () async {
      disk = _FakeDiskSpace(6 * _gb, total: 64 * _gb);
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final busy = await manager.upsertEntry(entry('busy'));
      final busyLease = await manager.reserve(busy.key, 400 * _mb);
      await busyLease?.commitResource(
        resourceId: '0',
        size: 400 * _mb,
        ext: 'ts',
      );
      await manager.touch(busy.key);
      final ref = await manager.acquire(busy.key);

      await manager.reserve(busy.key, 3 * _gb);
      final stats = await manager.stats();
      expect(stats.entryCount, 1);
      expect(stats.entries.single.title, '影片busy');

      await ref.dispose();
    });

    test(
      'deleteEntry is blocked while referenced then deletes after',
      () async {
        final manager = CacheManager(store: store, diskSpace: disk);
        await manager.initialize();
        final created = await manager.upsertEntry(entry('1'));
        final ref = await manager.acquire(created.key);
        expect(await manager.deleteEntry(created.key), DeleteResult.blocked);
        await ref.dispose();
        expect(await manager.deleteEntry(created.key), DeleteResult.deleted);
        expect((await manager.stats()).entryCount, 0);
        expect(store.entryDir('ck1', 'rk1').existsSync(), isFalse);
      },
    );

    test('clearAll skips active entries and reports counts', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final active = await manager.upsertEntry(entry('active'));
      await manager.upsertEntry(entry('idle'));
      final ref = await manager.acquire(active.key);
      final result = await manager.clearAll();
      expect(result.deleted, 1);
      expect(result.skippedActive, 1);
      expect(result.failed, 0);
      await ref.dispose();
    });

    test('touch updates lastAccess for LRU ordering', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final first = await manager.upsertEntry(entry('1'));
      await manager.touch(first.key);
      await manager.upsertEntry(entry('2'));
      final stats = await manager.stats();
      expect(stats.entries.first.title, '影片1');
      expect(stats.entries.last.title, '影片2');
    });

    test('markFailed records error summary', () async {
      final manager = CacheManager(store: store, diskSpace: disk);
      await manager.initialize();
      final created = await manager.upsertEntry(entry('1'));
      await manager.markFailed(created.key, '4096');
      final stats = await manager.stats();
      expect(stats.entries.single.status, CacheEntryStatus.failed);
      expect(stats.entries.single.errorSummary, '4096');
    });

    test(
      'committing the same resource twice does not double the count',
      () async {
        final manager = CacheManager(store: store, diskSpace: disk);
        await manager.initialize();
        final created = await manager.upsertEntry(entry('1'));
        await manager.setExpectations(created.key, 2);
        final id = 'sha256:${'a' * 64}';
        for (var i = 0; i < 2; i++) {
          final lease = await manager.reserve(created.key, 100);
          await lease?.commitResource(resourceId: id, size: 100, ext: 'ts');
        }
        final stats = await manager.stats();
        expect(stats.entries.single.committedResourceCount, 1);
        expect(stats.entries.single.completeBytes, 100);
      },
    );

    test(
      'findOffline returns a fully cached entry matching the base url',
      () async {
        final manager = CacheManager(store: store, diskSpace: disk);
        await manager.initialize();
        final created = await manager.upsertEntry(
          entry(
            '1',
          ).copyWith(manifestBaseUrl: 'https://cdn.example.com/a.m3u8'),
        );
        await manager.setExpectations(created.key, 1);
        final lease = await manager.reserve(created.key, 100);
        await lease?.commitResource(
          resourceId: 'sha256:${'a' * 64}',
          size: 100,
          ext: 'ts',
        );
        final hit = await manager.findOffline(
          created.contentKeyHash,
          'https://cdn.example.com/a.m3u8',
        );
        expect(hit, isNotNull);
        expect(hit!.offlinePlayable, isTrue);
        expect(
          await manager.findOffline(
            created.contentKeyHash,
            'https://other.example.com/x',
          ),
          isNull,
        );
      },
    );

    test(
      'reconcile fixes missing files and removes deleting leftovers',
      () async {
        final manager = CacheManager(store: store, diskSpace: disk);
        await manager.initialize();
        final created = await manager.upsertEntry(entry('1'));
        await manager.setExpectations(created.key, 1);
        final lease = await manager.reserve(created.key, 100);
        await lease?.commitResource(
          resourceId: 'sha256:${'a' * 64}',
          size: 100,
          ext: 'ts',
        );
        // commitResource 只更新元数据，物理文件由缓存写入方创建，这里模拟。
        final resFile = store.resourceFile(
          'ck1',
          'rk1',
          'sha256:${'a' * 64}',
          'ts',
        );
        await resFile.parent.create(recursive: true);
        await resFile.writeAsBytes(List.filled(100, 0));
        expect((await manager.stats()).entries.single.offlinePlayable, isTrue);
        expect(resFile.existsSync(), isTrue);

        // 模拟文件被外部删除后重启恢复
        resFile.deleteSync();
        final restored = CacheManager(store: store, diskSpace: disk);
        await restored.initialize();
        final stats = await restored.stats();
        expect(stats.entries.single.offlinePlayable, isFalse);
        expect(stats.entries.single.committedResourceCount, 0);
        expect(stats.entries.single.completeBytes, 0);
      },
    );
  });
}
