import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_controller.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/download/download_providers.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/data/library_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/library.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/settings/more_settings_page.dart';
import 'package:jive/features/profile/profile_page.dart';
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
  var refreshCount = 0;

  @override
  Future<CacheStats> build() async => CacheStats(
    completeBytes: 5 * 1024,
    partialBytes: 0,
    reservedBytes: 0,
    quotaBytes: 10 * 1024,
    entries: [
      _cacheEntry('播放缓存', 1024),
      _cacheEntry('离线下载', 4 * 1024, downloadOrigin: true),
    ],
  );

  @override
  Future<void> refresh() async {
    refreshCount++;
  }
}

CacheEntry _cacheEntry(
  String episode,
  int bytes, {
  bool downloadOrigin = false,
}) => CacheEntry(
  contentKeyVersion: 1,
  contentKeyHash: episode,
  revisionKeyHash: 'revision-$episode',
  manifestFingerprint: 'fingerprint-$episode',
  sourceId: 's',
  sourceVideoId: 'v',
  title: '测试影片',
  playbackLineIdentity: 'line',
  playbackLineName: '',
  episodeIdentity: episode,
  episodeId: episode,
  episodeName: episode,
  downloadOrigin: downloadOrigin,
  completeBytes: bytes,
);

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
    expect(find.text('追更'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.text('追更与收藏'), findsNothing);
    expect(find.text('播放缓存'), findsNothing);
    expect(find.text('预加载'), findsNothing);
  });

  testWidgets('paused download shows resume triangle and paused subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry([_testSource], {}),
          ),
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value([_task('1', DownloadTaskStatus.paused)]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('1 个下载已暂停'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_outline), findsNothing);
  });

  testWidgets('downloading arrow falls through the progress circle', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry([_testSource], {}),
          ),
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value([_task('1', DownloadTaskStatus.downloading)]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilePage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final fallingIcon = find.byKey(
      const ValueKey('profile-download-falling-icon'),
    );
    final initialY = tester
        .widget<Transform>(fallingIcon)
        .transform
        .storage[13];
    await tester.pump(const Duration(milliseconds: 400));
    final laterY = tester.widget<Transform>(fallingIcon).transform.storage[13];

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(laterY, greaterThan(initialY));
  });

  testWidgets('follow and favorite tabs do not duplicate content', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 8);
    final records = [
      FavoriteRecord(
        video: const Video(id: 'followed', title: '追更剧集'),
        createdAt: now,
        updatedAt: now,
        isFollowing: true,
      ),
      FavoriteRecord(
        video: const Video(id: 'favorite', title: '收藏电影'),
        createdAt: now,
        updatedAt: now,
      ),
    ];
    SharedPreferences.setMockInitialValues({
      LibraryRepository.libraryKey: jsonEncode(
        records.map((record) => record.toJson()).toList(),
      ),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry([_testSource], {}),
          ),
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value(const <DownloadTask>[]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilePage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('追更剧集'), findsOneWidget);
    expect(find.text('收藏电影'), findsNothing);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.text('收藏电影'), findsOneWidget);
    expect(find.text('追更剧集'), findsNothing);
  });

  testWidgets('follow card overlays latest episode and unread count', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 8);
    final record = FavoriteRecord(
      video: const Video(id: 'followed', title: '追更剧集'),
      createdAt: now,
      updatedAt: now,
      isFollowing: true,
      latestEpisodeLabel: '第12集',
      unreadAddedCount: 2,
    );
    SharedPreferences.setMockInitialValues({
      LibraryRepository.libraryKey: jsonEncode([record.toJson()]),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry([_testSource], {}),
          ),
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value(const <DownloadTask>[]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilePage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('更新至 第12集'), findsOneWidget);
    expect(find.text('新增2集'), findsOneWidget);
    expect(find.textContaining('新增 2 集'), findsNothing);
    final tabBadge = find.byKey(const ValueKey('follow-tab-update-badge'));
    expect(tabBadge, findsOneWidget);
    expect(
      find.descendant(of: tabBadge, matching: find.text('1')),
      findsOneWidget,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProfilePage)),
    );
    await container
        .read(favoriteControllerProvider.notifier)
        .markViewed(record.video.globalId);
    await tester.pumpAndSettle();

    expect(find.text('更新至 第12集'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-card-badge')), findsNothing);
    expect(find.byKey(const ValueKey('follow-tab-update-badge')), findsNothing);
  });

  testWidgets('follow check failure stays in subtitle without a badge', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 8);
    final record = FavoriteRecord(
      video: const Video(id: 'failed', title: '来源异常剧集'),
      createdAt: now,
      updatedAt: now,
      isFollowing: true,
      latestEpisodeLabel: '第12集',
      unreadAddedCount: 2,
      sourceUnavailable: true,
    );
    SharedPreferences.setMockInitialValues({
      LibraryRepository.libraryKey: jsonEncode([record.toJson()]),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry([_testSource], {}),
          ),
          downloadTasksProvider.overrideWith(
            (ref) => Stream.value(const <DownloadTask>[]),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilePage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('追更 · 来源异常'), findsOneWidget);
    expect(find.text('更新至 第12集'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-card-badge')), findsNothing);
  });

  testWidgets('more settings groups prefetch and cache entries', (
    tester,
  ) async {
    final cacheController = _FakeCacheController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheControllerProvider.overrideWith(() => cacheController),
        ],
        child: const MaterialApp(home: MoreSettingsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('更多设置'), findsOneWidget);
    expect(cacheController.refreshCount, 1);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('预加载'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('允许蜂窝网络下载'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('播放缓存'), findsOneWidget);
    expect(
      find.textContaining('已用 1.0 KB / 配额 10.0 KB · 1 个剧集'),
      findsOneWidget,
    );
    expect(find.text('自动清理缓存'), findsOneWidget);
    expect(find.text('1 小时后'), findsOneWidget);
    await tester.tap(find.text('主题模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日间模式'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自动清理缓存'));
    await tester.tap(find.text('自动清理缓存'));
    await tester.pumpAndSettle();
    expect(find.text('3 天后'), findsOneWidget);
    expect(find.text('7 天后'), findsOneWidget);
    await tester.tap(find.text('不自动清理'));
    await tester.pumpAndSettle();
    final prefetchSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('预加载'),
        matching: find.byType(SwitchListTile),
      ),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(prefetchSwitch);
    await tester.tap(prefetchSwitch);
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prefetch_mode'), 'off');
    expect(prefs.getString('cache_ttl_option'), 'never');
    expect(prefs.getString('app_theme_mode'), 'light');
  });

  testWidgets('cellular download setting confirms before persisting', (
    tester,
  ) async {
    final cacheController = _FakeCacheController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheControllerProvider.overrideWith(() => cacheController),
        ],
        child: const MaterialApp(home: MoreSettingsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final cellularSwitch = find.widgetWithText(SwitchListTile, '允许蜂窝网络下载');
    await tester.ensureVisible(cellularSwitch);
    await tester.tap(cellularSwitch);
    await tester.pumpAndSettle();
    expect(find.text('允许蜂窝网络下载？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '允许'));
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('download_allow_cellular'), isTrue);
    expect(find.textContaining('已允许使用移动数据'), findsOneWidget);
  });
}
