part of '../player_page.dart';

/// 播放页共享状态基类：集中全部可变字段，供各职责 mixin 读写。
/// 抽象方法声明的是"跨职责接缝"——方法本体在对应 mixin 中实现，
/// 其他 mixin 只经由这些声明调用，形成显式的依赖边界。
abstract class PlayerStateBase extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  // ── 会话/控制器（player_session_lifecycle.dart）──────────────────
  Future<void> _setup(Duration resume);
  ({VideoPlayerController? controller, PlaybackSession? session})
  _detachPlayback();
  Future<void> _disposeDetachedPlayback(
    ({VideoPlayerController? controller, PlaybackSession? session}) playback,
  );
  Future<void> _loadSkipPolicy();

  // ── 持久化/生命周期（player_persistence.dart）────────────────────
  Future<void> _save();
  void _startPlaybackTimer();
  Future<void> _syncWakelock();

  // ── 控制栏/锁屏/遥控器/全屏（player_controls_state.dart）─────────
  void _showControls();
  void _scheduleControlsHide();
  bool get _isPortraitVideo;
  Future<void> _syncFullScreenOrientation();
  Future<void> _saveAndPop();

  // ── 拖动快进状态机（player_seek.dart）───────────────────────────
  void _seekStart(Duration target);
  void _seekUpdate(Duration target);
  Future<void> _seekEnd(Duration target);
  Future<void> _seekCancel();
  void _seekToAbsolute(Duration target);
  Duration _clampSeekTarget(Duration target, Duration duration);
  void _resetSeekState();
  void _notePlaybackDuration(Duration playerDuration);

  // ── 剧集/线路切换（player_episodes.dart）────────────────────────
  Future<void> _switchEpisode(Episode next);
  Episode? _adjacentEpisode(int delta);
  Future<PlaybackSelection> _resolvePlaybackSource(PlaybackSelection start);
  PlaybackSelection? _bindPlaybackHeaders(PlaybackSelection? selection);

  // ── 播放命令/跳过片头片尾（player_playback_commands.dart）────────
  Future<void> _togglePlayback();
  Future<void> _resumePlayback([VideoPlayerController? target]);
  void _skipOutro();
  void _queueVolumeChange(double value);

  // ── 屏幕手势（player_gestures.dart）─────────────────────────────
  void _stopSpeedBoost(VideoPlayerController? current);
  void _handleSpeedBoostBuffering(VideoPlayerController current);

  late final HistoryRepository historyRepository;
  late final OfflineProgressRepository offlineProgressRepository;
  late final ScreenAwakeController screenAwakeController;
  final Object screenAwakeOwner = Object();
  VideoPlayerController? controller;
  late Episode episode;
  PlaybackSelection? _selection;
  int setupGeneration = 0;
  PlaybackSession? _activeSession;
  LocalProxyServer? _proxy;
  http.Client? _sessionClient;
  PlaybackUrlResolver? _urlResolver;
  PlaybackStartupTrace? _startupTrace;
  Timer? saveTimer;
  Timer? controlsTimer;
  Timer? _lockButtonTimer;
  bool failed = false, fullScreen = false, initializing = true;
  bool fillScreen = false;
  bool controlsVisible = true;
  bool _episodeMenuOpen = false;
  bool _speedMenuOpen = false;
  bool _screenLocked = false;
  bool _lockButtonVisible = true;
  bool _isAppForeground = true;
  bool _playbackDesired = true;
  bool _completionHandled = false;
  bool _fullScreenTransitionInFlight = false;
  bool _fullScreenToggleQueued = false;
  bool _fullScreenLockedPortrait = false;
  bool _savedBeforePop = false;
  Future<void> _systemUiTransition = Future.value();
  int _lifecycleGeneration = 0;
  PlaybackStatus playbackStatus = const PlaybackStatus.preparing();
  bool playbackToggleInFlight = false;
  bool isSeeking = false;
  final ValueNotifier<Duration?> previewPosition = ValueNotifier(null);
  final ValueNotifier<Duration?> seekClock = ValueNotifier(null);
  final ValueNotifier<bool> seekCommitting = ValueNotifier(false);
  Duration _observedDuration = Duration.zero;
  final ValueNotifier<bool> screenSeeking = ValueNotifier(false);
  final ValueNotifier<bool> speedBoosting = ValueNotifier(false);
  final ValueNotifier<bool> speedBoostFallback = ValueNotifier(false);
  Timer? _speedBoostRetryTimer;
  bool _speedBoostRetried = false;
  bool? _lastBuffering;
  Duration positionBeforeSeek = Duration.zero;
  Duration screenSeekStartPosition = Duration.zero;
  double screenSeekStartX = 0;
  bool screenLongPressOnRight = false;
  double playbackSpeed = 1;
  double playbackVolume = 1;
  double volumeBeforeMute = 1;
  bool volumeSliderVisible = false;
  double screenBrightness = 0.5;
  bool screenBrightnessLoaded = false;
  bool verticalDragHasUpdated = false;
  double? _pendingVolume;
  double? _pendingBrightness;
  bool _applyingVolume = false;
  bool _applyingBrightness = false;
  Future<void> _brightnessChangeTask = Future.value();
  double verticalDragStartY = 0;
  double verticalDragStartValue = 0;
  int verticalDragGeneration = 0;
  final ValueNotifier<({bool isVolume, double value})?> verticalDrag =
      ValueNotifier(null);
  Future<void> longPressSpeedChange = Future.value();
  bool wasPlayingBeforeSeek = false;
  Future<void> seekPause = Future.value();
  int seekGeneration = 0;
  String errorMessage = '视频加载失败，请检查网络后重试';

  /// TV 遥控器/D-pad 按键处理的焦点节点，以 autofocus 挂在页面根部，
  /// 保证遥控器事件始终落到播放页。
  final FocusNode _remoteKeyFocusNode = FocusNode();

  /// 选集/倍速菜单的 GlobalKey，供遥控器菜单键程序化打开；
  /// 按钮本身仍由原 ValueKey 定位。
  final GlobalKey<PopupMenuButtonState<Episode>> _episodeMenuKey = GlobalKey();
  final GlobalKey<PopupMenuButtonState<double>> _speedMenuKey = GlobalKey();

  /// 是否运行在 Android TV（isTvProvider 驱动）。仅 TV 接管遥控器按键，
  /// 手机端不拦截任何键盘事件，保持既有触摸路径。
  bool _isTv = false;

  /// 手机端退出全屏/离开播放页时锁回竖屏；平板和电视保持自由旋转。
  bool _lockPortraitOnExit = true;

  /// 当前预取目标（领先播放位置的时长），由 prefetchAheadProvider 驱动
  /// （网络类型/开关变化）。
  Duration _prefetchAhead = Duration.zero;

  /// 退出播放器时是否立即清理本次播放的缓存条目（自动清理设置驱动）。
  /// 设置未加载完成前保守起见不清理（默认项是 1 小时后，不退出即清）。
  bool _cleanCacheOnExit = false;
  Set<String> _downloadedEpisodeKeys = const {};

  SkipPolicy _skipPolicy = const SkipPolicy();
  bool _introSkipped = false;
  bool _outroSkipped = false;

  /// 本集起播/续播的目标位置（广告过滤后时间轴）。片头是否跳过看它，
  /// 不看起播瞬间可能仍为 0 的 native position。
  Duration _introDecisionPosition = Duration.zero;
}
