import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:jive/app/theme.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/data/download/download_network_policy.dart';
import 'package:jive/data/download/download_providers.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/features/download/download_management_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDiskSpace implements DiskSpaceProvider {
  @override
  Future<int> availableBytes() async => 20 * (1 << 30);

  @override
  Future<int?> platformCacheLimitBytes() async => null;

  @override
  Future<int?> totalCapacityBytes() async => 64 * (1 << 30);
}

DownloadTask _task(
  String id,
  DownloadTaskStatus status, {
  String episode = '第1集',
  String title = '测试影片',
  int expectedResourceCount = 100,
  int completedResourceCount = 40,
  int totalBytes = 500 * 1024 * 1024,
  int downloadedBytes = 200 * 1024 * 1024,
  int speedBytesPerSecond = 1024 * 1024,
  DownloadPauseReason? pauseReason,
}) => DownloadTask(
  taskId: id,
  sourceId: 's',
  sourceVideoId: 'v',
  title: title,
  playbackLineIdentity: 'line',
  episodeIdentity: 'ep$id',
  episodeId: id,
  episodeName: episode,
  status: status,
  expectedResourceCount: expectedResourceCount,
  completedResourceCount: completedResourceCount,
  totalBytes: totalBytes,
  downloadedBytes: downloadedBytes,
  speedBytesPerSecond: speedBytesPerSecond,
  pauseReason: pauseReason,
  error: status == DownloadTaskStatus.failed
      ? DownloadFailureReason.network
      : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('download page renders all statuses without overflow', (
    tester,
  ) async {
    final tasks = [
      _task('1', DownloadTaskStatus.downloading, episode: '第1集'),
      _task('2', DownloadTaskStatus.paused, episode: '第2集'),
      _task('3', DownloadTaskStatus.completed, episode: '第3集'),
      _task('4', DownloadTaskStatus.failed, episode: '第4集'),
      _task('5', DownloadTaskStatus.queued, episode: '第5集'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => Stream.value(tasks)),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('下载管理'), findsOneWidget);
    expect(find.text('全部暂停'), findsOneWidget);
    expect(find.text('未完成 3'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '未完成 3'))
          .selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(ChoiceChip, '全部 5'));
    await tester.pumpAndSettle();
    expect(find.text('整体进度'), findsNothing);
    expect(find.text('失败/取消'), findsNothing);
    expect(find.text('5 集 · 完成 1 集'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('第1集')).dx,
      greaterThan(tester.getTopLeft(find.text('测试影片')).dx),
    );
    expect(
      tester.widget<Text>(find.text('测试影片')).style?.fontWeight,
      FontWeight.w700,
    );
    expect(
      tester.widget<Text>(find.text('第1集')).style?.fontWeight,
      FontWeight.w600,
    );
    expect(find.text('下载中'), findsNothing);
    expect(find.text('已暂停'), findsNothing);
    expect(find.text('已完成'), findsNothing);
    expect(find.text('失败'), findsNothing);
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(find.byTooltip('继续'), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);
    final pauseAll = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('全部暂停'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
    );
    expect(pauseAll.style?.foregroundColor?.resolve({}), AppPalette.dark.text);
    final resumeAll = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('全部继续'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
    );
    expect(resumeAll.style?.foregroundColor?.resolve({}), AppPalette.dark.text);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    expect(
      tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .map((indicator) => indicator.color),
      everyElement(AppPalette.dark.accent),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('download-task-row-1')),
        matching: find.text('速度 1.0 MB/s'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('download-task-row-3')),
        matching: find.textContaining('速度'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('download-task-row-2')),
        matching: find.textContaining('速度'),
      ),
      findsNothing,
    );
    for (final id in ['1', '2', '3', '4', '5']) {
      expect(
        tester
            .widget<InkWell>(find.byKey(ValueKey('download-task-row-$id')))
            .onTap,
        isNotNull,
      );
    }
    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('删除任务记录'), findsNothing);

    // 切换筛选
    await tester.tap(find.text('异常 1'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('重试'), findsOneWidget);

    // 进入编辑态
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('phone layout keeps summary and long task metadata readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tasks = [
      _task(
        '1',
        DownloadTaskStatus.downloading,
        episode: '第123集特别篇',
        title: '这是一部名称很长的测试影片',
        totalBytes: 0,
        downloadedBytes: 188 * 1024 * 1024,
        expectedResourceCount: 293,
        completedResourceCount: 181,
      ),
      _task('2', DownloadTaskStatus.paused, episode: '第2集'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => Stream.value(tasks)),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('全部继续'), findsOneWidget);
    expect(find.text('全部暂停'), findsOneWidget);
    expect(find.text('62% · 188 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-pause-1')), findsOneWidget);
    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('删除任务记录'), findsNothing);
  });

  testWidgets('completed-only downloads default to the completed filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value([_task('1', DownloadTaskStatus.completed)]),
          ),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '已完成 1'))
          .selected,
      isTrue,
    );
  });

  testWidgets('select all button toggles all visible tasks', (tester) async {
    final tasks = [
      _task('1', DownloadTaskStatus.downloading, episode: '第1集'),
      _task('2', DownloadTaskStatus.paused, episode: '第2集'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => Stream.value(tasks)),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前筛选结果'));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.byTooltip('取消全选'), findsOneWidget);
    expect(
      tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .map((item) => item.value),
      everyElement(isTrue),
    );

    await tester.tap(find.byTooltip('取消全选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 0 项'), findsOneWidget);
    expect(find.byTooltip('全选当前筛选结果'), findsOneWidget);
    expect(
      tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .map((item) => item.value),
      everyElement(isFalse),
    );
  });

  testWidgets('paused task with unknown size uses a static empty progress', (
    tester,
  ) async {
    final paused = _task(
      '1',
      DownloadTaskStatus.paused,
      expectedResourceCount: 0,
      completedResourceCount: 0,
      totalBytes: 0,
      downloadedBytes: 0,
      speedBytesPerSecond: 0,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => Stream.value([paused])),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试影片'));
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('等待继续'), findsOneWidget);
  });

  testWidgets('an active group can stay manually collapsed', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value([_task('1', DownloadTaskStatus.downloading)]),
          ),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第1集'), findsOneWidget);

    await tester.tap(find.text('测试影片').first);
    await tester.pumpAndSettle();

    expect(find.text('第1集'), findsNothing);
  });

  testWidgets('waiting Wi-Fi asks before a one-time cellular resume', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'jive_download_page_cellular_test',
    );
    final store = CacheIndexStore(directory);
    final cache = CacheManager(store: store, diskSpace: _FakeDiskSpace());
    await cache.initialize();
    final manager = DownloadTaskManager(
      store: store,
      cacheManager: cache,
      client: http.Client(),
      resolveSelection: (_) async => null,
      initialNetworkAccess: DownloadNetworkAccess.cellularBlocked,
    );
    await manager.initialize();
    debugPrint('cellular-test: manager initialized');
    addTearDown(() async {
      await manager.dispose();
      manager.client.close();
      await cache.flush();
      directory.deleteSync(recursive: true);
    });
    final waiting = _task(
      '1',
      DownloadTaskStatus.paused,
      pauseReason: DownloadPauseReason.network,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => Stream.value([waiting])),
          downloadManagerProvider.overrideWith((ref) async => manager),
          downloadNetworkAccessProvider.overrideWithValue(
            DownloadNetworkAccess.cellularBlocked,
          ),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint('cellular-test: page pumped');

    expect(find.textContaining('等待 Wi-Fi'), findsOneWidget);
    await tester.tap(find.byTooltip('等待 Wi-Fi，点击继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    debugPrint('cellular-test: dialog pumped');
    expect(find.text('使用蜂窝网络继续下载？'), findsOneWidget);
    expect(find.textContaining('预计还需 300 MB'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '继续下载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    debugPrint('cellular-test: dialog closed');
    expect(find.text('使用蜂窝网络继续下载？'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(downloadAllowCellularKey), isNull);
    debugPrint('cellular-test: body complete');
  });
}
