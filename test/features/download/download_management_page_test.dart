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
}) => DownloadTask(
  taskId: id,
  sourceId: 's',
  sourceVideoId: 'v',
  title: '测试影片',
  playbackLineIdentity: 'line',
  episodeIdentity: 'ep$id',
  episodeId: id,
  episodeName: episode,
  status: status,
  expectedResourceCount: 100,
  completedResourceCount: 40,
  totalBytes: 500 * 1024 * 1024,
  downloadedBytes: 200 * 1024 * 1024,
  speedBytesPerSecond: 1024 * 1024,
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
    expect(find.text('下载中'), findsOneWidget);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('失败'), findsOneWidget);

    // 切换筛选
    await tester.tap(find.text('失败/取消 1'));
    await tester.pumpAndSettle();
    expect(find.text('失败'), findsOneWidget);

    // 进入编辑态
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsOneWidget);
  });
}
