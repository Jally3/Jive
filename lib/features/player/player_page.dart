import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import '../../app/theme.dart';
import '../../data/playback/ad_filter.dart';
import '../../data/cache/cache_manager.dart';
import '../../data/cache/cache_providers.dart';
import '../../data/cache/cache_ttl_policy.dart';
import '../../data/playback/content_type_sniffer.dart';
import '../../data/download/download_providers.dart';
import '../../data/download/download_task_manager.dart';
import '../../data/playback/hls_parser.dart';
import '../../data/playback/local_proxy.dart';
import '../../data/playback/playback_session.dart';
import '../../data/playback/playback_url_resolver.dart';
import '../../data/playback/prefetch_policy.dart';
import '../../data/playback/skip_policy.dart';
import '../../data/playback/trace/playback_startup_trace.dart';
import '../../data/playback/playback_startup_watchdog.dart';
import '../../data/playback/trace/playback_trace_stage.dart';
import '../../data/vod_source/adapters/age_adapter.dart';
import '../../data/history_repository.dart';
import '../../data/offline_progress_repository.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_adapter.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_selection.dart';
import '../../domain/playback_source.dart';
import '../../domain/playback_status.dart';
import '../../domain/video.dart';
import '../../domain/watch_record.dart';
import '../../shared/app_toast.dart';
import '../../shared/is_tv.dart';
import '../../shared/playback_scrubber.dart';
import '../../shared/screen_awake_controller.dart';
import 'widgets/playback_status_indicator.dart';
import 'widgets/player_controls_bar.dart';
import 'widgets/player_error_view.dart';
import 'widgets/player_gesture_layer.dart';
import 'widgets/player_indicators.dart';
import 'widgets/player_info_panel.dart';
import 'widgets/player_overlays.dart';
import 'playback_seek_clock.dart';
import 'widgets/player_top_bar.dart';

export 'widgets/playback_status_indicator.dart';
export 'widgets/player_info_panel.dart';

// 播放页原本是 2500+ 行的单个 State 类，按职责拆为共享状态基类 +
// 7 个职责 mixin（见 player_state.dart 顶部的接缝说明）。
// 本文件保留：页面参数壳、生命周期装配、UI 组装。
part 'parts/player_state.dart';
part 'parts/player_session_lifecycle.dart';
part 'parts/player_persistence.dart';
part 'parts/player_controls_state.dart';
part 'parts/player_episodes.dart';
part 'parts/player_playback_commands.dart';
part 'parts/player_gestures.dart';
part 'parts/player_seek.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.video,
    required this.episode,
    this.resumePosition = Duration.zero,
    this.selection,
    this.episodeSelections = const {},
    this.episodeResumePositions = const {},
    this.offlineOnly = false,
    this.startupTrace,
  });
  final Video video;
  final Episode episode;
  final Duration resumePosition;
  final PlaybackSelection? selection;
  final Map<String, PlaybackSelection> episodeSelections;
  final Map<String, Duration> episodeResumePositions;
  final bool offlineOnly;
  final PlaybackStartupTrace? startupTrace;
  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends PlayerStateBase
    with
        PlayerSessionLifecycle,
        PlayerProgressPersistence,
        PlayerControlsState,
        PlayerEpisodeNavigation,
        PlayerPlaybackCommands,
        PlayerScreenGestures,
        PlayerSeekCoordinator {
  @override
  void initState() {
    super.initState();
    // Cache provider-backed dependencies while the ConsumerState is mounted.
    // dispose() must not access ref because its BuildContext is deactivated.
    historyRepository = ref.read(historyRepositoryProvider);
    offlineProgressRepository = ref.read(offlineProgressRepositoryProvider);
    screenAwakeController = ref.read(screenAwakeControllerProvider);
    _updateDownloadedEpisodeKeys(
      ref.read(downloadTasksProvider).value ?? const [],
    );
    ref.listenManual(downloadTasksProvider, (_, next) {
      _updateDownloadedEpisodeKeys(next.value ?? const []);
    });
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isAppForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _prefetchAhead = ref.read(prefetchAheadProvider);
    // 网络类型或开关变化时更新预取目标；从 0 变为可用时按当前位置重锚定。
    ref.listenManual(prefetchAheadProvider, (previous, next) {
      _prefetchAhead = next;
      if (next > Duration.zero && previous != next) {
        _activeSession?.prefetcher?.updatePosition(
          controller?.value.position ?? Duration.zero,
        );
      }
    });
    _cleanCacheOnExit = ref.read(cacheTtlProvider).value?.cleanOnExit ?? false;
    ref.listenManual(cacheTtlProvider, (_, next) {
      final option = next.value;
      if (option != null) _cleanCacheOnExit = option.cleanOnExit;
    });
    _isTv = ref
        .read(isTvProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    ref.listenManual(isTvProvider, (_, next) {
      _isTv = next.maybeWhen(data: (value) => value, orElse: () => false);
    });
    _skipPolicy =
        ref.read(skipPolicyProvider(widget.video.globalId)).value ??
        const SkipPolicy();
    ref.listenManual(skipPolicyProvider(widget.video.globalId), (_, next) {
      final policy = next.value;
      if (policy == null || policy == _skipPolicy) return;
      if (!mounted) return;
      setState(() => _skipPolicy = policy);
      _maybeSkipIntro();
    });
    WidgetsBinding.instance.addObserver(this);
    episode = widget.episode;
    _startupTrace = widget.startupTrace;
    _selection = widget.selection ?? selectionFor(widget.video, widget.episode);
    unawaited(_loadInitialScreenBrightness());
    unawaited(_setup(widget.resumePosition));
  }

  @override
  void dispose() {
    _startupTrace?.cancel();
    setupGeneration++;
    _startupWatchdog?.cancel();
    _lifecycleGeneration++;
    _isAppForeground = false;
    _playbackDesired = false;
    WidgetsBinding.instance.removeObserver(this);
    saveTimer?.cancel();
    controlsTimer?.cancel();
    _speedBoostRetryTimer?.cancel();
    _lockButtonTimer?.cancel();
    final save = _save();
    final detached = _detachPlayback();
    final proxy = _proxy;
    final client = _sessionClient;
    // 退出清理需要在 close 之前取 entryKey（close 会释放 cacheRef）。
    final sessionEntryKey = detached.session?.cacheRef?.entryKey;
    final sessionCacheManager = detached.session?.cacheManager;
    unawaited(() async {
      await save.catchError((_) {});
      await _disposeDetachedPlayback(detached);
      if (_cleanCacheOnExit &&
          sessionEntryKey != null &&
          sessionCacheManager != null) {
        try {
          await sessionCacheManager.deletePlaybackEntry(sessionEntryKey);
        } catch (_) {}
      }
      await proxy?.close();
      client?.close();
    }());
    previewPosition.dispose();
    seekClock.dispose();
    seekCommitting.dispose();
    screenSeeking.dispose();
    speedBoosting.dispose();
    speedBoostFallback.dispose();
    verticalDrag.dispose();
    _remoteKeyFocusNode.dispose();
    unawaited(() async {
      try {
        await _systemUiTransition;
      } catch (_) {}
      await SystemChrome.setPreferredOrientations(_idlePreferredOrientations());
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }());
    unawaited(_resetScreenBrightness());
    unawaited(screenAwakeController.release(screenAwakeOwner));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 沉浸式 overlay：全屏，或设备本身是横屏（iPad 横屏未全屏）。
    // 退出横屏全屏时旋转动画有几帧延迟，期间 MediaQuery 仍可能是横屏尺寸，
    // 用 overlay 避免竖屏 Column 在横屏尺寸下溢出。
    final overlayLayout = _overlayLayoutOf(context);
    if (!overlayLayout && _screenLocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_overlayLayoutOf(context)) {
          _unlockScreenForLayoutChange();
        }
      });
    }
    final colors = context.appColors;
    final appBrightness = Theme.of(context).brightness;
    _lockPortraitOnExit =
        !_isTv && MediaQuery.sizeOf(context).shortestSide < 600;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayLayout || appBrightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (fullScreen) {
            unawaited(_toggleFullScreen());
            return;
          }
          unawaited(_saveAndPop());
        },
        child: Focus(
          focusNode: _remoteKeyFocusNode,
          autofocus: true,
          onKeyEvent: _handleRemoteKeyEvent,
          child: Scaffold(
            backgroundColor: overlayLayout ? Colors.black : colors.background,
            appBar: overlayLayout
                ? null
                : AppBar(
                    centerTitle: false,
                    titleSpacing: 0,
                    leading: IconButton(
                      tooltip: '返回',
                      onPressed: () => unawaited(_saveAndPop()),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    toolbarHeight:
                        56 +
                        12 *
                            (MediaQuery.textScalerOf(context).scale(1) - 1)
                                .clamp(0.0, 1.0),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.video.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          episode.name,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
            body: overlayLayout
                ? _darkPlayerSurface(_overlayBody())
                : Column(
                    children: [
                      _darkPlayerSurface(_portraitPlayer()),
                      Expanded(
                        child: SafeArea(
                          top: false,
                          child: PlayerInfoPanel(
                            video: widget.video,
                            current: episode,
                            onEpisodeTap: (e) => unawaited(_switchEpisode(e)),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _darkPlayerSurface(Widget child) {
    final darkTheme = buildDarkTheme();
    return Theme(
      data: darkTheme,
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: AppColors.text),
        child: IconTheme.merge(
          data: const IconThemeData(color: AppColors.text),
          child: ColoredBox(
            key: const ValueKey('player-video-surface'),
            color: Colors.black,
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Future<void> _saveAndPop() async {
    if (_savedBeforePop) return;
    _savedBeforePop = true;
    try {
      await _save();
    } catch (_) {}
    if (!mounted) {
      _savedBeforePop = false;
      return;
    }
    if (_lockPortraitOnExit) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]),
      );
    }
    Navigator.of(context).pop<Episode>(episode);
  }

  Widget _overlayBody() {
    final showStandaloneBack = failed || initializing;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!showStandaloneBack)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _screenLocked ? _toggleLockedControls : _toggleControls,
            ),
          ),
        Center(
          child: failed
              ? SingleChildScrollView(child: _error())
              : initializing
              ? const CircularProgressIndicator()
              : _player(),
        ),
        if (!showStandaloneBack) ...[
          _gestureIndicator(topBarVisible: controlsVisible && !_screenLocked),
          // 顶栏按屏幕安全区定位，避免视频黑边与 SafeArea 叠加留白。
          PlayerTopBar(
            visible: controlsVisible && !_screenLocked,
            fullScreen: fullScreen,
            title: '${widget.video.title} · ${episode.name}',
            onShowControls: _showControls,
            isTv: _isTv,
            onBack: fullScreen
                ? _toggleFullScreen
                : () => unawaited(_saveAndPop()),
          ),
        ],
        if (showStandaloneBack)
          Align(
            alignment: Alignment.topLeft,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  key: const ValueKey('player-state-back'),
                  tooltip: fullScreen ? '退出全屏' : '返回',
                  onPressed: fullScreen
                      ? () => unawaited(_toggleFullScreen())
                      : () => unawaited(_saveAndPop()),
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                  ),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            ),
          ),
        if (!showStandaloneBack && !_isTv)
          PlayerScreenLockButton(
            locked: _screenLocked,
            visible: _screenLocked ? _lockButtonVisible : controlsVisible,
            onPressed: _toggleScreenLock,
          ),
      ],
    );
  }

  /// 竖屏时的播放器区域：加载/出错只在 16:9 区域内展示，下方信息面板保持不变。
  Widget _portraitPlayer() {
    if (failed) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: SingleChildScrollView(child: _error())),
      );
    }
    if (initializing) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return _player(portrait: true);
  }

  Widget _error() => PlayerErrorView(message: errorMessage, onRetry: _retry);

  Widget _gestureIndicator({bool topBarVisible = false}) =>
      PlayerGestureIndicator(
        controller: controller!,
        previewPosition: previewPosition,
        seekClock: seekClock,
        seekCommitting: seekCommitting,
        screenSeeking: screenSeeking,
        speedBoosting: speedBoosting,
        speedBoostFallback: speedBoostFallback,
        verticalDrag: verticalDrag,
        positionBeforeSeek: positionBeforeSeek,
        topBarVisible: topBarVisible,
      );

  Widget _player({bool portrait = false}) {
    final current = controller!;
    final downloadTasks = ref.watch(downloadTasksProvider).value ?? const [];
    final currentDownload = downloadTasks
        .where(
          (task) =>
              _selection != null &&
              task.sourceId == _selection!.sourceId &&
              task.sourceVideoId == widget.video.sourceVideoId &&
              task.playbackLineIdentity == _selection!.playbackLineIdentity &&
              task.episodeIdentity == _selection!.episodeIdentity,
        )
        .firstOrNull;
    final aspectRatio = current.value.aspectRatio == 0
        ? 16 / 9
        : current.value.aspectRatio;
    // 铺满（cover）在沉浸式 overlay（全屏或设备横屏）生效：视频等比放大覆盖
    // 整个区域，超出部分裁剪；窗口模式保持完整画面。
    final overlayLayout = _overlayLayoutOf(context);
    final lockActive = overlayLayout && _screenLocked;
    final cover = fillScreen && overlayLayout && !_isPortraitVideo;
    final compactControls =
        MediaQuery.sizeOf(context).width < 430 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.2;
    final showEpisodeNav = overlayLayout && _lineEpisodes.length > 1;
    final stack = Stack(
      alignment: Alignment.center,
      children: [
        if (cover)
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: aspectRatio * 100,
                height: 100,
                child: VideoPlayer(current),
              ),
            ),
          )
        else
          Positioned.fill(
            child: Center(
              child: AspectRatio(
                aspectRatio: aspectRatio,
                child: VideoPlayer(current),
              ),
            ),
          ),
        if (lockActive)
          PlayerLockedGestureLayer(
            onTap: _toggleLockedControls,
            onLongPressStart: _screenLongPressStart,
            onLongPressEnd: _screenLongPressEnd,
            onLongPressCancel: _screenLongPressCancel,
          )
        else
          PlayerGestureLayer(
            onTap: _toggleControls,
            onDoubleTap: _togglePlayback,
            onHorizontalDragStart: _screenHorizontalDragStart,
            onHorizontalDragUpdate: _screenHorizontalDragUpdate,
            onHorizontalDragEnd: _screenHorizontalDragEnd,
            onHorizontalDragCancel: _screenHorizontalDragCancel,
            onLongPressStart: _screenLongPressStart,
            onLongPressEnd: _screenLongPressEnd,
            onLongPressCancel: _screenLongPressCancel,
            onVerticalDragStart: _screenVerticalDragStart,
            onVerticalDragUpdate: _screenVerticalDragUpdate,
            onVerticalDragEnd: _screenVerticalDragEnd,
          ),
        PlayerBufferingIndicator(
          controller: current,
          screenSeeking: screenSeeking,
          seekCommitting: seekCommitting,
        ),
        if (!overlayLayout) _gestureIndicator(),
        PlayerControlsBar(
          controller: current,
          previewPosition: previewPosition,
          seekClock: seekClock,
          seekCommitting: seekCommitting,
          episodeMenuKey: _episodeMenuKey,
          speedMenuKey: _speedMenuKey,
          controlsVisible: controlsVisible && !lockActive,
          failed: failed,
          fullScreen: fullScreen,
          overlayLayout: overlayLayout,
          compactControls: compactControls,
          showEpisodeNav: showEpisodeNav,
          fillScreen: fillScreen,
          isPortraitVideo: _isPortraitVideo,
          playbackStatus: playbackStatus,
          playbackSpeed: playbackSpeed,
          playbackDesired: _playbackDesired,
          downloadStatus: currentDownload?.status,
          episodes: _lineEpisodes,
          isCurrentEpisode: (item) => _isSameEpisode(item, episode),
          onShowControls: _showControls,
          onTogglePlayback: _togglePlayback,
          onPreviousEpisode: _adjacentEpisode(-1) == null
              ? null
              : () {
                  _showControls();
                  unawaited(_switchToAdjacentEpisode(-1));
                },
          onNextEpisode: _adjacentEpisode(1) == null
              ? null
              : () {
                  _showControls();
                  unawaited(_switchToAdjacentEpisode(1));
                },
          onVolumeButton: () {
            _showControls();
            setState(() => volumeSliderVisible = !volumeSliderVisible);
          },
          onVolumeLongPress: () => unawaited(_toggleMute()),
          onDownload: currentDownload?.status == DownloadTaskStatus.completed
              ? null
              : _downloadCurrentEpisode,
          onSpeedMenuOpened: () {
            controlsTimer?.cancel();
            setState(() => _speedMenuOpen = true);
          },
          onSpeedMenuCanceled: () {
            if (!mounted) return;
            setState(() => _speedMenuOpen = false);
            _scheduleControlsHide();
          },
          onSpeedSelected: (speed) {
            setState(() => _speedMenuOpen = false);
            unawaited(_setPlaybackSpeed(speed));
            _scheduleControlsHide();
          },
          onStatusLongPress: _showPlaybackStatusDetails,
          onEpisodeMenuOpened: () {
            controlsTimer?.cancel();
            setState(() => _episodeMenuOpen = true);
          },
          onEpisodeMenuCanceled: () {
            if (!mounted) return;
            setState(() => _episodeMenuOpen = false);
            _scheduleControlsHide();
          },
          onEpisodeSelected: (next) {
            setState(() => _episodeMenuOpen = false);
            unawaited(_switchEpisode(next));
            _scheduleControlsHide();
          },
          onFillScreenToggle: () {
            _showControls();
            setState(() => fillScreen = !fillScreen);
            if (fillScreen) {
              showAppToast(context, '已切换为铺满模式，画面边缘可能被裁剪');
            }
          },
          onFullScreenToggle: () {
            _showControls();
            unawaited(_toggleFullScreen());
          },
          onSeekStart: _seekStart,
          onSeekUpdate: _seekUpdate,
          onSeekEnd: _seekEnd,
          onSeekCancel: _seekCancel,
        ),
        if (!lockActive)
          PlayerCenterReplayButton(
            controller: current,
            controlsVisible: controlsVisible,
            onReplay: _resumePlayback,
          ),
        if (!lockActive &&
            !compactControls &&
            volumeSliderVisible &&
            controlsVisible)
          PlayerVolumeSlider(
            controller: current,
            overlayLayout: overlayLayout,
            onShowControls: _showControls,
            onVolumeChanged: (value) {
              _queueVolumeChange(value);
              if (value > 0) volumeBeforeMute = value;
              _showControls();
            },
          ),
      ],
    );
    if (cover) return SizedBox.expand(child: stack);
    return AspectRatio(
      aspectRatio: portrait ? 16 / 9 : aspectRatio,
      child: stack,
    );
  }
}
