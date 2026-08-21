import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/vod_source_adapter.dart';
import 'package:jive/data/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _testSource = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

class _EmptyCategoryAdapter implements VodSourceAdapter {
  @override
  String get adapterType => 'mac_cms_v10';

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    if (categoryId == 2) {
      return const VideoPage(items: [], page: 1, pageCount: 1);
    }
    return VideoPage(
      items: [
        for (var i = 0; i < 3; i++)
          Video(id: '$i', title: '影片$i', typeId: categoryId ?? 1),
      ],
      page: page,
      pageCount: 1,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 1, name: '电影'),
    VideoCategory(id: 2, name: '电视剧'),
    VideoCategory(id: 3, name: '动作片'),
  ];

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) =>
      throw UnimplementedError();

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

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
    items: [
      for (var i = 0; i < 10; i++)
        Video(id: '$i', title: '正常影片$i', typeId: 1, category: '电影片'),
      const Video(id: 'x', title: '敏感影片', typeId: 2, category: '伦理片'),
    ],
    page: page,
    pageCount: 99,
  );

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 1, name: '电影片'),
    VideoCategory(id: 2, name: '伦理片'),
  ];

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) =>
      throw UnimplementedError();

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpHome(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        vodSourceRegistryProvider.overrideWith(
          (ref) async =>
              VodSourceRegistry([_testSource], {'mac_cms_v10': _FakeAdapter()}),
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

  testWidgets('empty categories are hidden after the first-page probe', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        vodSourceRegistryProvider.overrideWith(
          (ref) async => VodSourceRegistry(
            [_testSource],
            {'mac_cms_v10': _EmptyCategoryAdapter()},
          ),
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
    expect(find.widgetWithText(ChoiceChip, '电影'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '动作片'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '电视剧'), findsNothing);
  });

  testWidgets('sensitive categories are hidden by default', (tester) async {
    await pumpHome(tester);
    expect(find.widgetWithText(ChoiceChip, '电影片'), findsOneWidget);
    expect(find.text('伦理片'), findsNothing);
    expect(find.text('正常影片0'), findsOneWidget);
  });

  testWidgets('long-press Jive title toggles the content filter', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.text('伦理片'), findsNothing);

    // 关闭过滤。
    await tester.longPress(find.text('Jive'));
    await tester.pumpAndSettle();
    expect(find.text('关闭内容过滤？'), findsOneWidget);
    await tester.tap(find.text('关闭过滤'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('content_filter_enabled'), isFalse);
    expect(find.widgetWithText(ChoiceChip, '伦理片'), findsOneWidget);

    // 重新开启过滤。
    await tester.longPress(find.text('Jive'));
    await tester.pumpAndSettle();
    expect(find.text('开启内容过滤？'), findsOneWidget);
    await tester.tap(find.text('开启过滤'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));

    expect(prefs.getBool('content_filter_enabled'), isTrue);
    expect(find.text('伦理片'), findsNothing);
  });
}
