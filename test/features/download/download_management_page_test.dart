import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/download/download_providers.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/features/download/download_management_page.dart';

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
  error: status == DownloadTaskStatus.failed
      ? DownloadFailureReason.network
      : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    expect(find.text('下载中'), findsOneWidget);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('失败'), findsOneWidget);
    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('删除任务记录'), findsNothing);

    // 切换筛选
    await tester.tap(find.text('异常 1'));
    await tester.pumpAndSettle();
    expect(find.text('失败'), findsOneWidget);

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
    expect(find.text('速度 1.0 MB/s'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-pause-1')), findsOneWidget);
    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('删除任务记录'), findsNothing);
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

    final indicators = tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicators, hasLength(1));
    expect(indicators.single.value, 0);
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
}
