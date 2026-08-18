import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/app.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/data/cache/download_providers.dart';
import 'package:jive/data/cache/download_task_manager.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source_registry.dart';
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

final _testOverrides = [
  videoRepositoryProvider.overrideWithValue(_FakeRepository()),
  vodSourceRegistryProvider.overrideWith(
    (ref) async => VodSourceRegistry([_testSource, _altSource], {}),
  ),
  downloadTasksProvider.overrideWith(
    (ref) => Stream.value(const <DownloadTask>[]),
  ),
];

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
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();

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
      AppColors.surface.withValues(alpha: 0.3),
    );

    await tester.tap(find.descendant(of: nav, matching: find.text('我的')));
    await tester.pump();
    expect(
      tester.widget<Material>(surface).color,
      AppColors.surface.withValues(alpha: 0.78),
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
      AppColors.surface.withValues(alpha: 0.3),
    );
  });

  testWidgets('loads home content and opens the complete detail page', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Jive'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('测试影片'), findsOneWidget);
    await tester.tap(find.text('测试影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('视频详情'), findsOneWidget);
    expect(find.text('完整简介'), findsOneWidget);
    expect(find.text('播放 第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('switching the global source rebuilds and reloads home', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: _testOverrides);
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
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
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(find.text('播放源'), findsOneWidget);
    expect(find.text('更多设置'), findsOneWidget);
    await tester.tap(find.text('播放源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('共 2 个来源，点击可设为默认'), findsOneWidget);
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
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
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
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
    await tester.tap(find.text('搜索'));
    await tester.pump();
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
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
    await tester.tap(find.text('搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump(const Duration(milliseconds: 601));
    await tester.pump();
    expect(find.text('没有找到结果，换个关键词或来源试试'), findsOneWidget);
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
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const JiveApp()),
      );
      await tester.pump();
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
}
