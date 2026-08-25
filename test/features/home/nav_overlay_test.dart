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

/// 「全部频道」页面的滚动容器内，先把目标滚进可视区再点。
Future<void> _scrollPanelUntilVisible(WidgetTester tester, Finder target) {
  final scrollView = find.descendant(
    of: find.byKey(const ValueKey('category-channels-page')),
    matching: find.byType(SingleChildScrollView),
  );
  return tester.scrollUntilVisible(
    target,
    120,
    scrollable: find
        .descendant(of: scrollView, matching: find.byType(Scrollable))
        .first,
  );
}

/// 点分类栏右侧按钮打开「全部频道」页面，并等路由动画完成。
Future<void> _openChannelsPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('home-category-expand-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// 点 X 关闭「全部频道」页面。页面盖住时首页 offstage（finder 默认跳过），
/// tab 行的断言必须在关闭页面之后进行。
Future<void> _closeChannelsPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('category-channels-close')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

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

  testWidgets('expand button opens the all-channels page', (tester) async {
    await _pumpHome(tester, repository: _ManyNestedCategoryRepository());
    expect(find.byKey(const ValueKey('category-channels-page')), findsNothing);

    await _openChannelsPage(tester);

    final page = find.byKey(const ValueKey('category-channels-page'));
    expect(page, findsOneWidget);
    expect(
      find.descendant(of: page, matching: find.text('最新')),
      findsOneWidget,
    );
    // 子分类按所属主分类分组展示；「电影」出现在我的频道网格和分组区头两处。
    expect(find.descendant(of: page, matching: find.text('电影')), findsWidgets);
    expect(
      find.descendant(of: page, matching: find.text('子分类5')),
      findsOneWidget,
    );
  });

  testWidgets('selecting a leaf in the page pops it and applies selection', (
    tester,
  ) async {
    await _pumpHome(tester, repository: _ManyNestedCategoryRepository());
    await _openChannelsPage(tester);

    final page = find.byKey(const ValueKey('category-channels-page'));
    final target = find.descendant(of: page, matching: find.text('子分类5'));
    await _scrollPanelUntilVisible(tester, target);
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('category-channels-page')), findsNothing);
    // 选中后主分类切到「电影」，子分类行出现且「子分类5」为选中态。
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '子分类5'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('selecting a childless root in the page selects that category', (
    tester,
  ) async {
    await _pumpHome(tester, repository: _ManyCategoryRepository());
    await _openChannelsPage(tester);

    final page = find.byKey(const ValueKey('category-channels-page'));
    // 「分类3」在页面里出现两处（我的频道网格 + 自身分组），点任一均可选中。
    await tester.tap(
      find.descendant(of: page, matching: find.text('分类3')).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('category-channels-page')), findsNothing);
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '分类3'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('edit mode removes a channel from my channels and persists', (
    tester,
  ) async {
    await _pumpHome(tester, repository: _ManyCategoryRepository());
    await _openChannelsPage(tester);

    final page = find.byKey(const ValueKey('category-channels-page'));
    await tester.tap(find.descendant(of: page, matching: find.text('编辑')));
    await tester.pump();

    // 编辑态点我的频道里的「分类0」（id 1）移除它。
    await tester.tap(
      find.descendant(of: page, matching: find.text('分类0')).first,
    );
    await tester.pump();

    await _closeChannelsPage(tester);

    // tab 行的 chip 消失。
    expect(find.widgetWithText(ChoiceChip, '分类0'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('home_my_channels_storm'), isNot(contains('1')));
  });

  testWidgets('edit mode adds a hidden channel back to the tab row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'home_my_channels_storm': ['1', '2', '3'],
    });
    await _pumpHome(tester, repository: _ManyCategoryRepository());
    // 定制生效：tab 行只保留前三个分类。
    expect(find.widgetWithText(ChoiceChip, '分类3'), findsNothing);

    await _openChannelsPage(tester);
    final page = find.byKey(const ValueKey('category-channels-page'));
    await tester.tap(find.descendant(of: page, matching: find.text('编辑')));
    await tester.pump();

    // 第一个「+ 添加」属于「分类3」（id 4）的分组区头。
    final addAction = find
        .descendant(of: page, matching: find.text('+ 添加'))
        .first;
    await _scrollPanelUntilVisible(tester, addAction);
    await tester.tap(addAction);
    await tester.pump();
    await _closeChannelsPage(tester);

    expect(find.widgetWithText(ChoiceChip, '分类3'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('home_my_channels_storm'), contains('4'));
  });

  testWidgets('edit mode drag reorders my channels and persists the order', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'home_my_channels_storm': ['1', '2', '3', '4'],
    });
    await _pumpHome(tester, repository: _ManyCategoryRepository());
    await _openChannelsPage(tester);

    final page = find.byKey(const ValueKey('category-channels-page'));
    await tester.tap(find.descendant(of: page, matching: find.text('编辑')));
    await tester.pump();

    // 长按「分类0」（id 1）拖到「分类2」（id 3）的位置。
    // key 同时挂在 ReorderableItemView 与内部 pill 上，取 .first（外层）。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('my-channel-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('my-channel-3')).first),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    // 顺序持久化：「分类0」被移到了「分类1」「分类2」之后。
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('home_my_channels_storm');
    expect(ids, isNotNull);
    expect(ids!.length, 4);
    expect(ids.indexOf('1'), greaterThan(ids.indexOf('3')));
  });

  testWidgets('reset restores all channels and clears the saved record', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'home_my_channels_storm': ['1', '2'],
    });
    await _pumpHome(tester, repository: _ManyCategoryRepository());
    // 定制后「分类2」（id 3）不在 tab 行。
    expect(find.widgetWithText(ChoiceChip, '分类2'), findsNothing);

    await _openChannelsPage(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('category-channels-page')),
        matching: find.text('恢复默认'),
      ),
    );
    await tester.pump();
    await _closeChannelsPage(tester);

    // 恢复后回到 tab 行（用靠前的分类断言：横滑列表是懒构建，屏幕外的不在树里）。
    expect(find.widgetWithText(ChoiceChip, '分类2'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('home_my_channels_storm'), isNull);
  });

  testWidgets('close button pops the page', (tester) async {
    await _pumpHome(tester, repository: _ManyNestedCategoryRepository());
    await _openChannelsPage(tester);
    expect(
      find.byKey(const ValueKey('category-channels-page')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('category-channels-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('category-channels-page')), findsNothing);
  });
}
