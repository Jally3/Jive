import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../app/theme.dart';
import '../data/history_repository.dart';
import '../data/video_repository.dart';
import '../domain/video.dart';
import '../domain/watch_record.dart';
import '../domain/playback_progress.dart';
import '../shared/playback_scrubber.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.video,
    required this.episode,
    this.resumePosition = Duration.zero,
  });
  final Video video;
  final Episode episode;
  final Duration resumePosition;
  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  late final HistoryRepository historyRepository;
  VideoPlayerController? controller;
  late Episode episode;
  Timer? saveTimer;
  Timer? controlsTimer;
  bool failed = false, fullScreen = false, initializing = true;
  bool controlsVisible = true;
  bool isSeeking = false;
  final ValueNotifier<Duration?> previewPosition = ValueNotifier(null);
  final ValueNotifier<bool> seekCommitting = ValueNotifier(false);
  final ValueNotifier<bool> screenSeeking = ValueNotifier(false);
  final ValueNotifier<bool> speedBoosting = ValueNotifier(false);
  Duration positionBeforeSeek = Duration.zero;
  Duration screenSeekStartPosition = Duration.zero;
  double screenSeekStartX = 0;
  bool screenLongPressOnRight = false;
  double playbackSpeed = 1;
  Future<void> longPressSpeedChange = Future.value();
  bool wasPlayingBeforeSeek = false;
  Future<void> seekPause = Future.value();
  int seekGeneration = 0;
  String errorMessage = '视频加载失败，请检查网络后重试';

  @override
  void initState() {
    super.initState();
    // Cache provider-backed dependencies while the ConsumerState is mounted.
    // dispose() must not access ref because its BuildContext is deactivated.
    historyRepository = ref.read(historyRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
    episode = widget.episode;
    _setup(widget.resumePosition);
  }

  Future<void> _setup(Duration resume) async {
    _resetSeekState();
    if (mounted) {
      setState(() {
        failed = false;
        initializing = true;
      });
    }
    final next = VideoPlayerController.networkUrl(
      Uri.parse(episode.url),
      formatHint: episode.url.toLowerCase().contains('.m3u8')
          ? VideoFormat.hls
          : null,
    );
    try {
      await next.initialize().timeout(const Duration(seconds: 20));
      if (!mounted) {
        await next.dispose();
        return;
      }
      if (resume > Duration.zero && resume < next.value.duration) {
        await next.seekTo(resume);
      }
      controller = next;
      next.addListener(_handlePlayerValueChanged);
      await next.setPlaybackSpeed(playbackSpeed);
      await next.play();
      saveTimer?.cancel();
      saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
      setState(() => initializing = false);
      _scheduleControlsHide();
      await _save();
    } catch (e) {
      next.removeListener(_handlePlayerValueChanged);
      if (identical(controller, next)) controller = null;
      await next.dispose();
      if (mounted) {
        setState(() {
          failed = true;
          initializing = false;
          errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
        });
      }
    }
  }

  Future<void> _retry() async {
    _resetSeekState();
    setState(() {
      failed = false;
      initializing = true;
    });
    try {
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(widget.video.id);
      final match = fresh.episodes.where(
        (item) => item.name == episode.name || item.id == episode.id,
      );
      if (match.isEmpty) throw const VideoDataException('该剧集的播放地址已经失效');
      final oldPosition = controller?.value.position ?? Duration.zero;
      controller?.removeListener(_handlePlayerValueChanged);
      await controller?.dispose();
      controller = null;
      episode = match.first;
      await _setup(oldPosition);
    } catch (e) {
      if (mounted) {
        setState(() {
          failed = true;
          initializing = false;
          errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    final current = controller;
    if (current == null || !current.value.isInitialized || isSeeking) return;
    final position = current.value.position.inMilliseconds;
    final duration = current.value.duration.inMilliseconds;
    final progress = PlaybackProgress.normalize(
      positionMs: position,
      durationMs: duration,
    );
    final record = WatchRecord(
      video: widget.video.copyWith(episodes: const []),
      episodeId: episode.id,
      episodeName: episode.name,
      positionMs: progress.positionMs,
      durationMs: progress.durationMs,
      updatedAt: DateTime.now(),
      completed: progress.completed,
    );
    await historyRepository.save(record);
  }

  void _handlePlayerValueChanged() {
    final current = controller;
    if (current == null || !current.value.hasError || failed || !mounted) {
      return;
    }
    saveTimer?.cancel();
    controlsTimer?.cancel();
    setState(() {
      failed = true;
      initializing = false;
      errorMessage = '播放已中断，请重新获取播放地址后重试';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      controller?.pause();
      unawaited(_save());
    }
  }

  Future<void> _toggleFullScreen() async {
    fullScreen = !fullScreen;
    await SystemChrome.setEnabledSystemUIMode(
      fullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    await SystemChrome.setPreferredOrientations(
      fullScreen
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
    if (mounted) setState(() {});
  }

  void _showControls() {
    controlsTimer?.cancel();
    if (mounted) setState(() => controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    controlsTimer?.cancel();
    setState(() => controlsVisible = !controlsVisible);
    if (controlsVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    if (controller?.value.isPlaying != true || isSeeking) return;
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  Future<void> _togglePlayback() async {
    final current = controller;
    if (current == null) return;
    if (current.value.isPlaying) {
      await current.pause();
      controlsTimer?.cancel();
      await _save();
    } else {
      await current.play();
      _scheduleControlsHide();
    }
    if (mounted) setState(() => controlsVisible = true);
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final current = controller;
    if (current == null || !current.value.isInitialized) return;
    await current.setPlaybackSpeed(speed);
    if (mounted) {
      setState(() => playbackSpeed = speed);
      _showControls();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    saveTimer?.cancel();
    controlsTimer?.cancel();
    unawaited(_save());
    controller?.removeListener(_handlePlayerValueChanged);
    controller?.dispose();
    previewPosition.dispose();
    seekCommitting.dispose();
    screenSeeking.dispose();
    speedBoosting.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !fullScreen,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && fullScreen) {
        unawaited(_toggleFullScreen());
      } else {
        unawaited(_save());
      }
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      appBar: fullScreen
          ? null
          : AppBar(
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
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.secondary,
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.black,
            ),
      body: Center(
        child: failed
            ? _error()
            : initializing
            ? const CircularProgressIndicator()
            : _player(),
      ),
    ),
  );

  Widget _error() => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: AppColors.error, size: 48),
        const SizedBox(height: 12),
        Text(errorMessage, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh),
          label: const Text('重新获取并重试'),
        ),
      ],
    ),
  );

  Widget _player() {
    final current = controller!;
    return AspectRatio(
      aspectRatio: current.value.aspectRatio == 0
          ? 16 / 9
          : current.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(current),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (_, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: _togglePlayback,
                onLongPressStart: (details) =>
                    _screenLongPressStart(details, constraints.maxWidth),
                onLongPressMoveUpdate: (details) =>
                    _screenLongPressUpdate(details, constraints.maxWidth),
                onLongPressEnd: (_) => _screenLongPressEnd(),
                onLongPressCancel: _screenLongPressCancel,
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: Listenable.merge([
              previewPosition,
              seekCommitting,
              screenSeeking,
              speedBoosting,
            ]),
            builder: (_, _) {
              if (speedBoosting.value && !screenSeeking.value) {
                return IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('speed-boost-indicator'),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fast_forward, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            '2× 播放中',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              if (!screenSeeking.value) {
                return const SizedBox.shrink();
              }
              final target = previewPosition.value ?? current.value.position;
              final delta = target - positionBeforeSeek;
              final forward = !delta.isNegative;
              return IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('screen-seek-indicator'),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 14,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        seekCommitting.value
                            ? const SizedBox.square(
                                dimension: 26,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                forward
                                    ? Icons.fast_forward
                                    : Icons.fast_rewind,
                                color: Colors.white,
                                size: 30,
                              ),
                        const SizedBox(height: 4),
                        Text(
                          formatPlaybackTime(target),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '/ ${formatPlaybackTime(current.value.duration)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          if (fullScreen)
            AnimatedOpacity(
              opacity: controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !controlsVisible,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: const ValueKey('fullscreen-back'),
                            onPressed: _toggleFullScreen,
                            tooltip: '退出全屏',
                            icon: const Icon(Icons.arrow_back),
                          ),
                          Flexible(
                            child: Text(
                              '${widget.video.title} · ${episode.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge([current, screenSeeking]),
                  builder: (_, _) =>
                      current.value.isPlaying || screenSeeking.value
                      ? const SizedBox.shrink()
                      : IconButton.filled(
                          onPressed: _togglePlayback,
                          iconSize: 38,
                          style: IconButton.styleFrom(
                            minimumSize: const Size.square(60),
                            backgroundColor: AppColors.accent,
                            foregroundColor: AppColors.onAccent,
                          ),
                          icon: const Icon(Icons.play_arrow),
                        ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedOpacity(
              opacity: controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !controlsVisible,
                child: Listener(
                  onPointerDown: (_) => _showControls(),
                  child: Container(
                    color: AppColors.scrim,
                    padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        current,
                        previewPosition,
                        seekCommitting,
                      ]),
                      builder: (_, _) => Row(
                        children: [
                          IconButton(
                            onPressed: _togglePlayback,
                            icon: Icon(
                              current.value.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                            ),
                          ),
                          Expanded(
                            child: PlaybackScrubber(
                              position:
                                  previewPosition.value ??
                                  current.value.position,
                              duration: current.value.duration,
                              buffered: current.value.buffered.isEmpty
                                  ? Duration.zero
                                  : current.value.buffered.last.end,
                              enabled:
                                  !failed &&
                                  current.value.isInitialized &&
                                  current.value.duration > Duration.zero &&
                                  !seekCommitting.value,
                              committing: seekCommitting.value,
                              onSeekStart: _seekStart,
                              onSeekUpdate: _seekUpdate,
                              onSeekEnd: _seekEnd,
                              onSeekCancel: _seekCancel,
                            ),
                          ),
                          PopupMenuButton<double>(
                            key: const ValueKey('playback-speed-menu'),
                            tooltip: '播放速度',
                            initialValue: playbackSpeed,
                            onSelected: (speed) =>
                                unawaited(_setPlaybackSpeed(speed)),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 0.5, child: Text('0.5×')),
                              PopupMenuItem(value: 0.75, child: Text('0.75×')),
                              PopupMenuItem(value: 1.0, child: Text('正常')),
                              PopupMenuItem(value: 1.25, child: Text('1.25×')),
                              PopupMenuItem(value: 1.5, child: Text('1.5×')),
                              PopupMenuItem(value: 2.0, child: Text('2×')),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 10,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.speed, size: 21),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${playbackSpeed.toStringAsFixed(playbackSpeed % 1 == 0 ? 0 : 2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}×',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () {
                              _showControls();
                              _toggleFullScreen();
                            },
                            icon: Icon(
                              fullScreen
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _seekStart(Duration target) {
    controlsTimer?.cancel();
    final current = controller;
    if (current == null || isSeeking || seekCommitting.value) return;
    seekGeneration++;
    isSeeking = true;
    positionBeforeSeek = current.value.position;
    wasPlayingBeforeSeek = current.value.isPlaying;
    previewPosition.value = _clampSeekTarget(target, current.value.duration);
    seekPause = wasPlayingBeforeSeek ? current.pause() : Future.value();
  }

  void _screenLongPressStart(LongPressStartDetails details, double width) {
    final current = controller;
    if (current == null ||
        !current.value.isInitialized ||
        current.value.duration <= Duration.zero ||
        isSeeking ||
        seekCommitting.value) {
      return;
    }
    screenSeekStartX = details.localPosition.dx;
    screenSeekStartPosition = current.value.position;
    screenLongPressOnRight = details.localPosition.dx >= width / 2;
    controlsTimer?.cancel();
    if (screenLongPressOnRight && current.value.isPlaying) {
      speedBoosting.value = true;
      longPressSpeedChange = current.setPlaybackSpeed(2);
    }
  }

  void _screenLongPressUpdate(
    LongPressMoveUpdateDetails details,
    double width,
  ) {
    final current = controller;
    if (current == null) return;
    final delta = details.localPosition.dx - screenSeekStartX;
    if (!screenSeeking.value && delta.abs() >= 12) {
      _stopSpeedBoost(current);
      _seekStart(screenSeekStartPosition);
      if (isSeeking) screenSeeking.value = true;
    }
    if (!screenSeeking.value) return;
    _seekUpdate(
      positionFromDragDelta(
        start: screenSeekStartPosition,
        delta: delta,
        width: width,
        duration: current.value.duration,
      ),
    );
  }

  void _screenLongPressEnd() {
    final current = controller;
    if (screenSeeking.value) {
      unawaited(_commitScreenSeek());
    } else {
      _stopSpeedBoost(current);
      _scheduleControlsHide();
    }
  }

  Future<void> _commitScreenSeek() async {
    await _seekEnd(previewPosition.value ?? screenSeekStartPosition);
    if (mounted) screenSeeking.value = false;
  }

  void _screenLongPressCancel() {
    _stopSpeedBoost(controller);
    if (screenSeeking.value) {
      screenSeeking.value = false;
      unawaited(_seekCancel());
    }
  }

  void _stopSpeedBoost(VideoPlayerController? current) {
    if (!speedBoosting.value) return;
    speedBoosting.value = false;
    if (current != null) {
      longPressSpeedChange = longPressSpeedChange.then((_) async {
        if (identical(controller, current)) {
          await current.setPlaybackSpeed(playbackSpeed);
        }
      });
    }
  }

  void _seekUpdate(Duration target) {
    final current = controller;
    if (isSeeking && current != null) {
      previewPosition.value = _clampSeekTarget(target, current.value.duration);
    }
  }

  Future<void> _seekEnd(Duration target) async {
    if (!isSeeking) return;
    final seekController = controller;
    if (seekController == null) {
      _resetSeekState();
      return;
    }
    final generation = seekGeneration;
    final finalTarget = _clampSeekTarget(
      previewPosition.value ?? target,
      seekController.value.duration,
    );
    isSeeking = false;
    previewPosition.value = finalTarget;
    seekCommitting.value = true;
    try {
      await seekPause;
      if (!_isCurrentSeek(seekController, generation)) return;
      if ((finalTarget - positionBeforeSeek).abs() >
          const Duration(milliseconds: 250)) {
        await seekController.seekTo(finalTarget);
      }
      if (!_isCurrentSeek(seekController, generation)) return;
      if (wasPlayingBeforeSeek) await seekController.play();
      if (!_isCurrentSeek(seekController, generation)) return;
      previewPosition.value = null;
      seekCommitting.value = false;
      await _save();
      _scheduleControlsHide();
    } catch (_) {
      if (!_isCurrentSeek(seekController, generation)) return;
      previewPosition.value = positionBeforeSeek;
      seekCommitting.value = false;
      if (wasPlayingBeforeSeek) {
        try {
          await seekController.play();
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('跳转失败，请稍后重试')));
      }
      previewPosition.value = null;
      _scheduleControlsHide();
    }
  }

  Future<void> _seekCancel() async {
    if (!isSeeking) return;
    final seekController = controller;
    final generation = seekGeneration;
    isSeeking = false;
    previewPosition.value = positionBeforeSeek;
    try {
      await seekPause;
      if (_isCurrentSeek(seekController, generation) && wasPlayingBeforeSeek) {
        await seekController?.play();
      }
    } finally {
      if (_isCurrentSeek(seekController, generation)) {
        previewPosition.value = null;
        _scheduleControlsHide();
      }
    }
  }

  bool _isCurrentSeek(VideoPlayerController? target, int generation) =>
      mounted && identical(controller, target) && seekGeneration == generation;

  Duration _clampSeekTarget(Duration target, Duration duration) {
    if (duration <= Duration.zero || target <= Duration.zero) {
      return Duration.zero;
    }
    return target > duration ? duration : target;
  }

  void _resetSeekState() {
    seekGeneration++;
    isSeeking = false;
    wasPlayingBeforeSeek = false;
    positionBeforeSeek = Duration.zero;
    previewPosition.value = null;
    seekCommitting.value = false;
    screenSeeking.value = false;
    speedBoosting.value = false;
    seekPause = Future.value();
  }
}
