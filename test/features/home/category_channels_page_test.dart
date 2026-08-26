import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/features/home/category_channels_page.dart';

const _roots = [
  VideoCategory(id: 1, name: '电影片'),
  VideoCategory(id: 2, name: '连续剧'),
  VideoCategory(id: 3, name: '综艺片'),
  VideoCategory(id: 4, name: '动漫片'),
];

const _children = {
  1: [
    VideoCategory(id: 11, name: '动作片', parentId: 1),
    VideoCategory(id: 12, name: '喜剧片', parentId: 1),
    VideoCategory(id: 13, name: '爱情片', parentId: 1),
    VideoCategory(id: 14, name: '科幻片', parentId: 1),
  ],
  2: [
    VideoCategory(id: 21, name: '国产剧', parentId: 2),
    VideoCategory(id: 22, name: '香港剧', parentId: 2),
  ],
};

Widget _page() => CategoryChannelsPage(
  roots: _roots,
  children: _children,
  myChannelIds: const [1, 2, 3, 4],
  selectedRootId: null,
  selectedCategoryId: null,
  onSelectRoot: (_) {},
  onSelectLeaf: (_, _) {},
  onAddRoot: (_) {},
  onRemoveRoot: (_) {},
  onReorder: (_) {},
  onReset: () {},
);

Future<void> _pumpAt(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: _page()));
}

SliverGridDelegateWithFixedCrossAxisCount _firstGridDelegate(
  WidgetTester tester,
) {
  final grid = tester.widget<GridView>(find.byType(GridView).first);
  return grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
}

void main() {
  group('CategoryChannelsLayout', () {
    test('phone portrait stays 4 columns with 2.4 aspect', () {
      final layout = CategoryChannelsLayout.resolve(
        viewportWidth: 390,
        shortestSide: 390,
      );
      expect(layout.isTablet, isFalse);
      expect(layout.columns, 4);
      expect(layout.padding, 16);
      expect(layout.spacing, 8);
      expect(layout.contentWidth, 390);
      expect(layout.childAspectRatio, closeTo(2.4, 0.01));
    });

    test('iPad 11 portrait uses 6 compact columns', () {
      final layout = CategoryChannelsLayout.resolve(
        viewportWidth: 834,
        shortestSide: 834,
      );
      expect(layout.isTablet, isTrue);
      expect(layout.columns, 6);
      expect(layout.padding, 24);
      expect(layout.spacing, 12);
      expect(layout.contentWidth, 834);
      final available = 834 - 24 * 2 - 12 * 5;
      final cellWidth = available / 6;
      expect(layout.childAspectRatio, closeTo(cellWidth / 48, 0.01));
    });

    test('iPad landscape caps content width at 1100', () {
      final layout = CategoryChannelsLayout.resolve(
        viewportWidth: 1210,
        shortestSide: 834,
      );
      expect(layout.isTablet, isTrue);
      expect(layout.contentWidth, 1100);
      expect(layout.columns, 8);
    });

    test('very wide viewport never exceeds 8 columns', () {
      final layout = CategoryChannelsLayout.resolve(
        viewportWidth: 1920,
        shortestSide: 1080,
      );
      expect(layout.columns, 8);
      expect(layout.contentWidth, 1100);
    });
  });

  group('CategoryChannelsPage grid', () {
    testWidgets('phone portrait grid is 4 columns', (tester) async {
      await _pumpAt(tester, size: const Size(390, 844));
      expect(_firstGridDelegate(tester).crossAxisCount, 4);
      expect(find.text('全部频道'), findsOneWidget);
      expect(find.text('我的频道'), findsOneWidget);
    });

    testWidgets('iPad portrait grid is 6 columns and does not stretch pills', (
      tester,
    ) async {
      await _pumpAt(tester, size: const Size(834, 1210));
      final delegate = _firstGridDelegate(tester);
      expect(delegate.crossAxisCount, 6);
      expect(delegate.mainAxisSpacing, 12);
      expect(delegate.crossAxisSpacing, 12);

      final pill = tester.getSize(find.text('最新'));
      // 胶囊本身只有文字尺寸；其父网格格高应接近 48，而不是 4 列时的 ~80。
      final grid = tester.getSize(find.byType(GridView).first);
      final rowHeight = (grid.width - 12 * 5) / 6 / delegate.childAspectRatio;
      expect(rowHeight, closeTo(48, 0.5));
      expect(pill.height, lessThan(rowHeight));
    });

    testWidgets('iPad landscape keeps the page content column under 1100', (
      tester,
    ) async {
      await _pumpAt(tester, size: const Size(1210, 834));
      final page = tester.getSize(
        find.byKey(const ValueKey('category-channels-page')),
      );
      expect(page.width, 1210);
      final grid = tester.getSize(find.byType(GridView).first);
      // 1100 内容宽 - 左右 24 padding。
      expect(grid.width, closeTo(1052, 0.5));
      expect(_firstGridDelegate(tester).crossAxisCount, 8);
    });
  });
}
