import 'dart:async';
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
import 'package:jive/data/download/download_screen_awake_preferences.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/features/download/download_management_page.dart';
import 'package:jive/features/download/widgets/download_task_card.dart';
import 'package:jive/data/offline_progress_repository.dart';
import 'package:jive/shared/screen_awake_controller.dart';
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
  String sourceVideoId = 'v',
  int expectedResourceCount = 100,
  int completedResourceCount = 40,
  int totalBytes = 500 * 1024 * 1024,
  int downloadedBytes = 200 * 1024 * 1024,
  int speedBytesPerSecond = 1024 * 1024,
  DownloadPauseReason? pauseReason,
  int createdAtMs = 0,
  int updatedAtMs = 0,
}) => DownloadTask(
  taskId: id,
  sourceId: 's',
  sourceVideoId: sourceVideoId,
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
  createdAtMs: createdAtMs,
  updatedAtMs: updatedAtMs,
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
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('188 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-pause-1')), findsOneWidget);
    expect(find.byTooltip('取消下载'), findsNothing);
    expect(find.byTooltip('删除任务记录'), findsNothing);

    await tester.tap(find.byTooltip('编辑任务'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('全选 这是一部名称很长的测试影片'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets(
    'completed download separates watch progress and size without dimming actions',
    (tester) async {
      final task = _task('1', DownloadTaskStatus.completed);
      final watched = OfflineEpisodeProgress(
        key: offlineProgressKeyForTask(task),
        positionMs: 7000,
        durationMs: 10000,
        updatedAt: DateTime(2026),
        completed: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadTasksProvider.overrideWith((ref) => Stream.value([task])),
            offlineProgressProvider.overrideWith(
              (ref) async => {watched.key: watched},
            ),
          ],
          child: const MaterialApp(home: DownloadManagementPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试影片'));
      await tester.pumpAndSettle();

      expect(find.text('看到 0:07 / 0:10'), findsOneWidget);
      expect(find.textContaining('70%'), findsNothing);
      expect(find.text('500 MB'), findsOneWidget);
      final row = find.byKey(const ValueKey('download-task-row-1'));
      expect(
        find.descendant(of: row, matching: find.byType(Opacity)),
        findsNothing,
      );
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.descendant(of: row, matching: find.text('第1集')))
            .style
            ?.color,
        AppPalette.dark.secondary,
      );
    },
  );

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

  testWidgets(
    'long pressing an episode enters edit with only that episode selected',
    (tester) async {
      final tasks = [
        _task('1', DownloadTaskStatus.downloading),
        _task('2', DownloadTaskStatus.paused, episode: '第2集'),
        _task(
          '3',
          DownloadTaskStatus.paused,
          title: '另一部影片',
          sourceVideoId: 'v2',
        ),
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

      await tester.longPress(find.byKey(const ValueKey('download-task-row-1')));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.byTooltip('全选 测试影片'), findsOneWidget);
      final groupCheckbox = tester.widget<Checkbox>(
        find.descendant(
          of: find.byTooltip('全选 测试影片'),
          matching: find.byType(Checkbox),
        ),
      );
      expect(groupCheckbox.value, isNull);

      await tester.tap(find.byTooltip('全选 测试影片'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(find.byTooltip('取消全选 测试影片'), findsOneWidget);
      expect(find.byTooltip('全选 另一部影片'), findsOneWidget);
      expect(find.byTooltip('全选当前筛选结果'), findsOneWidget);

      await tester.tap(find.byTooltip('取消全选 测试影片'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(find.byTooltip('全选 测试影片'), findsOneWidget);
    },
  );

  testWidgets(
    'long pressing a collapsed video group selects its visible episodes',
    (tester) async {
      final tasks = [
        _task('1', DownloadTaskStatus.paused),
        _task('2', DownloadTaskStatus.paused, episode: '第2集'),
        _task(
          '3',
          DownloadTaskStatus.paused,
          title: '另一部影片',
          sourceVideoId: 'v2',
        ),
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

      expect(find.byKey(const ValueKey('download-task-row-1')), findsNothing);
      await tester.longPress(find.text('测试影片'));
      await tester.pumpAndSettle();

      expect(find.text('已选 2 项'), findsOneWidget);
      expect(find.byTooltip('取消全选 测试影片'), findsOneWidget);
      expect(find.byTooltip('全选 另一部影片'), findsOneWidget);
      expect(find.byKey(const ValueKey('download-task-row-1')), findsNothing);

      await tester.tap(find.text('测试影片'));
      await tester.pumpAndSettle();
      final selected = tester.widgetList<Checkbox>(
        find.descendant(
          of: find.byType(DownloadManagementPage),
          matching: find.byType(Checkbox),
        ),
      );
      expect(
        selected.where((checkbox) => checkbox.value == true),
        hasLength(3),
      );
    },
  );

  testWidgets('video group selection follows the current filter', (
    tester,
  ) async {
    final tasks = [
      _task('1', DownloadTaskStatus.paused),
      _task('2', DownloadTaskStatus.completed, episode: '第2集'),
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

    await tester.longPress(find.text('测试影片'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.byTooltip('退出编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '全部 2'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('测试影片'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
  });

  testWidgets('concurrent download progress does not reorder video groups', (
    tester,
  ) async {
    final updates = StreamController<List<DownloadTask>>();
    addTearDown(() => unawaited(updates.close()));
    final first = _task(
      'a',
      DownloadTaskStatus.downloading,
      title: '影片A',
      sourceVideoId: 'a',
      createdAtMs: 3000,
      updatedAtMs: 3000,
    );
    final earlierEpisode = _task(
      'a0',
      DownloadTaskStatus.completed,
      episode: '第0集',
      title: '影片A',
      sourceVideoId: 'a',
      createdAtMs: 1000,
      updatedAtMs: 1000,
    );
    final second = _task(
      'b',
      DownloadTaskStatus.downloading,
      title: '影片B',
      sourceVideoId: 'b',
      createdAtMs: 2000,
      updatedAtMs: 2000,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => updates.stream),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );

    void expectOrder() {
      expect(
        tester.getTopLeft(find.text('影片B')).dy,
        lessThan(tester.getTopLeft(find.text('影片A')).dy),
      );
    }

    updates.add([first, second, earlierEpisode]);
    await tester.pumpAndSettle();
    expectOrder();

    updates.add([second.copyWith(updatedAtMs: 4000), first, earlierEpisode]);
    await tester.pumpAndSettle();
    expectOrder();

    updates.add([first.copyWith(updatedAtMs: 5000), second, earlierEpisode]);
    await tester.pumpAndSettle();
    expectOrder();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('same video identity keeps one group and stable episode order', (
    tester,
  ) async {
    final updates = StreamController<List<DownloadTask>>();
    addTearDown(() => unawaited(updates.close()));
    final first = _task(
      'a',
      DownloadTaskStatus.downloading,
      episode: '特别篇',
      title: '原剧名',
      createdAtMs: 1000,
      updatedAtMs: 2000,
    );
    final second = _task(
      'b',
      DownloadTaskStatus.downloading,
      episode: '特别篇',
      title: '更新后的剧名',
      createdAtMs: 1000,
      updatedAtMs: 3000,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadTasksProvider.overrideWith((ref) => updates.stream),
        ],
        child: const MaterialApp(home: DownloadManagementPage()),
      ),
    );

    void expectOrder() {
      expect(find.byType(DownloadVideoGroup), findsOneWidget);
      expect(find.text('原剧名'), findsOneWidget);
      expect(find.text('2 集 · 完成 0 集'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('download-task-row-a'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('download-task-row-b')))
              .dy,
        ),
      );
    }

    updates.add([second, first]);
    await tester.pumpAndSettle();
    expectOrder();

    updates.add([first.copyWith(updatedAtMs: 4000), second]);
    await tester.pumpAndSettle();
    expectOrder();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('download wake request follows setting, route, and task state', (
    tester,
  ) async {
    final applied = <bool>[];
    final screenAwake = ScreenAwakeController(
      setEnabled: (enabled) async => applied.add(enabled),
    );
    final observer = RouteObserver<PageRoute<dynamic>>();
    final updates = StreamController<List<DownloadTask>>();
    final container = ProviderContainer(
      overrides: [
        screenAwakeControllerProvider.overrideWithValue(screenAwake),
        screenAwakeRouteObserverProvider.overrideWithValue(observer),
        downloadTasksProvider.overrideWith((ref) => updates.stream),
      ],
    );
    addTearDown(() {
      container.dispose();
      unawaited(updates.close());
      unawaited(screenAwake.dispose());
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [observer],
          home: const DownloadManagementPage(),
        ),
      ),
    );
    updates.add([_task('1', DownloadTaskStatus.downloading)]);
    await tester.pumpAndSettle();
    expect(applied.last, isFalse);

    await container
        .read(downloadKeepScreenAwakeProvider.notifier)
        .setEnabled(true);
    await tester.pumpAndSettle();
    expect(applied.last, isTrue);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('播放器'))),
    );
    await tester.pumpAndSettle();
    expect(applied.last, isFalse);

    final playerOwner = Object();
    await screenAwake.setRequested(playerOwner, true);
    navigator.pop();
    await tester.pumpAndSettle();
    await screenAwake.release(playerOwner);
    expect(applied.last, isTrue);

    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(DownloadManagementPage)),
        builder: (_) => const AlertDialog(title: Text('确认')),
      ),
    );
    await tester.pumpAndSettle();
    expect(applied.last, isTrue);
    navigator.pop();
    await tester.pumpAndSettle();

    await container
        .read(downloadKeepScreenAwakeProvider.notifier)
        .setEnabled(false);
    await tester.pumpAndSettle();
    expect(applied.last, isFalse);
    await container
        .read(downloadKeepScreenAwakeProvider.notifier)
        .setEnabled(true);
    await tester.pumpAndSettle();
    expect(applied.last, isTrue);

    updates.add([_task('1', DownloadTaskStatus.paused)]);
    await tester.pumpAndSettle();
    expect(applied.last, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deleting tasks always includes their local files', (
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

    await tester.tap(find.text('测试影片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选 测试影片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('批量删除下载？'), findsOneWidget);
    expect(find.textContaining('下载任务及其本地文件'), findsOneWidget);
    expect(find.text('同时删除本地文件'), findsNothing);
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
