import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_controller.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/download_providers.dart';
import 'package:jive/data/cache/download_task_manager.dart';
import 'package:jive/data/vod_source_registry.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/more_settings_page.dart';
import 'package:jive/features/profile_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _testSource = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

DownloadTask _task(String id, DownloadTaskStatus status) => DownloadTask(
  taskId: id,
  sourceId: 's',
  sourceVideoId: 'v',
  title: '测试影片',
  playbackLineIdentity: 'line',
  episodeIdentity: 'ep$id',
  episodeId: id,
  episodeName: '第$id集',
  status: status,
  expectedResourceCount: 100,
  completedResourceCount: 40,
);

class _FakeCacheController extends CacheController {
  @override
  Future<CacheStats> build() async => const CacheStats(
    completeBytes: 1024,
    partialBytes: 0,
    reservedBytes: 0,
    quotaBytes: 2048,
    entries: [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('profile shows status quick actions instead of setting list', (
    tester,
  ) async {
    final tasks = [
      _task('1', DownloadTaskStatus.downloading),
      _task('2', DownloadTaskStatus.completed),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry([_testSource], {}),
          ),
          downloadTasksProvider.overrideWith((ref) => Stream.value(tasks)),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('离线下载'), findsOneWidget);
    expect(find.text('1 个下载中 · 40%'), findsOneWidget);
    expect(find.text('播放源'), findsOneWidget);
    expect(find.text('测试源'), findsOneWidget);
    expect(find.text('更多设置'), findsOneWidget);
    expect(find.text('播放与存储'), findsOneWidget);
    expect(find.text('缓存管理'), findsNothing);
    expect(find.text('预加载'), findsNothing);
  });

  testWidgets('more settings groups prefetch and cache entries', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheControllerProvider.overrideWith(_FakeCacheController.new),
        ],
        child: const MaterialApp(home: MoreSettingsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('更多设置'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('预加载'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.textContaining('已用 1.0 KB / 配额 2.0 KB'), findsOneWidget);
    expect(find.text('自动清理缓存'), findsOneWidget);
    expect(find.text('3 天'), findsOneWidget);
    await tester.tap(find.text('自动清理缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prefetch_mode'), 'off');
    expect(prefs.getString('cache_ttl_option'), 'off');
  });
}
