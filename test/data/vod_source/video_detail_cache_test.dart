import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/vod_source/video_detail_cache.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

final _source = VodSource(
  id: 'source',
  name: 'Source',
  baseUri: Uri.parse('https://example.com/api'),
  adapterType: 'mac_cms_v10',
);

VideoDetailCacheKey _key(String id) => videoDetailCacheKey(
  _source,
  VideoRef(sourceId: _source.id, sourceVideoId: id),
);

void main() {
  testWidgets('expiry releases entries without another cache access', (
    tester,
  ) async {
    var now = DateTime(2026);
    final cache = VideoDetailCache(now: () => now);
    addTearDown(cache.dispose);
    const video = Video(id: '1', title: 'Title');
    cache.put(_key('1'), video);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(cache.get(_key('1')), same(video));
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(cache.entryCount, 0);
    expect(cache.estimatedBytes, 0);
  });

  test('reads update LRU order and count evicts the least recently used', () {
    final cache = VideoDetailCache(maxEntries: 2);
    addTearDown(cache.dispose);
    for (final id in ['1', '2']) {
      cache.put(_key(id), Video(id: id, title: id));
    }
    cache.get(_key('1'));
    cache.put(_key('3'), const Video(id: '3', title: '3'));
    expect(cache.get(_key('2')), isNull);
    expect(cache.get(_key('1')), isNotNull);
    expect(cache.get(_key('3')), isNotNull);
  });

  test('size budget evicts old entries and skips oversized resources', () {
    const small = Video(id: '1', title: 'Title');
    final bytes = VideoDetailCache.estimateVideoBytes(small);
    final cache = VideoDetailCache(maxEstimatedBytes: bytes);
    addTearDown(cache.dispose);
    cache.put(_key('1'), small);
    cache.put(_key('2'), small);
    expect(cache.get(_key('1')), isNull);
    expect(cache.get(_key('2')), same(small));
    cache.put(_key('3'), Video(id: '3', title: 'long' * 1000));
    expect(cache.get(_key('3')), isNull);
    expect(cache.get(_key('2')), same(small));
    expect(cache.estimatedBytes, lessThanOrEqualTo(bytes));
  });

  test(
    'shared episode lists are counted once and URLs count toward budget',
    () {
      const episode = Episode(id: '1', name: 'One', url: 'https://cdn/one');
      const shared = [episode];
      const video = Video(
        id: '1',
        title: 'Title',
        episodes: shared,
        playbackLines: [PlaybackLine(id: '0', name: 'Line', episodes: shared)],
      );
      final duplicateList = video.copyWith(
        playbackLines: [
          PlaybackLine(id: '0', name: 'Line', episodes: [...shared]),
        ],
      );
      expect(
        VideoDetailCache.estimateVideoBytes(duplicateList),
        greaterThan(VideoDetailCache.estimateVideoBytes(video)),
      );
      final longUrl = video.copyWith(
        episodes: [
          Episode(id: '1', name: 'One', url: 'https://cdn/${'token' * 1000}'),
        ],
      );
      expect(
        VideoDetailCache.estimateVideoBytes(longUrl),
        greaterThan(VideoDetailCache.estimateVideoBytes(video)),
      );
    },
  );

  testWidgets('dispose clears retained models and cancels expiry', (
    tester,
  ) async {
    final cache = VideoDetailCache();
    cache.put(_key('1'), const Video(id: '1', title: 'Title'));
    cache.dispose();
    cache.put(_key('2'), const Video(id: '2', title: 'Title'));
    expect(cache.entryCount, 0);
    expect(cache.estimatedBytes, 0);
  });
}
