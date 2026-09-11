import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/home/curated_vod_search_pool.dart';

void main() {
  const source = 'source|adapter|https://example.com|';

  test('source fingerprint changes when endpoint configuration changes', () {
    final first = VodSource(
      id: 'same-id',
      name: 'Source',
      baseUri: Uri.parse('https://one.example.com'),
      adapterType: 'mac_cms_v10',
    );
    final second = VodSource(
      id: 'same-id',
      name: 'Source',
      baseUri: Uri.parse('https://two.example.com'),
      adapterType: 'mac_cms_v10',
    );

    expect(
      curatedVodSourceFingerprint(first),
      isNot(curatedVodSourceFingerprint(second)),
    );
  });

  test(
    'deduplicates in-flight requests and then serves the ready cache',
    () async {
      final pool = CuratedVodSearchPool();
      addTearDown(pool.close);
      final response = Completer<VideoPage>();
      var calls = 0;

      Future<VideoPage> loader(Future<void> _) {
        calls++;
        return response.future;
      }

      final first = pool.acquire(
        sourceFingerprint: source,
        query: '  Test   Movie ',
        loader: loader,
      );
      final joined = pool.acquire(
        sourceFingerprint: source,
        query: 'test movie',
        loader: loader,
      );
      expect(first.reuseKind, SearchReuseKind.network);
      expect(joined.reuseKind, SearchReuseKind.joinedInflight);
      expect(calls, 1);

      response.complete(_page('test movie'));
      await Future.wait([first.future, joined.future]);
      first.release();
      joined.release();

      final cached = pool.acquire(
        sourceFingerprint: source,
        query: 'TEST MOVIE',
        loader: loader,
      );
      expect(cached.reuseKind, SearchReuseKind.cache);
      expect((await cached.future).page.items.single.title, 'test movie');
      expect(calls, 1);
    },
  );

  test('peekReady is synchronous, touches LRU, and expires safely', () async {
    var now = DateTime(2026, 9, 11);
    final pool = CuratedVodSearchPool(
      maxReadyEntries: 2,
      successTtl: const Duration(minutes: 1),
      now: () => now,
    );
    addTearDown(pool.close);
    var calls = 0;
    Future<VideoPage> loader(Future<void> _) async {
      calls++;
      return _page('ready');
    }

    final lease = pool.acquire(
      sourceFingerprint: source,
      query: 'Ready',
      loader: loader,
    );
    await lease.future;
    lease.release();

    final peeked = pool.peekReady(sourceFingerprint: source, query: ' ready ');
    expect(peeked?.reuseKind, SearchReuseKind.cache);
    expect(peeked?.page.items.single.title, 'ready');
    expect(calls, 1);

    now = now.add(const Duration(minutes: 1));
    expect(pool.peekReady(sourceFingerprint: source, query: 'ready'), isNull);
  });

  test('source eviction and ready clearing are isolated', () async {
    final pool = CuratedVodSearchPool();
    addTearDown(pool.close);

    Future<void> load(String sourceKey) async {
      final lease = pool.acquire(
        sourceFingerprint: sourceKey,
        query: 'shared',
        loader: (_) async => _page(sourceKey),
      );
      await lease.future;
      lease.release();
    }

    await load('source-a');
    await load('source-b');
    pool.evictSource('source-a');
    expect(
      pool.peekReady(sourceFingerprint: 'source-a', query: 'shared'),
      isNull,
    );
    expect(
      pool.peekReady(sourceFingerprint: 'source-b', query: 'shared'),
      isNotNull,
    );
    pool.clearReady();
    expect(pool.readyEntryCount, 0);
  });

  test('retains ready entries for only the most recent sources', () async {
    var now = DateTime(2026, 9, 11);
    final pool = CuratedVodSearchPool(maxReadySources: 2, now: () => now);
    addTearDown(pool.close);

    for (final sourceKey in ['source-a', 'source-b', 'source-c']) {
      final lease = pool.acquire(
        sourceFingerprint: sourceKey,
        query: 'shared',
        loader: (_) async => _page(sourceKey),
      );
      await lease.future;
      lease.release();
      now = now.add(const Duration(seconds: 1));
    }

    expect(
      pool.peekReady(sourceFingerprint: 'source-a', query: 'shared'),
      isNull,
    );
    expect(
      pool.peekReady(sourceFingerprint: 'source-b', query: 'shared'),
      isNotNull,
    );
    expect(
      pool.peekReady(sourceFingerprint: 'source-c', query: 'shared'),
      isNotNull,
    );
  });

  test('aborts only after the final in-flight subscriber releases', () async {
    final pool = CuratedVodSearchPool();
    addTearDown(pool.close);
    var aborted = false;

    Future<VideoPage> loader(Future<void> abort) async {
      await abort;
      aborted = true;
      throw StateError('aborted');
    }

    final first = pool.acquire(
      sourceFingerprint: source,
      query: 'shared',
      loader: loader,
    );
    final joined = pool.acquire(
      sourceFingerprint: source,
      query: 'shared',
      loader: loader,
    );
    final firstError = expectLater(first.future, throwsA(anything));
    final joinedError = expectLater(joined.future, throwsA(anything));

    first.release();
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isFalse);
    joined.release();
    await Future.wait([firstError, joinedError]);
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
  });

  test('enforces one concurrency budget across different queries', () async {
    final pool = CuratedVodSearchPool(maxConcurrentRequests: 1);
    addTearDown(pool.close);
    final firstResponse = Completer<VideoPage>();
    final secondResponse = Completer<VideoPage>();
    final started = <String>[];

    final first = pool.acquire(
      sourceFingerprint: source,
      query: 'first',
      loader: (_) {
        started.add('first');
        return firstResponse.future;
      },
    );
    final second = pool.acquire(
      sourceFingerprint: source,
      query: 'second',
      loader: (_) {
        started.add('second');
        return secondResponse.future;
      },
    );
    expect(started, ['first']);

    firstResponse.complete(_page('first'));
    await first.future;
    first.release();
    await _waitFor(() => started.length == 2);
    secondResponse.complete(_page('second'));
    await second.future;
    second.release();
    expect(started, ['first', 'second']);
  });

  test(
    'empty responses expire earlier and refresh bypasses ready cache',
    () async {
      var now = DateTime(2026, 9, 11);
      final pool = CuratedVodSearchPool(now: () => now);
      addTearDown(pool.close);
      var calls = 0;

      Future<VideoPage> loader(Future<void> _) async {
        calls++;
        return const VideoPage(items: [], page: 1, pageCount: 1);
      }

      final first = pool.acquire(
        sourceFingerprint: source,
        query: 'missing',
        loader: loader,
      );
      await first.future;
      first.release();
      expect(calls, 1);

      now = now.add(const Duration(seconds: 89));
      final cached = pool.acquire(
        sourceFingerprint: source,
        query: 'missing',
        loader: loader,
      );
      expect(cached.reuseKind, SearchReuseKind.cache);
      await cached.future;
      expect(calls, 1);

      final refreshed = pool.acquire(
        sourceFingerprint: source,
        query: 'missing',
        loader: loader,
        mode: SearchCacheMode.refresh,
      );
      await refreshed.future;
      refreshed.release();
      expect(calls, 2);

      now = now.add(const Duration(seconds: 91));
      final expired = pool.acquire(
        sourceFingerprint: source,
        query: 'missing',
        loader: loader,
      );
      await expired.future;
      expired.release();
      expect(calls, 3);
    },
  );

  test(
    'isolates source fingerprints and evicts the least recently used result',
    () async {
      var now = DateTime(2026, 9, 11);
      final pool = CuratedVodSearchPool(maxReadyEntries: 2, now: () => now);
      addTearDown(pool.close);
      var calls = 0;

      Future<void> load(String sourceKey, String query) async {
        final lease = pool.acquire(
          sourceFingerprint: sourceKey,
          query: query,
          loader: (_) async {
            calls++;
            return _page('$sourceKey:$query');
          },
        );
        await lease.future;
        lease.release();
        now = now.add(const Duration(seconds: 1));
      }

      await load('source-a', 'shared');
      await load('source-b', 'shared');
      expect(calls, 2);

      await load('source-a', 'third');
      expect(pool.readyEntryCount, 2);
      await load('source-a', 'shared');

      expect(calls, 4);
    },
  );
}

VideoPage _page(String title) => VideoPage(
  items: [Video(id: title, title: title)],
  page: 1,
  pageCount: 1,
);

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
