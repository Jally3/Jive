import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/home/paged_video_controller.dart';

final _source = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

void main() {
  test(
    'a newer search result is not overwritten by an older request',
    () async {
      final repository = _DelayedRepository();
      final controller = PagedVideoController(repository, _source);
      final old = controller.loadInitial(search: '旧');
      final latest = controller.loadInitial(search: '新');
      repository.complete('新');
      await latest;
      repository.complete('旧');
      await old;
      expect(controller.items.single.title, '新');
      expect(controller.loading, isFalse);
    },
  );

  test(
    'keeps loaded items and exposes error when a later page fails',
    () async {
      final repository = _PageRepository();
      final controller = PagedVideoController(repository, _source);
      await controller.loadInitial();
      expect(controller.items, hasLength(1));
      await controller.loadMore();
      expect(controller.items, hasLength(1));
      expect(controller.error, '第 2 页失败');
      expect(controller.loading, isFalse);
    },
  );

  test('deduplicates pages and can retry the failed next page', () async {
    final repository = _RetryRepository();
    final controller = PagedVideoController(repository, _source);
    await controller.loadInitial();
    await controller.loadMore();
    expect(controller.error, isNotNull);
    await controller.loadMore();
    expect(controller.error, isNull);
    expect(controller.items.map((item) => item.globalId), [
      'storm:1',
      'storm:2',
    ]);
    expect(controller.hasMore, isFalse);
  });

  test(
    'switching back to a loaded category reuses the cached first page',
    () async {
      final repository = _CountingRepository();
      final controller = PagedVideoController(repository, _source);
      await controller.loadInitial();
      await controller.loadInitial(category: 20);
      expect(controller.items.single.title, '分类20');
      await controller.loadInitial();
      expect(repository.requests, 2);
      expect(controller.items.single.title, '最新');
    },
  );

  test('refresh bypasses the cached first page', () async {
    final repository = _CountingRepository();
    final controller = PagedVideoController(repository, _source);
    await controller.loadInitial();
    await controller.refresh();
    expect(repository.requests, 2);
  });
}

class _CountingRepository implements VideoRepository {
  var requests = 0;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    requests++;
    return VideoPage(
      items: [
        Video(
          id: '${categoryId ?? 'latest'}',
          title: categoryId == null ? '最新' : '分类$categoryId',
        ),
      ],
      page: 1,
      pageCount: 1,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      const [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

class _RetryRepository implements VideoRepository {
  var pageTwoCalls = 0;
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    if (page == 1) {
      return const VideoPage(
        items: [Video(id: '1', title: 'A')],
        page: 1,
        pageCount: 2,
      );
    }
    if (pageTwoCalls++ == 0) throw const VideoDataException('临时失败');
    return const VideoPage(
      items: [
        Video(id: '1', title: 'A'),
        Video(id: '2', title: 'B'),
      ],
      page: 2,
      pageCount: 2,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      const [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

class _PageRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    if (page == 2) throw const VideoDataException('第 2 页失败');
    return const VideoPage(
      items: [Video(id: '1', title: '第一项')],
      page: 1,
      pageCount: 2,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      const [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

class _DelayedRepository implements VideoRepository {
  final requests = <String, Completer<VideoPage>>{};
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    final completer = Completer<VideoPage>();
    requests[keyword!] = completer;
    return completer.future;
  }

  void complete(String keyword) => requests[keyword]!.complete(
    VideoPage(
      items: [Video(id: keyword, title: keyword)],
      page: 1,
      pageCount: 1,
    ),
  );

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      const [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}
