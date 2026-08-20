import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/category_blocklist.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source_adapter.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

final _source = VodSource(
  id: 's',
  name: '测试源',
  baseUri: Uri.parse('https://s.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

class _FakeAdapter implements VodSourceAdapter {
  @override
  String get adapterType => 'mac_cms_v10';

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: const [
      Video(id: '1', title: '正常影片', typeId: 1, category: '电影片'),
      Video(id: '2', title: '敏感影片', typeId: 2, category: '伦理片'),
    ],
    page: page,
    pageCount: 1,
  );

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 1, name: '电影片'),
    VideoCategory(id: 2, name: '伦理片'),
    VideoCategory(id: 3, name: '午夜剧场'),
    VideoCategory(id: 4, name: '国产动漫'),
  ];

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) =>
      throw UnimplementedError();

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

void main() {
  group('isBlockedCategoryName', () {
    test('blocks sensitive category names and variants', () {
      expect(isBlockedCategoryName('伦理片'), isTrue);
      expect(isBlockedCategoryName('午夜剧场'), isTrue);
      expect(isBlockedCategoryName('福利视频'), isTrue);
      expect(isBlockedCategoryName('擦边球合集'), isTrue);
    });

    test('allows normal categories without false positives', () {
      expect(isBlockedCategoryName('电影片'), isFalse);
      expect(isBlockedCategoryName('国产动漫'), isFalse);
      expect(isBlockedCategoryName('纪录片'), isFalse);
      expect(isBlockedCategoryName('理论'), isFalse);
      expect(isBlockedCategoryName('动作片'), isFalse);
      expect(isBlockedCategoryName(''), isFalse);
    });
  });

  group('VideoRepositoryImpl content filter', () {
    test('filters categories and videos when enabled', () async {
      final repo = VideoRepositoryImpl(adapterResolver: (_) => _FakeAdapter());
      final categories = await repo.fetchCategories(_source);
      expect(categories.map((c) => c.name), ['电影片', '国产动漫']);

      final page = await repo.fetchPage(_source);
      expect(page.items.map((v) => v.title), ['正常影片']);
    });

    test('returns everything when disabled', () async {
      final repo = VideoRepositoryImpl(
        adapterResolver: (_) => _FakeAdapter(),
        contentFilterEnabled: false,
      );
      final categories = await repo.fetchCategories(_source);
      expect(categories, hasLength(4));

      final page = await repo.fetchPage(_source);
      expect(page.items, hasLength(2));
    });
  });
}
