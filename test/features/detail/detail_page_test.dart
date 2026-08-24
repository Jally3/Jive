import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/download/download_providers.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/data/playback/prefetch_policy.dart';
import 'package:jive/data/history_repository.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:jive/features/detail/detail_page.dart';
import 'package:jive/features/player/player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

VodSource _src(String id, String name) => VodSource(
  id: id,
  name: name,
  baseUri: Uri.parse('https://$id.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

final _sources = [
  _src('storm', '暴风'),
  _src('sa', '来源A'),
  _src('sb', '来源B'),
  _src('sc', '来源C'),
  _src('sd', '来源D'),
];

const _entryVideo = Video(id: '1', title: '测试剧集', sourceId: 'storm');

List<Episode> _episodes(int count) => List.generate(
  count,
  (i) => Episode(
    id: '${i + 1}',
    name: '第${i + 1}集',
    url: 'https://example.com/$i.m3u8',
  ),
);

class _FakeDetailRepository implements VideoRepository {
  _FakeDetailRepository({
    this.activeEpisodes = 36,
    this.failSources = const {},
  });

  final int activeEpisodes;
  final Set<String> failSources;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    switch (source.id) {
      case 'sa':
        return VideoPage(
          items: [Video(id: '9', title: '测试剧集', sourceId: 'sa')],
          page: 1,
          pageCount: 1,
        );
      case 'sc':
        throw const VideoDataException('请求失败');
      default:
        return const VideoPage(items: [], page: 1, pageCount: 1);
    }
  }

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async {
    if (failSources.contains(source.id)) {
      throw const VideoDataException('请求失败');
    }
    return Video(
      id: ref.sourceVideoId,
      title: '测试剧集',
      sourceId: source.id,
      episodes: _episodes(activeEpisodes),
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

ProviderContainer _container(
  _FakeDetailRepository repository, {
  bool delayRegistry = false,
}) => ProviderContainer(
  overrides: [
    videoRepositoryProvider.overrideWithValue(repository),
    vodSourceRegistryProvider.overrideWith((ref) async {
      if (delayRegistry) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return VodSourceRegistry(_sources, const {});
    }),
  ],
);

Future<void> _pumpDetailPage(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: VideoDetailPage(video: _entryVideo)),
    ),
  );
  await tester.pump();
}

class _FakeHistoryRepository extends HistoryRepository {
  @override
  Future<List<WatchRecord>> load() async => const [];

  @override
  Future<void> save(WatchRecord record) async {}

  @override
  Future<void> clear() async {}
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<DataSource> dataSources = [];
  final Map<int, StreamController<VideoEvent>> _streams = {};
  int _nextPlayerId = 0;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    final stream = StreamController<VideoEvent>();
    _streams[playerId] = stream;
    dataSources.add(options.dataSource);
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(160, 90),
        duration: const Duration(minutes: 10),
      ),
    );
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> init() async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => ColoredBox(
    key: ValueKey('fake-video-${options.playerId}'),
    color: Colors.black,
  );
}

class _FakeWakelockPlatform extends WakelockPlusPlatformInterface {
  @override
  Future<bool> get enabled async => false;

  @override
  Future<void> toggle({required bool enable}) async {}
}

({_FakeVideoPlayerPlatform video, VoidCallback restore})
_installPlayerPlatforms() {
  final originalVideo = VideoPlayerPlatform.instance;
  final originalWakelock = WakelockPlusPlatformInterface.instance;
  final video = _FakeVideoPlayerPlatform();
  VideoPlayerPlatform.instance = video;
  WakelockPlusPlatformInterface.instance = _FakeWakelockPlatform();
  return (
    video: video,
    restore: () {
      VideoPlayerPlatform.instance = originalVideo;
      WakelockPlusPlatformInterface.instance = originalWakelock;
    },
  );
}

ProviderContainer _playerAwareContainer(_FakeDetailRepository repository) =>
    ProviderContainer(
      overrides: [
        videoRepositoryProvider.overrideWithValue(repository),
        historyRepositoryProvider.overrideWithValue(_FakeHistoryRepository()),
        vodSourceRegistryProvider.overrideWith(
          (ref) async => VodSourceRegistry(_sources, const {}),
        ),
        downloadTasksProvider.overrideWith(
          (ref) => Stream.value(const <DownloadTask>[]),
        ),
        downloadManagerProvider.overrideWith(
          (ref) async => throw StateError('unused'),
        ),
        prefetchAheadProvider.overrideWithValue(Duration.zero),
      ],
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'condition was not reached',
}) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!condition()) fail(reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opens without setState during build when registry resolves', (
    tester,
  ) async {
    final container = _container(_FakeDetailRepository(), delayRegistry: true);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('视频详情'), findsOneWidget);
    expect(find.text('暴风 36集'), findsOneWidget);
  });

  testWidgets('source chips distinguish all detection states', (tester) async {
    final container = _container(_FakeDetailRepository());
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('暴风 36集'), findsOneWidget);
    // A source only renders as a chip once it has a state; seed one via the
    // same ensureSourceState path the page uses before a manual detection.
    final registry = container.read(vodSourceRegistryProvider).value!;
    final dynamic pageState = tester.state(find.byType(VideoDetailPage));
    // ignore: avoid_dynamic_calls
    pageState.sc.ensureSourceState(registry.findById('sd')!);
    await tester.pump();
    expect(find.text('来源D —'), findsOneWidget);
    await tester.tap(find.text('查找其他来源'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('来源A 有资源'), findsOneWidget);
    expect(find.text('来源B 0'), findsOneWidget);
    expect(find.text('来源C !'), findsOneWidget);
    expect(find.text('来源D —'), findsOneWidget);
  });

  testWidgets('a single-episode active source shows the 正片 label', (
    tester,
  ) async {
    final container = _container(_FakeDetailRepository(activeEpisodes: 1));
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('暴风 正片'), findsOneWidget);
  });

  testWidgets('download button label stays on one line on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final container = _container(_FakeDetailRepository());
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();

    final label = tester.widget<Text>(find.text('下载'));
    expect(label.maxLines, 1);
    expect(label.softWrap, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error view can finish switching to a detected source', (
    tester,
  ) async {
    final container = _container(_FakeDetailRepository(failSources: {'storm'}));
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('切换来源'), findsOneWidget);

    // 第一次打开“全部来源”：点击来源A触发检测。
    await tester.tap(find.text('切换来源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('来源A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 第二次打开：来源A已有候选，点击直接进入切换确认。
    await tester.tap(find.text('切换来源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('来源A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('确认切换来源'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 切换成功后错误页恢复为正常内容，不触发空值异常。
    expect(tester.takeException(), isNull);
    expect(find.text('来源A 36集'), findsOneWidget);
  });

  testWidgets('episode chips toggle between ascending and descending order', (
    tester,
  ) async {
    final container = _container(_FakeDetailRepository());
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();
    expect(tester.takeException(), isNull);

    Text chipLabel(int i) =>
        tester.widget<ChoiceChip>(find.byType(ChoiceChip).at(i)).label as Text;

    expect(chipLabel(0).data, '第1集');

    await tester.tap(find.text('倒序'));
    await tester.pump();
    expect(chipLabel(0).data, '第36集');
    expect(chipLabel(35).data, '第1集');

    await tester.tap(find.text('正序'));
    await tester.pump();
    expect(chipLabel(0).data, '第1集');
  });

  testWidgets('episodes over 100 are grouped and collapsible', (tester) async {
    final container = _container(_FakeDetailRepository(activeEpisodes: 250));
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('第 1–100 集'));
    await tester.pumpAndSettle();
    expect(find.text('第 101–200 集'), findsOneWidget);
    expect(find.text('第 201–250 集'), findsOneWidget);
    // 默认只展开第一组。
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第101集'), findsNothing);

    // 展开第二组。
    await tester.ensureVisible(find.text('第 101–200 集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 101–200 集'));
    await tester.pump();
    expect(find.text('第101集'), findsOneWidget);

    // 收起第一组。
    await tester.ensureVisible(find.text('第 1–100 集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1–100 集'));
    await tester.pump();
    expect(find.text('第1集'), findsNothing);
  });

  testWidgets('reversing grouped episodes keeps selected group expanded', (
    tester,
  ) async {
    final container = _container(_FakeDetailRepository(activeEpisodes: 250));
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('倒序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('倒序'));
    await tester.pump();

    // 选中第1集,倒序后位于最后一组并保持展开。
    expect(find.text('第 151–250 集'), findsOneWidget);
    expect(find.text('第 1–50 集'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第250集'), findsNothing);
  });

  testWidgets('returning from the player highlights the played episode', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final platforms = _installPlayerPlatforms();
    addTearDown(platforms.restore);

    final container = _playerAwareContainer(
      _FakeDetailRepository(activeEpisodes: 3),
    );
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await _pumpDetailPage(tester, container);
    await tester.pump();

    expect(find.text('播放 第1集'), findsOneWidget);
    await tester.tap(find.text('播放 第1集'));
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'player did not open from the detail page',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(PlayerPage),
        matching: find.widgetWithText(ChoiceChip, '第3集'),
      ),
    );
    await _pumpUntil(
      tester,
      () => platforms.video.dataSources.length == 2,
      reason: 'player did not switch to the third episode',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(PlayerPage),
        matching: find.byTooltip('返回'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('播放 第3集'), findsOneWidget);

    ChoiceChip detailChip(String name) => tester.widget<ChoiceChip>(
      find.descendant(
        of: find.byType(VideoDetailPage),
        matching: find.widgetWithText(ChoiceChip, name),
      ),
    );
    expect(detailChip('第3集').selected, isTrue);
    expect(detailChip('第1集').selected, isFalse);
  });

  testWidgets(
    'returning from the player expands the group of the played episode',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platforms = _installPlayerPlatforms();
      addTearDown(platforms.restore);

      final container = _playerAwareContainer(
        _FakeDetailRepository(activeEpisodes: 250),
      );
      await container.read(vodSourceRegistryProvider.future);
      addTearDown(container.dispose);
      await _pumpDetailPage(tester, container);
      await tester.pump();

      await tester.tap(find.text('播放 第1集'));
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
        reason: 'player did not open from the detail page',
      );
      await tester.tap(find.byKey(const ValueKey('player-episode-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(
        find.text('第120集'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('第120集'));
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-1')).evaluate().isNotEmpty,
        reason: 'player did not switch to episode 120',
      );
      await tester.tap(find.byKey(const ValueKey('fullscreen-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.text('播放 第120集'), findsOneWidget);
      expect(find.text('第 101–200 集', skipOffstage: false), findsOneWidget);
      expect(find.text('第120集', skipOffstage: false), findsOneWidget);
      expect(find.text('第1集', skipOffstage: false), findsNothing);
    },
  );
}
