import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/category_nav.dart';
import 'package:jive/domain/video.dart';

void main() {
  const movie = VideoCategory(id: 1, name: '电影');
  const action = VideoCategory(id: 6, name: '动作片', parentId: 1);
  const comedy = VideoCategory(id: 7, name: '喜剧片', parentId: 1);
  const sport = VideoCategory(id: 36, name: '体育');

  test('buildCategoryNav splits roots and children', () {
    final nav = buildCategoryNav(const [movie, action, comedy, sport]);
    expect(nav.roots.map((item) => item.name), ['电影', '体育']);
    expect(nav.children[1]!.map((item) => item.name), ['动作片', '喜剧片']);
    expect(categoryIdsToProbe(nav), [36, 6, 7]);
  });

  test('featured ids keep only matching roots when any match', () {
    final nav = buildCategoryNav(
      const [movie, action, comedy, sport],
      featuredIds: {1},
    );
    expect(nav.roots.map((item) => item.name), ['电影']);
    expect(categoryIdsToProbe(nav), [6, 7]);
  });

  test('hides empty childless roots used as tabs', () {
    final nav = hideEmptyCategories(
      buildCategoryNav(const [
        VideoCategory(id: 1, name: '电影'),
        VideoCategory(id: 2, name: '电视剧'),
        VideoCategory(id: 6, name: '动作片'),
      ]),
      {1, 2},
    );
    expect(nav.roots.map((item) => item.name), ['动作片']);
    expect(nav.children, isEmpty);
  });

  test('hides a parent when every child is empty', () {
    final nav = hideEmptyCategories(
      buildCategoryNav(const [movie, action, comedy, sport]),
      {6, 7},
    );
    expect(nav.roots.map((item) => item.name), ['体育']);
    expect(nav.children, isEmpty);
  });

  test('keeps a parent when at least one child has content', () {
    final nav = hideEmptyCategories(
      buildCategoryNav(const [movie, action, comedy]),
      {7},
    );
    expect(nav.roots.map((item) => item.name), ['电影']);
    expect(nav.children[1]!.map((item) => item.name), ['动作片']);
  });

  test('findEmptyCategoryIds returns ids whose first page is empty', () async {
    final empty = await findEmptyCategoryIds(
      ids: const [1, 2, 3],
      fetchPage: (id) async => VideoPage(
        items: [if (id != 2) const Video(id: '1', title: '有内容')],
        page: 1,
        pageCount: 1,
      ),
    );
    expect(empty, {2});
  });

  test('findEmptyCategoryIds keeps a category when the probe fails', () async {
    final empty = await findEmptyCategoryIds(
      ids: const [1],
      fetchPage: (id) async => throw Exception('network'),
    );
    expect(empty, isEmpty);
  });
}
