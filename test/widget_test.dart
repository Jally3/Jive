import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/app.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('loads home content and opens the complete detail page', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoRepositoryProvider.overrideWithValue(_FakeRepository()),
        ],
        child: const JiveApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Jive'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('测试影片'), findsOneWidget);
    await tester.tap(find.text('测试影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('视频详情'), findsOneWidget);
    expect(find.text('完整简介'), findsOneWidget);
    expect(find.text('播放 第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('home category entry switches to filtered category tab', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoRepositoryProvider.overrideWithValue(_FakeRepository()),
        ],
        child: const JiveApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(ActionChip, '电影'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('分类'), findsWidgets);
    expect(find.widgetWithText(ChoiceChip, '电影片'), findsOneWidget);
  });

  testWidgets('search debounces, displays results and clears input', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoRepositoryProvider.overrideWithValue(_FakeRepository()),
        ],
        child: const JiveApp(),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('搜索'));
    await tester.pump();
    expect(find.text('输入片名开始搜索'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '测试');
    await tester.pump(const Duration(milliseconds: 399));
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoRepositoryProvider.overrideWithValue(_FakeRepository()),
        ],
        child: const JiveApp(),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump(const Duration(milliseconds: 401));
    await tester.pump();
    expect(find.text('没有找到结果，换个关键词试试'), findsOneWidget);
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
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoRepositoryProvider.overrideWithValue(_FakeRepository()),
          ],
          child: const JiveApp(),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('最近观看'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('历史影片'), findsOneWidget);
      expect(find.text('继续 第1集 · 1:05'), findsOneWidget);
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

class _FakeRepository implements VideoRepository {
  static const video = Video(
    id: '1',
    title: '测试影片',
    typeId: 20,
    category: '电影片',
    remarks: 'HD',
  );
  @override
  Future<VideoPage> fetchPage({
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => keyword == '不存在'
      ? const VideoPage(items: [], page: 1, pageCount: 1)
      : const VideoPage(items: [video], page: 1, pageCount: 1);
  @override
  Future<List<VideoCategory>> fetchCategories() async => const [
    VideoCategory(id: 20, name: '电影片'),
    VideoCategory(id: 30, name: '连续剧'),
  ];
  @override
  Future<Video> fetchDetail(
    String videoId, {
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
  Future<Video> resolvePlayback(String videoId) => fetchDetail(videoId);
}
