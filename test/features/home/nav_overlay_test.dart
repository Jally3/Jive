import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/app.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/home/home_page.dart';
import 'package:jive/shared/video_card.dart';
import 'package:jive/shared/video_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _testSource = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

class _FakeRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: List.generate(
      20,
      (i) => Video(id: '$i', title: '影片$i', typeId: 1, category: '电影片'),
    ),
    page: page,
    pageCount: 99,
  );
  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 1, name: '电影片'),
  ];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => const Video(id: '1', title: 't', typeId: 1, category: 'c');
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _EmptyRepository extends _FakeRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => const VideoPage(items: [], page: 1, pageCount: 1);
}

class _ManyCategoryRepository extends _FakeRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return super.fetchPage(
      source,
      page: page,
      categoryId: categoryId,
      keyword: keyword,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      List.generate(
        12,
        (index) => VideoCategory(id: index + 1, name: '分类$index'),
      );
}

class _ManyNestedCategoryRepository extends _ManyCategoryRepository {
  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [
    const VideoCategory(id: 100, name: '电影'),
    ...List.generate(
      12,
      (index) => VideoCategory(id: index + 1, name: '子分类$index', parentId: 100),
    ),
  ];
}

Future<void> _pumpHome(
  WidgetTester tester, {
  VideoRepository? repository,
}) async {
  final container = ProviderContainer(
    overrides: [
      videoRepositoryProvider.overrideWithValue(
        repository ?? _FakeRepository(),
      ),
      vodSourceRegistryProvider.overrideWith(
        (ref) async => VodSourceRegistry([_testSource], {}),
      ),
    ],
  );
  await container.read(vodSourceRegistryProvider.future);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const JiveApp()),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _pumpBareEmptyHome(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      videoRepositoryProvider.overrideWithValue(_EmptyRepository()),
      vodSourceRegistryProvider.overrideWith(
        (ref) async => VodSourceRegistry([_testSource], {}),
      ),
    ],
  );
  await container.read(vodSourceRegistryProvider.future);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: HomePage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

ScrollableState _homeScrollState(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(VideoGrid),
        matching: find.byType(Scrollable),
      ),
    )
    .firstWhere((state) => state.position.axis == Axis.vertical);

ScrollableState _rootTabScrollState(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('home-category-header')),
        matching: find.byType(Scrollable),
      ),
    )
    .firstWhere((state) => state.position.axis == Axis.horizontal);

ScrollableState _leafTabScrollState(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('home-category-header')),
        matching: find.byType(Scrollable),
      ),
    )
    .where((state) => state.position.axis == Axis.horizontal)
    .last;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home grid extends behind the floating nav bar', (tester) async {
    await _pumpHome(tester);

    final grid = tester.getRect(find.byType(VideoGrid));
    final scaffold = tester.getRect(find.byType(Scaffold).first);
    // ignore: avoid_print
    print('grid: $grid scaffold: $scaffold');
    expect(grid.bottom, scaffold.bottom);
  });

  testWidgets('home category header stays aligned and pins with the grid', (
    tester,
  ) async {
    await _pumpHome(tester);
    final latestChip = find.widgetWithText(ChoiceChip, '最新');
    final firstCard = find.byType(VideoCard).first;
    final scrollState = _homeScrollState(tester);
    final initialGap =
        tester.getTopLeft(firstCard).dy - tester.getBottomLeft(latestChip).dy;

    scrollState.position.jumpTo(70);
    await tester.pump();
    final scrollingGap =
        tester.getTopLeft(firstCard).dy - tester.getBottomLeft(latestChip).dy;
    expect(scrollingGap, closeTo(initialGap, 0.01));

    scrollState.position.jumpTo(170);
    await tester.pump();
    final pinnedTop = tester
        .getTopLeft(find.byKey(const ValueKey('home-category-header')))
        .dy;
    scrollState.position.jumpTo(300);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('home-category-header'))).dy,
      closeTo(pinnedTop, 0.01),
    );
  });

  testWidgets('switching a home category resets the grid to the top', (
    tester,
  ) async {
    await _pumpHome(tester);
    final scrollState = _homeScrollState(tester);
    scrollState.position.jumpTo(900);
    await tester.pump();
    expect(scrollState.position.pixels, closeTo(900, 0.01));

    await tester.tap(find.widgetWithText(ChoiceChip, '电影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_homeScrollState(tester).position.pixels, 0);
  });

  testWidgets('home category header grows with accessibility text scaling', (
    tester,
  ) async {
    tester.binding.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    await _pumpBareEmptyHome(tester);

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('home-category-header'))).height,
      greaterThan(57),
    );
  });

  testWidgets('selecting a far-right category keeps the tab strip position', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpHome(tester, repository: _ManyCategoryRepository());

    final beforeState = _rootTabScrollState(tester);
    beforeState.position.jumpTo(beforeState.position.maxScrollExtent);
    await tester.pump();
    final offset = beforeState.position.pixels;
    expect(offset, greaterThan(0));

    await tester.tap(find.widgetWithText(ChoiceChip, '分类11'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_rootTabScrollState(tester).position.pixels, closeTo(offset, 0.01));
  });

  testWidgets('selecting a far-right leaf keeps the sub-tab strip position', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpHome(tester, repository: _ManyNestedCategoryRepository());

    await tester.tap(find.widgetWithText(ChoiceChip, '电影'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final beforeState = _leafTabScrollState(tester);
    beforeState.position.jumpTo(beforeState.position.maxScrollExtent);
    await tester.pump();
    final offset = beforeState.position.pixels;
    expect(offset, greaterThan(0));

    await tester.tap(find.widgetWithText(ChoiceChip, '子分类11'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_leafTabScrollState(tester).position.pixels, closeTo(offset, 0.01));
  });
}
