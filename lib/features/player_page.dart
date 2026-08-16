import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import '../app/theme.dart';
import '../data/cache/cache_manager.dart';
import '../data/cache/cache_providers.dart';
import '../data/cache/download_providers.dart';
import '../data/cache/download_task_manager.dart';
import '../data/cache/hls_parser.dart';
import '../data/cache/local_proxy.dart';
import '../data/cache/playback_session.dart';
import '../data/history_repository.dart';
import '../data/video_repository.dart';
import '../data/vod_source_registry.dart';
import '../domain/playback_progress.dart';
import '../domain/playback_selection.dart';
import '../domain/playback_source.dart';
import '../domain/playback_status.dart';
import '../domain/video.dart';
import '../domain/watch_record.dart';
import '../shared/playback_scrubber.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.video,
    required this.episode,
    this.resumePosition = Duration.zero,
    this.selection,
  });
  final Video video;
  final Episode episode;
  final Duration resumePosition;
  final PlaybackSelection? selection;
  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  late final HistoryRepository historyRepository;
  VideoPlayerController? controller;
  late Episode episode;
  PlaybackSelection? _selection;
  int setupGeneration = 0;
  PlaybackSession? _activeSession;
  LocalProxyServer? _proxy;
  http.Client? _sessionClient;
  Timer? saveTimer;
  Timer? controlsTimer;
  bool failed = false, fullScreen = false, initializing = true;
  bool controlsVisible = true;
  PlaybackStatus playbackStatus = const PlaybackStatus.preparing();
  bool playbackToggleInFlight = false;
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
  double volumeBeforeMute = 1;
  bool volumeSliderVisible = false;
  double screenBrightness = 0.5;
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

  @override
  void initState() {
    super.initState();
    // Cache provider-backed dependencies while the ConsumerState is mounted.
    // dispose() must not access ref because its BuildContext is deactivated.
    historyRepository = ref.read(historyRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
    episode = widget.episode;
    _selection = widget.selection ?? selectionFor(widget.video, widget.episode);
    _setup(widget.resumePosition);
  }

  Future<void> _setup(Duration resume) async {
    _resetSeekState();
    final generation = ++setupGeneration;
    if (mounted) {
      setState(() {
        failed = false;
        initializing = true;
        playbackStatus = const PlaybackStatus.preparing();
      });
    }
    final target = _selection;
    final directUrl = episode.url;
    PlaybackSession? session;
    var status = const PlaybackStatus(
      mode: PlaybackMode.direct,
      reason: PlaybackFallbackReason.stableIdentityMissing,
    );
    if (target == null || !target.hasStableIdentity) {
      status = const PlaybackStatus(
        mode: PlaybackMode.direct,
        reason: PlaybackFallbackReason.stableIdentityMissing,
      );
    } else if (target.playbackSource.format != PlaybackFormat.hls) {
      status = const PlaybackStatus(
        mode: PlaybackMode.direct,
        reason: PlaybackFallbackReason.unsupportedFormat,
      );
    } else {
      final preparation = await _prepareSession(target, generation);
      session = preparation.session;
      status = preparation.status;
    }
    if (!mounted || generation != setupGeneration) {
      if (session != null) await _closeSession(session);
      return;
    }
    setState(() => playbackStatus = status);
    final proxyUrl = session?.proxyManifestUrl;
    var next = VideoPlayerController.networkUrl(
      Uri.parse(proxyUrl ?? directUrl),
      formatHint:
          (proxyUrl != null || directUrl.toLowerCase().contains('.m3u8'))
          ? VideoFormat.hls
          : null,
    );
    try {
      await next.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || generation != setupGeneration) {
        await next.dispose();
        if (session != null) await _closeSession(session);
        return;
      }
      await _installController(next, session, resume, generation);
    } catch (_) {
      await next.dispose();
      if (session != null) {
        await _closeSession(session);
        session = null;
        _setPlaybackStatus(
          const PlaybackStatus(
            mode: PlaybackMode.direct,
            reason: PlaybackFallbackReason.proxyControllerInitializationFailed,
          ),
          generation: generation,
        );
        next = VideoPlayerController.networkUrl(
          Uri.parse(directUrl),
          formatHint: directUrl.toLowerCase().contains('.m3u8')
              ? VideoFormat.hls
              : null,
        );
        try {
          await next.initialize().timeout(const Duration(seconds: 20));
          if (!mounted || generation != setupGeneration) {
            await next.dispose();
            return;
          }
          await _installController(next, null, resume, generation);
        } catch (_) {
          await next.dispose();
          if (mounted) {
            setState(() {
              failed = true;
              initializing = false;
              errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
            });
          }
        }
      } else if (mounted) {
        setState(() {
          failed = true;
          initializing = false;
          errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
        });
      }
    }
  }

  Future<void> _installController(
    VideoPlayerController next,
    PlaybackSession? session,
    Duration resume,
    int generation,
  ) async {
    // 先完成所有准备（seek/倍速/播放），每次 await 后校验 generation，
    // 最后一次性提交，避免旧任务在提交后反向覆盖新任务。
    final mapping = session?.timelineMapping;
    final target = mapping == null ? resume : mapping.sourceToFiltered(resume);
    if (target > Duration.zero && target < next.value.duration) {
      try {
        await next.seekTo(target);
      } catch (_) {}
    }
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    await next.setPlaybackSpeed(playbackSpeed);
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    await next.play();
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    _activeSession = session;
    controller = next;
    next.addListener(_handlePlayerValueChanged);
    saveTimer?.cancel();
    saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    setState(() => initializing = false);
    _scheduleControlsHide();
    unawaited(_save());
    if (session != null) {
      try {
        final prefetcher = session.buildPrefetcher();
        if (prefetcher != null) {
          unawaited(prefetcher.prefetch(fromPosition: resume));
        }
      } catch (_) {}
    }
  }

  Future<PlaybackSessionPreparation> _prepareSession(
    PlaybackSelection target,
    int generation,
  ) async {
    try {
      final proxy = _proxy ??= LocalProxyServer();
      await proxy.start();
      final client = _sessionClient ??= http.Client();
      CacheManager? cacheManager;
      try {
        cacheManager = await ref.read(cacheManagerProvider.future);
      } catch (_) {}
      return await PlaybackSession.prepare(
        selection: target,
        proxy: proxy,
        parser: HlsParser(client: client),
        client: client,
        cacheManager: cacheManager,
        store: cacheManager?.store,
        onCacheBypass: (reason) {
          _setPlaybackStatus(
            PlaybackStatus(
              mode: PlaybackMode.proxyWithoutCaching,
              reason: reason,
            ),
            generation: generation,
          );
        },
      );
    } catch (_) {
      return const PlaybackSessionPreparation(
        session: null,
        status: PlaybackStatus(
          mode: PlaybackMode.direct,
          reason: PlaybackFallbackReason.proxyStartFailed,
        ),
      );
    }
  }

  void _setPlaybackStatus(PlaybackStatus status, {int? generation}) {
    if (!mounted || (generation != null && generation != setupGeneration)) {
      return;
    }
    setState(() => playbackStatus = status);
  }

  Future<void> _closeActiveSession() async {
    final proxy = _proxy;
    final session = _activeSession;
    _activeSession = null;
    if (session != null && proxy != null) await _closeSession(session);
  }

  Future<void> _closeSession(PlaybackSession session) async {
    final proxy = _proxy;
    if (proxy != null) await session.close(proxy);
  }

  Future<void> _downloadCurrentEpisode() async {
    final selection = _selection;
    if (selection == null || !selection.hasStableIdentity) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前播放源缺少稳定身份，无法下载')));
      }
      return;
    }
    if (selection.playbackSource.format != PlaybackFormat.hls) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前格式不支持下载，仅支持 HLS 视频')));
      }
      return;
    }
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      await manager.enqueue(selection);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已开始下载 ${episode.name}（完成后自动过滤广告）')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('下载任务创建失败，请稍后重试')));
      }
    }
  }

  Future<void> _retry() async {
    // 在关闭会话前，把当前过滤时间轴位置换算成原始时间轴，供重试恢复使用。
    final position = controller?.value.position ?? Duration.zero;
    final mapping = _activeSession?.timelineMapping;
    final oldPosition = mapping == null
        ? position
        : mapping.filteredToSource(position);
    setupGeneration++;
    await _closeActiveSession();
    _resetSeekState();
    setState(() {
      failed = false;
      initializing = true;
      playbackStatus = const PlaybackStatus.preparing();
    });
    try {
      final source = ref
          .read(vodSourceRegistryProvider)
          .maybeWhen(
            data: (r) => r.findById(widget.video.sourceId),
            orElse: () => null,
          );
      if (source == null) throw const VideoDataException('未知来源');
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, widget.video.ref);
      // 优先在稳定线路内按 episodeIdentity 匹配，再退回线路内 name/id，不跨线路。
      final line = fresh.playbackLines
          .where(
            (l) =>
                _selection != null &&
                l.identity == _selection!.playbackLineIdentity,
          )
          .toList();
      final candidates = line.isNotEmpty ? line.first.episodes : fresh.episodes;
      Episode? match;
      if (_selection != null && _selection!.episodeIdentity.isNotEmpty) {
        final byIdentity = candidates.where(
          (item) => item.identity == _selection!.episodeIdentity,
        );
        if (byIdentity.isNotEmpty) match = byIdentity.first;
      }
      match ??= candidates
          .where((item) => item.name == episode.name || item.id == episode.id)
          .firstOrNull;
      if (match == null) {
        throw const VideoDataException('该剧集的播放地址已经失效');
      }
      controller?.removeListener(_handlePlayerValueChanged);
      await controller?.dispose();
      controller = null;
      episode = match;
      _selection = widget.selection ?? selectionFor(widget.video, episode);
      await _setup(oldPosition);
    } catch (e) {
      if (mounted) {
        setState(() {
          failed = true;
          initializing = false;
          playbackStatus = const PlaybackStatus(
            mode: PlaybackMode.direct,
            reason: PlaybackFallbackReason.playbackAddressRefreshFailed,
          );
          errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    final current = controller;
    if (current == null || !current.value.isInitialized || isSeeking) return;
    final mapping = _activeSession?.timelineMapping;
    final positionMs = mapping == null
        ? current.value.position.inMilliseconds
        : mapping.filteredToSource(current.value.position).inMilliseconds;
    final durationMs =
        _activeSession?.originalDurationMs ??
        current.value.duration.inMilliseconds;
    final progress = PlaybackProgress.normalize(
      positionMs: positionMs,
      durationMs: durationMs,
    );
    final record = WatchRecord(
      video: widget.video.copyWith(episodes: const []),
      episodeId: episode.id,
      episodeName: episode.name,
      positionMs: progress.positionMs,
      durationMs: progress.durationMs,
      updatedAt: DateTime.now(),
      completed: progress.completed,
      playbackLineIdentity: _selection?.playbackLineIdentity ?? '',
      episodeIdentity: _selection?.episodeIdentity ?? '',
      filterVersion: _activeSession?.filterVersion ?? 0,
      timelineVersion: _activeSession?.timelineVersion ?? 0,
      manifestFingerprint: _activeSession?.manifestFingerprint,
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

  Future<void> _showPlaybackStatusDetails() async {
    if (!mounted || playbackStatus.mode == PlaybackMode.preparing) return;
    final status = playbackStatus;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202124),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前播放模式',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  PlaybackStatusIndicator.iconFor(
                    status.mode,
                    color: PlaybackStatusIndicator.colorFor(status.mode),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    status.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                status.description,
                style: const TextStyle(color: Colors.white70, height: 1.45),
              ),
              if (status.reasonText != null) ...[
                const SizedBox(height: 8),
                Text(
                  '原因：${status.reasonText}',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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

  Future<void> _switchEpisode(Episode next) async {
    if (next.id == episode.id) return;
    setupGeneration++;
    controlsTimer?.cancel();
    // 先保存进度（此时会话时间轴映射仍可用），再关闭旧会话。
    await _save();
    await _closeActiveSession();
    controller?.removeListener(_handlePlayerValueChanged);
    await controller?.dispose();
    controller = null;
    setState(() => episode = next);
    _selection = selectionFor(widget.video, next) ?? _selection;
    await _setup(Duration.zero);
  }

  void _showControls() {
    controlsTimer?.cancel();
    if (mounted) setState(() => controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    controlsTimer?.cancel();
    setState(() {
      controlsVisible = !controlsVisible;
      if (!controlsVisible) volumeSliderVisible = false;
    });
    if (controlsVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    if (controller?.value.isPlaying != true || isSeeking) return;
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          controlsVisible = false;
          volumeSliderVisible = false;
        });
      }
    });
  }

  Future<void> _togglePlayback() async {
    final current = controller;
    if (current == null || playbackToggleInFlight) return;
    if (!current.value.isPlaying) {
      await _resumePlayback(current);
      return;
    }
    playbackToggleInFlight = true;
    try {
      await current.pause();
      controlsTimer?.cancel();
      unawaited(_save());
      if (mounted) setState(() => controlsVisible = true);
    } finally {
      playbackToggleInFlight = false;
    }
  }

  Future<void> _resumePlayback([VideoPlayerController? target]) async {
    final current = target ?? controller;
    if (current == null || playbackToggleInFlight) return;
    playbackToggleInFlight = true;
    try {
      await current.play();
      _scheduleControlsHide();
      if (mounted) setState(() => controlsVisible = true);
    } finally {
      playbackToggleInFlight = false;
    }
  }

  Future<void> _toggleMute() async {
    final current = controller;
    if (current == null || !current.value.isInitialized) return;
    if (current.value.volume > 0) {
      volumeBeforeMute = current.value.volume;
      await current.setVolume(0);
    } else {
      await current.setVolume(volumeBeforeMute);
    }
    _showControls();
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
    setupGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    saveTimer?.cancel();
    controlsTimer?.cancel();
    unawaited(_save());
    final proxy = _proxy;
    // 先关闭会话（等待活跃读取结束并释放缓存引用），之后才关闭代理。
    unawaited(_closeActiveSession().whenComplete(() => proxy?.close()));
    controller?.removeListener(_handlePlayerValueChanged);
    controller?.dispose();
    _sessionClient?.close();
    previewPosition.dispose();
    seekCommitting.dispose();
    screenSeeking.dispose();
    speedBoosting.dispose();
    verticalDrag.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(_resetScreenBrightness());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 退出全屏时屏幕旋转动画有几帧延迟，期间 MediaQuery 仍是横屏尺寸；
    // 布局按实际方向选择，避免竖屏 Column 布局在横屏尺寸下溢出。
    final landscape =
        fullScreen ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return PopScope(
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
        appBar: landscape
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
        body: landscape
            ? Center(
                child: failed
                    ? _error()
                    : initializing
                    ? const CircularProgressIndicator()
                    : _player(),
              )
            : Column(
                children: [
                  _portraitPlayer(),
                  Expanded(
                    child: PlayerInfoPanel(
                      video: widget.video,
                      current: episode,
                      onEpisodeTap: (e) => unawaited(_switchEpisode(e)),
                    ),
                  ),
                ],
              ),
      ),
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
    return _player();
  }

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
                onVerticalDragStart: (details) =>
                    _screenVerticalDragStart(details, constraints.maxWidth),
                onVerticalDragUpdate: (details) =>
                    _screenVerticalDragUpdate(details, constraints.maxHeight),
                onVerticalDragEnd: (_) => _screenVerticalDragEnd(),
                onVerticalDragCancel: _screenVerticalDragEnd,
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
              verticalDrag,
            ]),
            builder: (_, _) {
              final drag = verticalDrag.value;
              if (drag != null) {
                return IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('vertical-drag-indicator'),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            drag.isVolume
                                ? (drag.value <= 0
                                      ? Icons.volume_off
                                      : drag.value < 0.5
                                      ? Icons.volume_down
                                      : Icons.volume_up)
                                : Icons.brightness_6,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(drag.value * 100).round()}%',
                            style: const TextStyle(
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
          AnimatedBuilder(
            animation: Listenable.merge([current, screenSeeking]),
            builder: (_, _) {
              final paused = !current.value.isPlaying && !screenSeeking.value;
              return AnimatedOpacity(
                opacity: controlsVisible || paused ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !controlsVisible && !paused,
                  child: Center(
                    child: paused
                        ? IconButton.filled(
                            onPressed: _resumePlayback,
                            iconSize: 38,
                            style: IconButton.styleFrom(
                              minimumSize: const Size.square(60),
                              backgroundColor: AppColors.accent,
                              foregroundColor: AppColors.onAccent,
                            ),
                            icon: const Icon(Icons.play_arrow),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              );
            },
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
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xCC000000)],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: AnimatedBuilder(
                        animation: Listenable.merge([
                          current,
                          previewPosition,
                          seekCommitting,
                        ]),
                        builder: (_, _) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PlaybackScrubber(
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
                              showTime: false,
                              onSeekStart: _seekStart,
                              onSeekUpdate: _seekUpdate,
                              onSeekEnd: _seekEnd,
                              onSeekCancel: _seekCancel,
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                              child: Row(
                                children: [
                                  IconButton(
                                    onPressed: _togglePlayback,
                                    iconSize: 30,
                                    icon: Icon(
                                      current.value.isPlaying
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      _showControls();
                                      setState(
                                        () => volumeSliderVisible =
                                            !volumeSliderVisible,
                                      );
                                    },
                                    onLongPress: () => unawaited(_toggleMute()),
                                    tooltip: '音量（长按静音）',
                                    icon: Icon(
                                      current.value.volume > 0.5
                                          ? Icons.volume_up
                                          : current.value.volume > 0
                                          ? Icons.volume_down
                                          : Icons.volume_off,
                                    ),
                                  ),
                                  Text(
                                    '${formatPlaybackTime(previewPosition.value ?? current.value.position)} / ${formatPlaybackTime(current.value.duration)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  PlaybackStatusIndicator(
                                    key: const ValueKey(
                                      'playback-status-indicator',
                                    ),
                                    status: playbackStatus,
                                    onLongPress: _showPlaybackStatusDetails,
                                  ),
                                  if (!fullScreen)
                                    IconButton(
                                      key: const ValueKey(
                                        'player-download-button',
                                      ),
                                      tooltip:
                                          currentDownload?.status ==
                                              DownloadTaskStatus.completed
                                          ? '已下载'
                                          : '下载本集',
                                      onPressed:
                                          currentDownload?.status ==
                                              DownloadTaskStatus.completed
                                          ? null
                                          : _downloadCurrentEpisode,
                                      icon: Icon(
                                        switch (currentDownload?.status) {
                                          DownloadTaskStatus.completed =>
                                            Icons.download_done,
                                          DownloadTaskStatus.downloading =>
                                            Icons.downloading,
                                          DownloadTaskStatus.queued =>
                                            Icons.schedule,
                                          DownloadTaskStatus.paused =>
                                            Icons.pause_circle_outline,
                                          DownloadTaskStatus.failed =>
                                            Icons.refresh,
                                          DownloadTaskStatus.cancelled ||
                                          null => Icons.download_outlined,
                                        },
                                      ),
                                    ),
                                  const Spacer(),
                                  PopupMenuButton<double>(
                                    key: const ValueKey('playback-speed-menu'),
                                    tooltip: '播放速度',
                                    initialValue: playbackSpeed,
                                    onSelected: (speed) =>
                                        unawaited(_setPlaybackSpeed(speed)),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 0.5,
                                        child: Text('0.5×'),
                                      ),
                                      PopupMenuItem(
                                        value: 0.75,
                                        child: Text('0.75×'),
                                      ),
                                      PopupMenuItem(
                                        value: 1.0,
                                        child: Text('正常'),
                                      ),
                                      PopupMenuItem(
                                        value: 1.25,
                                        child: Text('1.25×'),
                                      ),
                                      PopupMenuItem(
                                        value: 1.5,
                                        child: Text('1.5×'),
                                      ),
                                      PopupMenuItem(
                                        value: 2.0,
                                        child: Text('2×'),
                                      ),
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
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (volumeSliderVisible && controlsVisible)
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 46, bottom: 60),
                child: Listener(
                  onPointerDown: (_) => _showControls(),
                  child: AnimatedBuilder(
                    animation: current,
                    builder: (_, _) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        child: SizedBox(
                          height: 140,
                          width: 48,
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              value: current.value.volume.clamp(0.0, 1.0),
                              onChangeStart: (_) => _showControls(),
                              onChanged: (value) {
                                unawaited(current.setVolume(value));
                                if (value > 0) volumeBeforeMute = value;
                                _showControls();
                              },
                            ),
                          ),
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

  void _screenVerticalDragStart(DragStartDetails details, double width) {
    final current = controller;
    if (current == null ||
        !current.value.isInitialized ||
        isSeeking ||
        seekCommitting.value) {
      return;
    }
    final isVolume = details.localPosition.dx >= width / 2;
    verticalDragStartY = details.localPosition.dy;
    verticalDragStartValue = isVolume
        ? current.value.volume.clamp(0.0, 1.0)
        : screenBrightness;
    controlsTimer?.cancel();
    verticalDragGeneration++;
    verticalDrag.value = (isVolume: isVolume, value: verticalDragStartValue);
    if (!isVolume) {
      unawaited(_syncScreenBrightness(verticalDragGeneration));
    }
  }

  Future<void> _syncScreenBrightness(int generation) async {
    try {
      final value = await ScreenBrightness().application;
      if (!mounted || generation != verticalDragGeneration) return;
      screenBrightness = value;
      verticalDragStartValue = value;
      verticalDrag.value = (isVolume: false, value: value);
    } catch (_) {}
  }

  void _screenVerticalDragUpdate(DragUpdateDetails details, double height) {
    final drag = verticalDrag.value;
    if (drag == null || height <= 0) return;
    final delta = (verticalDragStartY - details.localPosition.dy) / height;
    final value = (verticalDragStartValue + delta).clamp(0.0, 1.0);
    verticalDrag.value = (isVolume: drag.isVolume, value: value);
    if (drag.isVolume) {
      final current = controller;
      if (current != null && current.value.isInitialized) {
        unawaited(current.setVolume(value));
        if (value > 0) volumeBeforeMute = value;
      }
    } else {
      screenBrightness = value;
      unawaited(_setScreenBrightness(value));
    }
  }

  Future<void> _setScreenBrightness(double value) async {
    try {
      await ScreenBrightness().setApplicationScreenBrightness(value);
    } catch (_) {}
  }

  Future<void> _resetScreenBrightness() async {
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {}
  }

  void _screenVerticalDragEnd() {
    if (verticalDrag.value == null) return;
    verticalDrag.value = null;
    verticalDragGeneration++;
    _scheduleControlsHide();
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
    verticalDrag.value = null;
    verticalDragGeneration++;
    seekPause = Future.value();
  }
}

class PlaybackStatusIndicator extends StatelessWidget {
  const PlaybackStatusIndicator({
    super.key,
    required this.status,
    required this.onLongPress,
  });

  final PlaybackStatus status;
  final VoidCallback onLongPress;

  static Color colorFor(PlaybackMode mode) {
    switch (mode) {
      case PlaybackMode.preparing:
        return Colors.white54;
      case PlaybackMode.streamingAndCaching:
        return Colors.greenAccent;
      case PlaybackMode.cachePlayback:
        return Colors.lightBlueAccent;
      case PlaybackMode.proxyWithoutCaching:
        return Colors.orangeAccent;
      case PlaybackMode.direct:
        return Colors.white60;
    }
  }

  static Icon iconFor(PlaybackMode mode, {Color? color}) {
    final icon = switch (mode) {
      PlaybackMode.preparing => Icons.sync,
      PlaybackMode.streamingAndCaching => Icons.download,
      PlaybackMode.cachePlayback => Icons.offline_pin,
      PlaybackMode.proxyWithoutCaching => Icons.cloud_off,
      PlaybackMode.direct => Icons.link,
    };
    return Icon(icon, size: 16, color: color ?? colorFor(mode));
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(status.mode);
    return Semantics(
      button: true,
      label: '${status.label}，长按查看详情',
      child: GestureDetector(
        key: const ValueKey('playback-status-gesture'),
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconFor(status.mode, color: color),
              const SizedBox(width: 3),
              Text(
                status.label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 竖屏（非全屏）状态下播放器下方的信息面板：整部简介 + 选集列表。
class PlayerInfoPanel extends StatefulWidget {
  const PlayerInfoPanel({
    super.key,
    required this.video,
    required this.current,
    required this.onEpisodeTap,
  });

  final Video video;
  final Episode current;
  final ValueChanged<Episode> onEpisodeTap;

  @override
  State<PlayerInfoPanel> createState() => _PlayerInfoPanelState();
}

class _PlayerInfoPanelState extends State<PlayerInfoPanel> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        const Text(
          '简介',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          video.description.isEmpty ? '暂无简介' : video.description,
          maxLines: expanded ? null : 4,
          overflow: expanded ? null : TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.55,
          ),
        ),
        if (video.description.length > 100)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => expanded = !expanded),
              child: Text(expanded ? '收起' : '展开'),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '选集（${video.episodes.length}）',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in video.episodes)
              ChoiceChip(
                label: Text(e.name),
                selected: e.id == widget.current.id,
                onSelected: (_) => widget.onEpisodeTap(e),
              ),
          ],
        ),
      ],
    );
  }
}
