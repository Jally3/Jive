import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/download_providers.dart';
import 'package:jive/data/cache/download_task_manager.dart';
import 'package:jive/data/cache/prefetch_policy.dart';
import 'package:jive/data/history_repository.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source_registry.dart';
import 'package:jive/domain/playback_status.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/features/player_page.dart';
import 'package:jive/shared/playback_scrubber.dart';
import 'package:shared_preferences/shared_preferences.dart';
// These interfaces are transitive test fixtures of the production plugins.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

enum _InitializationResult { success, failure, pending }

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<DataSource> dataSources = [];
  final List<String> calls = [];
  final List<Duration> seekPositions = [];
  final Map<int, bool> playing = {};
  final Map<int, Duration> positions = {};
  final Map<int, StreamController<VideoEvent>> _streams = {};
  List<_InitializationResult> initializationPlan = [
    _InitializationResult.success,
  ];
  Size videoSize = const Size(160, 90);
  Duration videoDuration = const Duration(minutes: 10);
  int _nextPlayerId = 0;

  int get lastPlayerId => _nextPlayerId - 1;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    final stream = StreamController<VideoEvent>();
    _streams[playerId] = stream;
    playing[playerId] = false;
    positions[playerId] = Duration.zero;
    dataSources.add(options.dataSource);
    calls.add('create:$playerId');
    final result = initializationPlan.isEmpty
        ? _InitializationResult.success
        : initializationPlan.removeAt(0);
    switch (result) {
      case _InitializationResult.success:
        emitInitialized(playerId);
      case _InitializationResult.failure:
        emitError(playerId);
      case _InitializationResult.pending:
        break;
    }
    return playerId;
  }

  void emitError(int playerId) {
    _streams[playerId]!.addError(
      PlatformException(code: 'VideoError', message: 'fake playback failure'),
    );
  }

  void emitInitialized(int playerId) {
    _streams[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: videoSize,
        duration: videoDuration,
      ),
    );
  }

  void emitCompleted(int playerId) {
    _streams[playerId]!.add(VideoEvent(eventType: VideoEventType.completed));
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose:$playerId');
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> play(int playerId) async {
    playing[playerId] = true;
    calls.add('play:$playerId');
  }

  @override
  Future<void> pause(int playerId) async {
    playing[playerId] = false;
    calls.add('pause:$playerId');
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
    seekPositions.add(position);
    calls.add('seekTo:$playerId');
  }

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
  bool isEnabled = false;

  @override
  Future<bool> get enabled async => isEnabled;

  @override
  Future<void> toggle({required bool enable}) async {
    isEnabled = enable;
  }
}

class _FakeHistoryRepository extends HistoryRepository {
  @override
  Future<List<WatchRecord>> load() async => const [];

  @override
  Future<void> save(WatchRecord record) async {}

  @override
  Future<void> clear() async {}
}

class _FakeVideoRepository implements VideoRepository {
  _FakeVideoRepository(this.resolvedVideo);

  final Video resolvedVideo;
  int resolveCalls = 0;

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => resolvedVideo;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => const VideoPage(items: [], page: 1, pageCount: 1);

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async {
    resolveCalls++;
    return resolvedVideo;
  }
}

final _testSource = VodSource(
  id: 'test-source',
  name: '测试源',
  baseUri: Uri.parse('https://api.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

Video _playableVideo(String url) {
  final episode = Episode(
    id: '1',
    name: '第1集',
    url: url,
    identity: 'episode:1',
  );
  final line = PlaybackLine(
    id: '0',
    name: 'MP4',
    identity: 'line:1',
    episodes: [episode],
  );
  return Video(
    id: '1',
    title: '测试剧集',
    sourceId: _testSource.id,
    sourceVideoId: '1',
    description: '这是一部测试剧集的简介。',
    episodes: [episode],
    playbackLines: [line],
  );
}

Video _playableSeries(String urlPrefix, {int count = 3}) {
  final episodes = [
    for (var i = 1; i <= count; i++)
      Episode(
        id: '$i',
        name: '第$i集',
        url: '$urlPrefix/$i.mp4',
        identity: 'episode:$i',
      ),
  ];
  final line = PlaybackLine(
    id: '0',
    name: 'MP4',
    identity: 'line:1',
    episodes: episodes,
  );
  return Video(
    id: '1',
    title: '测试剧集',
    sourceId: _testSource.id,
    sourceVideoId: '1',
    description: '这是一部测试剧集的简介。',
    episodes: episodes,
    playbackLines: [line],
  );
}

Future<ProviderContainer> _pumpPlayerPage(
  WidgetTester tester, {
  required Video video,
  required _FakeVideoRepository repository,
  Episode? episode,
  double textScale = 1,
}) async {
  final container = ProviderContainer(
    overrides: [
      videoRepositoryProvider.overrideWithValue(repository),
      historyRepositoryProvider.overrideWithValue(_FakeHistoryRepository()),
      vodSourceRegistryProvider.overrideWith(
        (ref) async => VodSourceRegistry([_testSource], const {}),
      ),
      downloadTasksProvider.overrideWith(
        (ref) => Stream.value(const <DownloadTask>[]),
      ),
      prefetchAheadProvider.overrideWithValue(Duration.zero),
    ],
  );
  await container.read(vodSourceRegistryProvider.future);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PlayerPage(
          video: video,
          episode: episode ?? video.episodes.first,
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

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

Future<void> _unmountPlayerPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

List<List<String>> _capturePreferredOrientations(WidgetTester tester) {
  final orientations = <List<String>>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientations.add(List<String>.from(call.arguments as List));
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return orientations;
}

Video _video() => Video(
  id: '1',
  title: '测试剧集',
  description: '这是一部测试剧集的简介。',
  episodes: List.generate(
    3,
    (i) => Episode(
      id: '${i + 1}',
      name: '第${i + 1}集',
      url: 'https://example.com/$i.m3u8',
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform originalVideoPlatform;
  late WakelockPlusPlatformInterface originalWakelockPlatform;
  late _FakeVideoPlayerPlatform videoPlatform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    originalVideoPlatform = VideoPlayerPlatform.instance;
    originalWakelockPlatform = WakelockPlusPlatformInterface.instance;
    videoPlatform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = videoPlatform;
    WakelockPlusPlatformInterface.instance = _FakeWakelockPlatform();
  });

  tearDown(() {
    VideoPlayerPlatform.instance = originalVideoPlatform;
    WakelockPlusPlatformInterface.instance = originalWakelockPlatform;
  });

  testWidgets(
    'PlaybackStatusIndicator shows a colored dot and handles long press',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var longPressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackStatusIndicator(
              status: const PlaybackStatus(
                mode: PlaybackMode.streamingAndCaching,
              ),
              onLongPress: () => longPressed = true,
            ),
          ),
        ),
      );

      // 圆点取代文字标签：不再渲染状态文字，只渲染对应颜色的圆点。
      expect(find.text('边下边播'), findsNothing);
      final dot = tester.widget<Container>(
        find.descendant(
          of: find.byType(PlaybackStatusIndicator),
          matching: find.byType(Container),
        ),
      );
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, Colors.greenAccent);
      expect(
        tester.getSize(find.byKey(const ValueKey('playback-status-gesture'))),
        const Size.square(48),
      );

      final semanticsNode = tester.semantics.find(
        find.byType(PlaybackStatusIndicator),
      );
      expect(
        semanticsNode.getSemanticsData().hasAction(SemanticsAction.longPress),
        isTrue,
      );
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        semanticsNode.id,
        SemanticsAction.longPress,
      );
      await tester.pump();
      expect(longPressed, isTrue);

      longPressed = false;
      await tester.longPress(find.byType(PlaybackStatusIndicator));
      expect(longPressed, isTrue);
      semantics.dispose();
    },
  );

  testWidgets(
    'PlayerInfoPanel shows description and selectable episode chips',
    (tester) async {
      final video = _video();
      Episode? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerInfoPanel(
              video: video,
              current: video.episodes[1],
              onEpisodeTap: (e) => tapped = e,
            ),
          ),
        ),
      );

      expect(find.text('简介'), findsOneWidget);
      expect(find.text('这是一部测试剧集的简介。'), findsOneWidget);
      expect(find.text('选集（3）'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(3));

      final current = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '第2集'),
      );
      expect(current.selected, isTrue);
      expect(current.selectedColor, AppColors.accent);
      expect(current.labelStyle?.color, AppColors.onAccent);

      await tester.tap(find.widgetWithText(ChoiceChip, '第3集'));
      expect(tapped?.id, '3');
      expect(tapped?.name, '第3集');
    },
  );

  testWidgets('PlayerInfoPanel shows fallback when description is empty', (
    tester,
  ) async {
    final video = _video();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerInfoPanel(
            video: Video(
              id: video.id,
              title: video.title,
              episodes: video.episodes,
            ),
            current: video.episodes.first,
            onEpisodeTap: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('暂无简介'), findsOneWidget);
  });

  testWidgets(
    'PlayerInfoPanel groups episodes by 100 and expands the current group',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final video = Video(
        id: '1',
        title: '测试剧集',
        description: '这是一部测试剧集的简介。',
        episodes: List.generate(
          250,
          (i) => Episode(
            id: '${i + 1}',
            name: '第${i + 1}集',
            url: 'https://example.com/$i.m3u8',
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerInfoPanel(
              video: video,
              current: video.episodes[119],
              onEpisodeTap: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('选集（250）'), findsOneWidget);
      expect(find.text('第 1–100 集'), findsOneWidget);
      expect(find.text('第 101–200 集'), findsOneWidget);
      expect(find.text('第 201–250 集'), findsOneWidget);
      expect(find.text('第120集'), findsOneWidget);
      expect(find.text('第1集'), findsNothing);
      expect(find.text('第101集'), findsOneWidget);

      await tester.tap(find.text('第 1–100 集'));
      await tester.pump();
      expect(find.text('第1集'), findsOneWidget);
    },
  );

  testWidgets('portrait title sits beside the back button', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final video = _playableVideo('https://old.example.com/1.mp4');
    await _pumpPlayerPage(
      tester,
      video: video,
      repository: _FakeVideoRepository(video),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('playback-status-indicator'))
          .evaluate()
          .isNotEmpty,
      reason: 'player did not finish initialization',
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.centerTitle, isFalse);
    final back = tester.getCenter(find.byTooltip('返回'));
    final title = tester.getCenter(find.text('测试剧集'));
    expect(title.dx, greaterThan(back.dx));
    expect(title.dx, lessThan(tester.getSize(find.byType(AppBar)).width / 2));
    expect((title.dy - back.dy).abs(), lessThan(16));

    await _unmountPlayerPage(tester);
  });

  testWidgets('PlayerPage fits a 9:16 video at 320x568 with text scale 2', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    videoPlatform.videoSize = const Size(90, 160);
    final video = _playableVideo('https://old.example.com/1.mp4');

    await _pumpPlayerPage(
      tester,
      video: video,
      repository: _FakeVideoRepository(video),
      textScale: 2,
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('playback-status-indicator'))
          .evaluate()
          .isNotEmpty,
      reason: 'player did not finish initialization',
    );

    expect(videoPlatform.dataSources, hasLength(1));
    expect(find.byKey(const ValueKey('fake-video-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmountPlayerPage(tester);
  });

  testWidgets('PlayerPage retry creates the next controller with the fresh URL', (
    tester,
  ) async {
    const oldUrl = 'https://old.example.com/1.mp4';
    const freshUrl = 'https://fresh.example.com/1.mp4';
    final oldVideo = _playableVideo(oldUrl);
    final repository = _FakeVideoRepository(_playableVideo(freshUrl));
    videoPlatform.initializationPlan = [
      _InitializationResult.success,
      _InitializationResult.success,
    ];

    await _pumpPlayerPage(tester, video: oldVideo, repository: repository);
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'initial controller did not initialize',
    );
    videoPlatform.emitError(videoPlatform.lastPlayerId);
    await _pumpUntil(
      tester,
      () => find.text('重新获取并重试').evaluate().isNotEmpty,
      reason: 'initial controller playback failure was not shown',
    );
    expect(videoPlatform.dataSources.single.uri, oldUrl);

    await tester.tap(find.text('重新获取并重试'));
    await tester.pump(const Duration(milliseconds: 50));
    debugPrint(
      'retry debug: resolve=${repository.resolveCalls} '
      'sources=${videoPlatform.dataSources.map((source) => source.uri).toList()} '
      'calls=${videoPlatform.calls} '
      'texts=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>().toList()}',
    );
    await _pumpUntil(
      tester,
      () => videoPlatform.dataSources.length == 2,
      reason: 'retry did not create a second controller',
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-1')).evaluate().isNotEmpty,
      reason: 'fresh controller did not initialize',
    );

    expect(repository.resolveCalls, 1);
    expect(videoPlatform.dataSources.last.uri, freshUrl);
    expect(tester.takeException(), isNull);
    await _unmountPlayerPage(tester);
  });

  testWidgets('landscape loading and error states keep a visible back button', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(844, 390);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    videoPlatform.initializationPlan = [_InitializationResult.pending];
    final video = _playableVideo('https://old.example.com/1.mp4');

    await _pumpPlayerPage(
      tester,
      video: video,
      repository: _FakeVideoRepository(video),
    );
    expect(find.byKey(const ValueKey('player-state-back')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final loadingBack = tester.widget<IconButton>(
      find.byKey(const ValueKey('player-state-back')),
    );
    expect(
      loadingBack.style?.foregroundColor?.resolve(const <WidgetState>{}),
      Colors.white,
    );

    videoPlatform.emitInitialized(videoPlatform.lastPlayerId);
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'pending controller did not initialize',
    );
    videoPlatform.emitError(videoPlatform.lastPlayerId);
    await _pumpUntil(
      tester,
      () => find.text('重新获取并重试').evaluate().isNotEmpty,
      reason: 'error state was not shown',
    );
    expect(find.byKey(const ValueKey('player-state-back')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmountPlayerPage(tester);
  });

  testWidgets('PlayerPage pauses and resumes with the app lifecycle', (
    tester,
  ) async {
    final video = _playableVideo('https://old.example.com/1.mp4');
    await _pumpPlayerPage(
      tester,
      video: video,
      repository: _FakeVideoRepository(video),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
    );
    final playerId = videoPlatform.lastPlayerId;
    expect(videoPlatform.playing[playerId], isTrue);

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    expect(videoPlatform.playing[playerId], isFalse);

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump();
    await tester.pump();
    expect(videoPlatform.playing[playerId], isTrue);
    expect(videoPlatform.calls, contains('pause:$playerId'));
    expect(
      videoPlatform.calls.lastWhere((call) => call.startsWith('play:')),
      'play:$playerId',
    );

    await _unmountPlayerPage(tester);
  });

  testWidgets(
    'landscape player hides episode navigation for a single episode',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final video = _playableVideo('https://old.example.com/1.mp4');
      await _pumpPlayerPage(
        tester,
        video: video,
        repository: _FakeVideoRepository(video),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
        reason: 'player did not finish initialization',
      );

      expect(find.byKey(const ValueKey('player-episode-menu')), findsNothing);
      expect(
        find.byKey(const ValueKey('player-previous-episode')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('player-next-episode')), findsNothing);
      await _unmountPlayerPage(tester);
    },
  );

  testWidgets(
    'landscape player can pick another episode and step with next/previous',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      videoPlatform.initializationPlan = [
        _InitializationResult.success,
        _InitializationResult.success,
        _InitializationResult.success,
        _InitializationResult.success,
      ];
      final video = _playableSeries('https://old.example.com');
      await _pumpPlayerPage(
        tester,
        video: video,
        repository: _FakeVideoRepository(video),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
        reason: 'player did not finish initialization',
      );

      expect(find.byKey(const ValueKey('player-episode-menu')), findsOneWidget);
      final previous = tester.widget<IconButton>(
        find.byKey(const ValueKey('player-previous-episode')),
      );
      expect(previous.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('player-next-episode')));
      await _pumpUntil(
        tester,
        () => videoPlatform.dataSources.length == 2,
        reason: 'next episode did not start',
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-1')).evaluate().isNotEmpty,
        reason: 'next episode controller did not initialize',
      );
      expect(
        videoPlatform.dataSources.last.uri,
        'https://old.example.com/2.mp4',
      );

      await tester.tap(find.byKey(const ValueKey('player-episode-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第3集'));
      await _pumpUntil(
        tester,
        () => videoPlatform.dataSources.length == 3,
        reason: 'episode menu did not start the selected episode',
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-2')).evaluate().isNotEmpty,
        reason: 'selected episode controller did not initialize',
      );
      expect(
        videoPlatform.dataSources.last.uri,
        'https://old.example.com/3.mp4',
      );

      final next = tester.widget<IconButton>(
        find.byKey(const ValueKey('player-next-episode')),
      );
      expect(next.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('player-previous-episode')));
      await _pumpUntil(
        tester,
        () => videoPlatform.dataSources.length == 4,
        reason: 'previous episode did not start',
      );
      expect(
        videoPlatform.dataSources.last.uri,
        'https://old.example.com/2.mp4',
      );
      await _unmountPlayerPage(tester);
    },
  );

  testWidgets(
    'portrait player keeps the episode panel and hides overlay episode nav',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final video = _playableSeries('https://old.example.com');
      await _pumpPlayerPage(
        tester,
        video: video,
        repository: _FakeVideoRepository(video),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
        reason: 'player did not finish initialization',
      );

      expect(find.byKey(const ValueKey('player-episode-menu')), findsNothing);
      expect(
        find.byKey(const ValueKey('player-previous-episode')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('player-next-episode')), findsNothing);
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      await _unmountPlayerPage(tester);
    },
  );

  testWidgets(
    'completed playback exposes replay and seeks to zero before play',
    (tester) async {
      final video = _playableVideo('https://old.example.com/1.mp4');
      await _pumpPlayerPage(
        tester,
        video: video,
        repository: _FakeVideoRepository(video),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      );
      final playerId = videoPlatform.lastPlayerId;

      videoPlatform.emitCompleted(playerId);
      await tester.pump();
      await tester.pump();
      final replayButton = tester
          .widgetList<IconButton>(find.byType(IconButton))
          .singleWhere(
            (button) => button.tooltip == '重新播放' && button.style != null,
          );
      expect(replayButton.tooltip, '重新播放');

      videoPlatform.calls.clear();
      videoPlatform.seekPositions.clear();
      await tester.tap(find.byWidget(replayButton));
      await tester.pump();
      await tester.pump();

      expect(videoPlatform.seekPositions, contains(Duration.zero));
      expect(videoPlatform.calls, contains('play:$playerId'));
      expect(videoPlatform.playing[playerId], isTrue);
      await _unmountPlayerPage(tester);
    },
  );

  testWidgets('completed playback auto-starts the next episode', (
    tester,
  ) async {
    videoPlatform.initializationPlan = [
      _InitializationResult.success,
      _InitializationResult.success,
    ];
    final video = _playableSeries('https://old.example.com');
    await _pumpPlayerPage(
      tester,
      video: video,
      repository: _FakeVideoRepository(video),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'player did not finish initialization',
    );

    videoPlatform.emitCompleted(videoPlatform.lastPlayerId);
    await _pumpUntil(
      tester,
      () => videoPlatform.dataSources.length == 2,
      reason: 'completed episode did not auto-start the next episode',
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-1')).evaluate().isNotEmpty,
      reason: 'next episode controller did not initialize',
    );
    expect(videoPlatform.dataSources.last.uri, 'https://old.example.com/2.mp4');
    expect(videoPlatform.playing[videoPlatform.lastPlayerId], isTrue);
    await _unmountPlayerPage(tester);
  });

  testWidgets('last episode still exposes replay when playback completes', (
    tester,
  ) async {
    final video = _playableSeries('https://old.example.com');
    await _pumpPlayerPage(
      tester,
      video: video,
      episode: video.episodes.last,
      repository: _FakeVideoRepository(video),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'player did not finish initialization',
    );
    final playerId = videoPlatform.lastPlayerId;

    videoPlatform.emitCompleted(playerId);
    await tester.pump();
    await tester.pump();

    expect(videoPlatform.dataSources, hasLength(1));
    final replayButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere(
          (button) => button.tooltip == '重新播放' && button.style != null,
        );
    expect(replayButton.tooltip, '重新播放');
    await _unmountPlayerPage(tester);
  });

  testWidgets('popping the player returns the episode that was playing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    videoPlatform.initializationPlan = [
      _InitializationResult.success,
      _InitializationResult.success,
    ];
    final video = _playableSeries('https://old.example.com');
    Episode? popped;
    final container = ProviderContainer(
      overrides: [
        videoRepositoryProvider.overrideWithValue(_FakeVideoRepository(video)),
        historyRepositoryProvider.overrideWithValue(_FakeHistoryRepository()),
        vodSourceRegistryProvider.overrideWith(
          (ref) async => VodSourceRegistry([_testSource], const {}),
        ),
        downloadTasksProvider.overrideWith(
          (ref) => Stream.value(const <DownloadTask>[]),
        ),
        prefetchAheadProvider.overrideWithValue(Duration.zero),
      ],
    );
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<Episode>(
                    MaterialPageRoute(
                      builder: (_) => PlayerPage(
                        video: video,
                        episode: video.episodes.first,
                      ),
                    ),
                  );
                },
                child: const Text('open-player'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-player'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'player did not finish initialization',
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '第3集'));
    await _pumpUntil(
      tester,
      () => videoPlatform.dataSources.length == 2,
      reason: 'player did not switch to the third episode',
    );
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump();

    expect(popped?.name, '第3集');
    expect(popped?.identity, 'episode:3');
    expect(find.text('open-player'), findsOneWidget);
  });

  testWidgets('system back returns the current episode', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final video = _playableSeries('https://old.example.com');
    Episode? popped;
    final container = ProviderContainer(
      overrides: [
        videoRepositoryProvider.overrideWithValue(_FakeVideoRepository(video)),
        historyRepositoryProvider.overrideWithValue(_FakeHistoryRepository()),
        vodSourceRegistryProvider.overrideWith(
          (ref) async => VodSourceRegistry([_testSource], const {}),
        ),
        downloadTasksProvider.overrideWith(
          (ref) => Stream.value(const <DownloadTask>[]),
        ),
        prefetchAheadProvider.overrideWithValue(Duration.zero),
      ],
    );
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<Episode>(
                    MaterialPageRoute(
                      builder: (_) =>
                          PlayerPage(video: video, episode: video.episodes[1]),
                    ),
                  );
                },
                child: const Text('open-player'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-player'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'player did not finish initialization',
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();

    expect(popped?.name, '第2集');
    expect(find.text('open-player'), findsOneWidget);
  });

  testWidgets(
    'portrait video fullscreen stays portrait and hides the info panel',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      videoPlatform.videoSize = const Size(90, 160);
      final orientations = _capturePreferredOrientations(tester);
      final video = _playableSeries('https://old.example.com');
      await _pumpPlayerPage(
        tester,
        video: video,
        repository: _FakeVideoRepository(video),
      );
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
        reason: 'player did not finish initialization',
      );
      expect(find.byType(PlayerInfoPanel), findsOneWidget);

      await tester.tap(find.byTooltip('进入全屏'));
      await tester.pump();
      await tester.pump();

      expect(orientations, isNotEmpty);
      expect(orientations.last, ['DeviceOrientation.portraitUp']);
      expect(find.byType(PlayerInfoPanel), findsNothing);
      expect(find.byKey(const ValueKey('fullscreen-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('player-episode-menu')), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(find.byTooltip('铺满'), findsNothing);
      expect(find.byTooltip('适应'), findsNothing);
      final time = tester.getRect(
        find.byKey(const ValueKey('player-position-label')),
      );
      final scrubber = tester.getRect(find.byType(PlaybackScrubber));
      expect(time.bottom, lessThanOrEqualTo(scrubber.top + 1));
      expect(time.left, lessThan(scrubber.left + 8));
      await _unmountPlayerPage(tester);
    },
  );

  testWidgets('landscape video fullscreen still locks landscape', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    videoPlatform.videoSize = const Size(160, 90);
    final orientations = _capturePreferredOrientations(tester);
    final video = _playableVideo('https://old.example.com/1.mp4');
    await _pumpPlayerPage(
      tester,
      video: video,
      repository: _FakeVideoRepository(video),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('fake-video-0')).evaluate().isNotEmpty,
      reason: 'player did not finish initialization',
    );

    await tester.tap(find.byTooltip('进入全屏'));
    await tester.pump();
    await tester.pump();

    expect(orientations, isNotEmpty);
    expect(orientations.last, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(find.byType(PlayerInfoPanel), findsNothing);
    await _unmountPlayerPage(tester);
  });
}
