import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/app.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/features/splash/splash_page.dart';
import 'package:jive/data/download/download_providers.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _testSource = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
  featuredCategoryIds: {20, 30},
);

final _altSource = VodSource(
  id: 'alt',
  name: '备用源',
  baseUri: Uri.parse('https://alt.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
  featuredCategoryIds: {20, 30},
);

class _FakeRepository implements VideoRepository {
  static const video = Video(
    id: '1',
    title: '测试影片',
    typeId: 20,
    category: '电影片',
    remarks: 'HD',
  );
  static const altVideo = Video(
    id: '1',
    title: '备用源影片',
    typeId: 20,
    category: '电影片',
    remarks: 'HD',
    sourceId: 'alt',
  );
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => keyword == '不存在'
      ? const VideoPage(items: [], page: 1, pageCount: 1)
      : VideoPage(
          items: [source.id == 'alt' ? altVideo : video],
          page: 1,
          pageCount: 1,
        );
  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 20, name: '电影片'),
    VideoCategory(id: 30, name: '连续剧'),
  ];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => const Video(
    id: '1',
    title: '测试影片',
    typeId: 20,
    category: '电影片',
    remarks: 'HD',
    description: '完整简介',
    episodes: [
      Episode(id: '1', name: '第1集', url: 'https://example.com/1.m3u8'),
      Episode(id: '2', name: '第2集', url: 'https://example.com/2.m3u8'),
    ],
  );
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _TreeCategoryRepository extends _FakeRepository {
  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 1, name: '电影片'),
    VideoCategory(id: 6, name: '动作片', parentId: 1),
    VideoCategory(id: 7, name: '喜剧片', parentId: 1),
    VideoCategory(id: 36, name: '体育'),
  ];
}

final _testOverrides = [
  videoRepositoryProvider.overrideWithValue(_FakeRepository()),
  vodSourceRegistryProvider.overrideWith(
    (ref) async => VodSourceRegistry([_testSource, _altSource], {}),
  ),
  downloadTasksProvider.overrideWith(
    (ref) => Stream.value(const <DownloadTask>[]),
  ),
];

Future<void> _pumpReadyApp(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const JiveApp()),
  );
  await tester.pump();
  await tester.pump(splashMinHold);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('bottom navigation adapts sizing and opacity by device and tab', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);

    final nav = find.byKey(const ValueKey('floating-nav-bar'));
    final surface = find.byKey(const ValueKey('floating-nav-surface'));
    Text navLabel(String label) => tester.widget<Text>(
      find.descendant(of: nav, matching: find.text(label)),
    );
    Icon navIcon(IconData icon) => tester.widget<Icon>(
      find.descendant(of: nav, matching: find.byIcon(icon)),
    );

    expect(tester.getSize(nav).height, 64);
    expect(navLabel('首页').style?.fontSize, 12);
    expect(navIcon(Icons.home).size, 24);
    expect(
      tester.widget<Material>(surface).color,
      AppPalette.light.surface.withValues(
        alpha: AppPalette.light.navigationHomeAlpha,
      ),
    );

    await tester.tap(find.descendant(of: nav, matching: find.text('我的')));
    await tester.pump();
    expect(
      tester.widget<Material>(surface).color,
      AppPalette.light.surface.withValues(
        alpha: AppPalette.light.navigationPageAlpha,
      ),
    );

    tester.view.physicalSize = const Size(834, 1194);
    await tester.pump();
    expect(tester.getSize(nav).height, 72);
    expect(navLabel('我的').style?.fontSize, 13);
    expect(navIcon(Icons.person).size, 26);

    await tester.tap(find.descendant(of: nav, matching: find.text('首页')));
    await tester.pump();
    expect(
      tester.widget<Material>(surface).color,
      AppPalette.light.surface.withValues(
        alpha: AppPalette.light.navigationHomeAlpha,
      ),
    );
  });

  testWidgets('loads home content and opens the complete detail page', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Jive'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('测试影片'), findsOneWidget);
    await tester.tap(find.text('测试影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('视频详情'), findsOneWidget);
    expect(find.text('播放 第1集'), findsOneWidget);
    final detailScroll = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere(
          (state) =>
              state.position.axis == Axis.vertical &&
              state.position.maxScrollExtent > 0,
        );
    detailScroll.position.jumpTo(detailScroll.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('完整简介'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('switching the global source rebuilds and reloads home', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('测试影片'), findsOneWidget);
    await tester.tap(find.text('测试源 ▾'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('选择来源'), findsOneWidget);
    await tester.tap(find.text('备用源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('备用源影片'), findsOneWidget);
    expect(find.text('测试影片'), findsNothing);
    expect(find.text('备用源 ▾'), findsOneWidget);
  });

  testWidgets('source management page lists sources and checks health', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(find.text('播放源'), findsOneWidget);
    expect(find.text('更多设置'), findsOneWidget);
    await tester.tap(find.text('播放源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('资源站 2 · 高清站 0，点击可设为默认'), findsOneWidget);
    expect(find.text('资源站'), findsOneWidget);
    expect(find.text('高清站'), findsOneWidget);
    expect(find.text('尚未检测'), findsNWidgets(2));
    await tester.tap(find.text('检测全部'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('上次检测：成功'), findsNWidgets(2));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('source_health_storm'), contains('"ok":true'));
    expect(prefs.getString('source_health_alt'), contains('"ok":true'));
  });

  testWidgets('home category chip filters the grid in place', (tester) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(ChoiceChip, '电影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '电影片'))
          .selected,
      isTrue,
    );
    expect(find.text('测试影片'), findsOneWidget);
  });

  testWidgets('search debounces, displays results and clears input', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.tap(find.text('搜索'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('输入片名开始搜索'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '测试');
    await tester.pump(const Duration(milliseconds: 599));
    expect(find.text('测试影片'), findsNothing);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(find.text('测试影片'), findsOneWidget);
    await tester.tap(find.byTooltip('清空'));
    await tester.pump();
    expect(find.text('输入片名开始搜索'), findsOneWidget);
    expect(find.byTooltip('清空'), findsNothing);
  });

  testWidgets('search shows the no-result state', (tester) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.tap(find.text('搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump(const Duration(milliseconds: 601));
    await tester.pump();
    expect(find.text('没有找到结果，换个关键词或来源试试'), findsOneWidget);
  });

  testWidgets('home uses two-level category navigation', (tester) async {
    final container = ProviderContainer(
      overrides: [
        videoRepositoryProvider.overrideWithValue(_TreeCategoryRepository()),
        vodSourceRegistryProvider.overrideWith(
          (ref) async => VodSourceRegistry([
            VodSource(
              id: 'tree',
              name: '树形源',
              baseUri: Uri.parse(
                'https://tree.example.com/api.php/provide/vod',
              ),
              adapterType: 'mac_cms_v10',
            ),
          ], {}),
        ),
        downloadTasksProvider.overrideWith(
          (ref) => Stream.value(const <DownloadTask>[]),
        ),
      ],
    );
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump(const Duration(milliseconds: 500));
    // 初始只展示顶级分类 tab，子分类不展示。
    expect(find.widgetWithText(ChoiceChip, '电影片'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '体育'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '动作片'), findsNothing);
    // 选中带子分类的顶级分类：展示子分类横滑栏并自动选中第一个子分类。
    await tester.tap(find.widgetWithText(ChoiceChip, '电影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(ChoiceChip, '动作片'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '喜剧片'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '动作片'))
          .selected,
      isTrue,
    );
    expect(find.text('测试影片'), findsOneWidget);
    // 切换子分类。
    await tester.tap(find.widgetWithText(ChoiceChip, '喜剧片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '喜剧片'))
          .selected,
      isTrue,
    );
    // 选中无子级的顶级分类：直接按该分类查询，子分类栏收起。
    await tester.tap(find.widgetWithText(ChoiceChip, '体育'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(ChoiceChip, '动作片'), findsNothing);
    expect(find.text('测试影片'), findsOneWidget);
  });

  testWidgets(
    'history displays progress and can be cleared with confirmation',
    (tester) async {
      final record = WatchRecord(
        video: const Video(id: '1', title: '历史影片', category: '电影片'),
        episodeId: '1',
        episodeName: '第1集',
        positionMs: 65000,
        durationMs: 120000,
        updatedAt: DateTime(2026, 8, 12),
      );
      SharedPreferences.setMockInitialValues({
        'watch_history_v1': jsonEncode([record.toJson()]),
      });
      final container = ProviderContainer(overrides: _testOverrides);
      await container.read(vodSourceRegistryProvider.future);
      addTearDown(container.dispose);
      await _pumpReadyApp(tester, container);
      await tester.tap(find.text('我的'));
      await tester.pump();
      await tester.tap(find.text('最近观看'));
      await tester.pumpAndSettle();
      expect(find.text('历史影片'), findsOneWidget);
      expect(find.text('继续 第1集 · 1:05'), findsOneWidget);
      final metadataBottom = tester.getBottomLeft(find.text('电影片')).dy;
      final resumeTop = tester.getTopLeft(find.text('继续 第1集 · 1:05')).dy;
      expect(resumeTop - metadataBottom, lessThanOrEqualTo(8));
      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(find.text('清空观看记录？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('还没有观看记录\n播放视频后可以从这里继续'), findsOneWidget);
    },
  );

  testWidgets('home continue watching dismisses for the session only', (
    tester,
  ) async {
    final record = WatchRecord(
      video: const Video(id: '1', title: '历史影片', category: '电影片'),
      episodeId: '1',
      episodeName: '正片',
      positionMs: 65000,
      durationMs: 120000,
      updatedAt: DateTime(2026, 8, 12),
    );
    SharedPreferences.setMockInitialValues({
      'watch_history_v1': jsonEncode([record.toJson()]),
    });
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('continue-watching-bar')), findsOneWidget);
    expect(find.text('继续 正片 · 1:05'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('continue-watching-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('continue-watching-bar')), findsNothing);
    expect(find.text('删除观看记录？'), findsNothing);
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.tap(find.text('最近观看'));
    await tester.pumpAndSettle();
    expect(find.text('历史影片'), findsOneWidget);
  });

  testWidgets('home hides continue watching after opening another video', (
    tester,
  ) async {
    final record = WatchRecord(
      video: const Video(id: '99', title: '历史影片', category: '连续剧'),
      episodeId: '1',
      episodeName: '第1集',
      positionMs: 10000,
      durationMs: 10000,
      updatedAt: DateTime(2026, 8, 12),
      completed: true,
    );
    SharedPreferences.setMockInitialValues({
      'watch_history_v1': jsonEncode([record.toJson()]),
    });
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('continue-watching-bar')), findsOneWidget);
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('continue-watching-bar')), findsOneWidget);
    await tester.tap(find.text('测试影片'));
    await tester.pump();
    expect(find.byKey(const ValueKey('continue-watching-bar')), findsNothing);
  });

  testWidgets('home hides movies past two thirds watched', (tester) async {
    final record = WatchRecord(
      video: const Video(id: '1', title: '快看完的电影', category: '电影片'),
      episodeId: '1',
      episodeName: '正片',
      positionMs: 80000,
      durationMs: 100000,
      updatedAt: DateTime(2026, 8, 12),
    );
    SharedPreferences.setMockInitialValues({
      'watch_history_v1': jsonEncode([record.toJson()]),
    });
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('continue-watching-bar')), findsNothing);
    expect(find.text('快看完的电影'), findsNothing);
  });

  testWidgets('profile history can delete a single record', (tester) async {
    final keep = WatchRecord(
      video: const Video(id: '1', title: '留下的影片', category: '电影片'),
      episodeId: '1',
      episodeName: '第1集',
      positionMs: 10000,
      durationMs: 120000,
      updatedAt: DateTime(2026, 8, 12),
    );
    final remove = WatchRecord(
      video: const Video(id: '2', title: '删掉的影片', category: '电影片'),
      episodeId: '1',
      episodeName: '第2集',
      positionMs: 20000,
      durationMs: 120000,
      updatedAt: DateTime(2026, 8, 11),
    );
    SharedPreferences.setMockInitialValues({
      'watch_history_v1': jsonEncode([keep.toJson(), remove.toJson()]),
    });
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.tap(find.text('最近观看'));
    await tester.pumpAndSettle();
    expect(find.text('留下的影片'), findsOneWidget);
    expect(find.text('删掉的影片'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('history-delete-${remove.video.globalId}')),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump();
    expect(find.text('留下的影片'), findsOneWidget);
    expect(find.text('删掉的影片'), findsNothing);
  });

  testWidgets('search remembers submitted keywords', (tester) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpReadyApp(tester, container);
    await tester.tap(find.text('搜索'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('输入片名开始搜索'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    expect(find.text('测试影片'), findsOneWidget);
    await tester.tap(find.byTooltip('清空'));
    await tester.pump();
    expect(find.text('最近搜索'), findsOneWidget);
    expect(find.text('测试'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('search-history-测试')));
    await tester.pump();
    expect(find.text('测试影片'), findsOneWidget);
  });
}
