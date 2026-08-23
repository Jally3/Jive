import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../app/theme.dart';
import '../data/cache/ad_filter.dart';
import '../data/cache/cache_manager.dart';
import '../data/cache/cache_providers.dart';
import '../data/cache/cache_ttl_policy.dart';
import '../data/cache/content_type_sniffer.dart';
import '../data/cache/download_providers.dart';
import '../data/cache/download_task_manager.dart';
import '../data/cache/hls_parser.dart';
import '../data/cache/local_proxy.dart';
import '../data/cache/playback_session.dart';
import '../data/cache/playback_url_resolver.dart';
import '../data/cache/prefetch_policy.dart';
import '../data/adapters/age_adapter.dart';
import '../data/history_repository.dart';
import '../data/video_repository.dart';
import '../data/vod_source_adapter.dart';
import '../data/vod_source_registry.dart';
import '../domain/playback_progress.dart';
import '../domain/playback_selection.dart';
import '../domain/playback_source.dart';
import '../domain/playback_status.dart';
import '../domain/video.dart';
import '../domain/watch_record.dart';
import '../shared/app_toast.dart';
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
  PlaybackUrlResolver? _urlResolver;
  Timer? saveTimer;
  Timer? controlsTimer;
  Timer? wakelockTimer;
  bool failed = false, fullScreen = false, initializing = true;
  bool fillScreen = false;
  bool controlsVisible = true;
  bool _episodeMenuOpen = false;
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
  final ValueNotifier<bool> seekCommitting = ValueNotifier(false);
  final ValueNotifier<bool> screenSeeking = ValueNotifier(false);
  final ValueNotifier<bool> speedBoosting = ValueNotifier(false);
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

  /// 当前预取目标（领先播放位置的时长），由 prefetchAheadProvider 驱动
  /// （网络类型/开关变化）。
  Duration _prefetchAhead = Duration.zero;

  /// 退出播放器时是否立即清理本次播放的缓存条目（自动清理设置驱动）。
  /// 设置未加载完成前保守起见不清理（默认项是 1 小时后，不退出即清）。
  bool _cleanCacheOnExit = false;

  @override
  void initState() {
    super.initState();
    // Cache provider-backed dependencies while the ConsumerState is mounted.
    // dispose() must not access ref because its BuildContext is deactivated.
    historyRepository = ref.read(historyRepositoryProvider);
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
    WidgetsBinding.instance.addObserver(this);
    episode = widget.episode;
    _selection = widget.selection ?? selectionFor(widget.video, widget.episode);
    unawaited(_loadInitialScreenBrightness());
    unawaited(_setup(widget.resumePosition));
  }

  Future<void> _setup(Duration resume) async {
    _resetSeekState();
    final generation = ++setupGeneration;
    _selection = _bindPlaybackHeaders(_selection);
    if (mounted) {
      setState(() {
        failed = false;
        initializing = true;
        playbackStatus = const PlaybackStatus.preparing();
      });
    }
    try {
      var target = _selection;
      PlaybackSession? session;
      PlaybackStatus? preparedStatus;
      if (target != null) {
        try {
          // Try the cache before resolving an unknown URL through the network.
          // Downloaded HLS endpoints are often extensionless and cannot be
          // reconstructed from the persisted URL alone.
          if (target.playbackSource.format == PlaybackFormat.unknown &&
              target.hasStableIdentity &&
              !target.playbackSource.url.toString().contains('/m3u8/?url=')) {
            final offlinePreparation = await _prepareSession(
              target,
              generation,
            );
            if (offlinePreparation.status.mode == PlaybackMode.cachePlayback &&
                offlinePreparation.session != null) {
              session = offlinePreparation.session;
              target = target.copyWith(
                playbackSource: target.playbackSource.copyWith(
                  format: PlaybackFormat.hls,
                ),
              );
              preparedStatus = offlinePreparation.status;
            }
          }
          if (session == null) {
            target = await _resolvePlaybackSource(target);
            if (!mounted || generation != setupGeneration) return;
            _selection = target;
            episode = target.episode;
          }
        } on PlaybackUrlResolutionException catch (error) {
          if (mounted && generation == setupGeneration) {
            setState(() {
              failed = true;
              initializing = false;
              errorMessage = error.message;
            });
            unawaited(WakelockPlus.disable());
          }
          return;
        }
      }
      final directUrl = target?.episode.url ?? episode.url;
      var status = const PlaybackStatus(
        mode: PlaybackMode.direct,
        reason: PlaybackFallbackReason.stableIdentityMissing,
      );
      if (target == null || !target.hasStableIdentity) {
        status = const PlaybackStatus(
          mode: PlaybackMode.direct,
          reason: PlaybackFallbackReason.stableIdentityMissing,
        );
      } else if (preparedStatus != null) {
        status = preparedStatus;
      } else if (target.playbackSource.format != PlaybackFormat.hls) {
        if (target.playbackSource.format == PlaybackFormat.unknown) {
          final sniffed = await ContentTypeSniffer().sniff(
            target.playbackSource.url.toString(),
          );
          if (sniffed == PlaybackFormat.hls) {
            _selection = target = PlaybackSelection(
              sourceId: target.sourceId,
              sourceVideoId: target.sourceVideoId,
              title: target.title,
              playbackLineIdentity: target.playbackLineIdentity,
              episodeIdentity: target.episodeIdentity,
              episode: target.episode,
              playbackSource: target.playbackSource.copyWith(format: sniffed),
            );
            final preparation = await _prepareSession(target, generation);
            session = preparation.session;
            status = preparation.status;
            if (!mounted || generation != setupGeneration) {
              if (session != null) await _closeSession(session);
              return;
            }
          } else {
            status = const PlaybackStatus(
              mode: PlaybackMode.direct,
              reason: PlaybackFallbackReason.unsupportedFormat,
            );
          }
        } else {
          status = const PlaybackStatus(
            mode: PlaybackMode.direct,
            reason: PlaybackFallbackReason.unsupportedFormat,
          );
        }
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
      final isHls = target?.playbackSource.format == PlaybackFormat.hls;
      final requestHeaders =
          target?.playbackSource.headers ?? const <String, String>{};
      var next = VideoPlayerController.networkUrl(
        Uri.parse(proxyUrl ?? directUrl),
        formatHint:
            (proxyUrl != null ||
                isHls ||
                directUrl.toLowerCase().contains('.m3u8'))
            ? VideoFormat.hls
            : null,
        httpHeaders: proxyUrl == null
            ? filterSessionHeaders(requestHeaders)
            : const {},
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
        if (!mounted || generation != setupGeneration) {
          if (session != null) await _closeSession(session);
          return;
        }
        if (session != null) {
          await _closeSession(session);
          session = null;
          if (!mounted || generation != setupGeneration) return;
          _setPlaybackStatus(
            const PlaybackStatus(
              mode: PlaybackMode.direct,
              reason:
                  PlaybackFallbackReason.proxyControllerInitializationFailed,
            ),
            generation: generation,
          );
          next = VideoPlayerController.networkUrl(
            Uri.parse(directUrl),
            formatHint: (isHls || directUrl.toLowerCase().contains('.m3u8'))
                ? VideoFormat.hls
                : null,
            httpHeaders: filterSessionHeaders(requestHeaders),
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
            if (mounted && generation == setupGeneration) {
              setState(() {
                failed = true;
                initializing = false;
                errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
              });
              unawaited(WakelockPlus.disable());
            }
          }
        } else if (mounted && generation == setupGeneration) {
          setState(() {
            failed = true;
            initializing = false;
            errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
          });
          unawaited(WakelockPlus.disable());
        }
      }
    } catch (error) {
      if (mounted && generation == setupGeneration) {
        setState(() {
          failed = true;
          initializing = false;
          errorMessage = error is PlaybackUrlResolutionException
              ? error.message
              : '视频加载失败，请检查网络后重试';
        });
        unawaited(WakelockPlus.disable());
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
    await next.setVolume(playbackVolume);
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    if (_isAppForeground && _playbackDesired) {
      await next.play();
      if (!mounted || generation != setupGeneration) {
        await next.dispose();
        if (session != null) await _closeSession(session);
        return;
      }
    }
    _activeSession = session;
    controller = next;
    _completionHandled = false;
    next.addListener(_handlePlayerValueChanged);
    setState(() => initializing = false);
    if (fullScreen) unawaited(_syncFullScreenOrientation());
    if (next.value.isPlaying) {
      _startPlaybackTimer();
      _scheduleControlsHide();
    }
    unawaited(_save());
    await _syncWakelock();
    if (next.value.isPlaying) _startWakelockHeartbeat();
    if (session != null) {
      try {
        final prefetcher = session.buildPrefetcher(
          windowSize: () => _prefetchAhead,
        );
        if (prefetcher != null) {
          if (!_isAppForeground) prefetcher.pause();
          unawaited(prefetcher.prefetch(fromPosition: target));
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
        parser: HlsParser(
          client: client,
          // 在线边下边播同样过滤广告分片；隐式 IV 加密流由解析器自动排除。
          adFilter: const AdFilter(enabled: true),
        ),
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

  Future<void> _closeSession(PlaybackSession session) async {
    final proxy = _proxy;
    if (proxy != null) await session.close(proxy);
  }

  ({VideoPlayerController? controller, PlaybackSession? session})
  _detachPlayback() {
    saveTimer?.cancel();
    saveTimer = null;
    wakelockTimer?.cancel();
    wakelockTimer = null;
    final current = controller;
    final session = _activeSession;
    controller = null;
    _activeSession = null;
    current?.removeListener(_handlePlayerValueChanged);
    _pendingVolume = null;
    return (controller: current, session: session);
  }

  Future<void> _disposeDetachedPlayback(
    ({VideoPlayerController? controller, PlaybackSession? session}) playback,
  ) async {
    final current = playback.controller;
    if (current != null) {
      try {
        await current.pause();
      } catch (_) {}
      // video_player 的 dispose 会等待内部 event subscription cancel。
      // 切集/重试必须继续创建下一个 controller，不能被这次释放卡住。
      unawaited(() async {
        try {
          await current.dispose();
        } catch (_) {}
      }());
    }
    final session = playback.session;
    if (session != null) await _closeSession(session);
  }

  Future<void> _downloadCurrentEpisode() async {
    final selection = _selection;
    if (selection == null || !selection.hasStableIdentity) {
      if (mounted) {
        showAppToast(context, '当前播放源缺少稳定身份，无法下载');
      }
      return;
    }
    if (selection.playbackSource.format != PlaybackFormat.hls) {
      if (mounted) {
        showAppToast(context, '当前格式不支持下载，仅支持 HLS 视频');
      }
      return;
    }
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      await manager.enqueue(selection);
      if (mounted) {
        showAppToast(context, '已开始下载 ${episode.name}（自动跳过广告片段）');
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '下载任务创建失败，请稍后重试');
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
    final generation = ++setupGeneration;
    final previousSelection = _selection;
    final previousEpisode = episode;
    final save = _save();
    final detached = _detachPlayback();
    _resetSeekState();
    _playbackDesired = true;
    _completionHandled = false;
    if (!mounted) return;
    setState(() {
      failed = false;
      initializing = true;
      playbackStatus = const PlaybackStatus.preparing();
    });
    try {
      await Future.wait<void>([
        save.catchError((_) {}),
        _disposeDetachedPlayback(detached),
      ]);
      if (!mounted || generation != setupGeneration) return;
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
      if (!mounted || generation != setupGeneration) return;
      final refreshed = refreshSelectionFor(
        freshVideo: fresh,
        priorEpisode: previousEpisode,
        previousSelection: previousSelection,
      );
      if (refreshed == null) {
        throw const VideoDataException('该剧集的播放地址已经失效');
      }
      final resolver = _urlResolver;
      if (resolver != null) {
        if (previousSelection != null) {
          resolver.clearCacheFor(previousSelection.playbackSource.url);
        }
        resolver.clearCacheFor(refreshed.playbackSource.url);
      }
      episode = refreshed.episode;
      _selection = refreshed;
      await _setup(oldPosition);
    } catch (e) {
      if (mounted && generation == setupGeneration) {
        setState(() {
          failed = true;
          initializing = false;
          playbackStatus = const PlaybackStatus(
            mode: PlaybackMode.direct,
            reason: PlaybackFallbackReason.playbackAddressRefreshFailed,
          );
          errorMessage = e.toString();
        });
        unawaited(WakelockPlus.disable());
      }
    }
  }

  /// 播放期定时任务：保存观看进度，并按当前播放位置重锚定预取窗口，
  /// 让预取始终维持在播放点前方一个窗口（seek 后也会在下一拍跟上）。
  void _startPlaybackTimer() {
    saveTimer?.cancel();
    if (!_isAppForeground || controller?.value.isPlaying != true) return;
    saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _onPlaybackTick(),
    );
  }

  void _onPlaybackTick() {
    if (!_isAppForeground || controller?.value.isPlaying != true) return;
    unawaited(_save());
    final current = controller;
    if (current != null && current.value.isInitialized) {
      _activeSession?.prefetcher?.updatePosition(current.value.position);
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
    if (current == null || !mounted) return;
    final value = current.value;
    if (value.hasError && !failed) {
      saveTimer?.cancel();
      saveTimer = null;
      controlsTimer?.cancel();
      wakelockTimer?.cancel();
      wakelockTimer = null;
      _activeSession?.prefetcher?.pause();
      setState(() {
        failed = true;
        initializing = false;
        errorMessage = '播放已中断，请重新获取播放地址后重试';
      });
      unawaited(_syncWakelock());
      return;
    }
    if (fullScreen &&
        value.isInitialized &&
        _isPortraitVideo != _fullScreenLockedPortrait) {
      unawaited(_syncFullScreenOrientation());
    }
    if (value.isCompleted && !_completionHandled) {
      _completionHandled = true;
      final nextEpisode = _adjacentEpisode(1);
      if (nextEpisode != null) {
        // video_player 在 completed 事件里会同步通知 listener；
        // 不能在这里直接 dispose 当前 controller，否则会和内部
        // pause/event subscription 互相等待。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_switchEpisode(nextEpisode));
        });
        return;
      }
      _playbackDesired = false;
      saveTimer?.cancel();
      saveTimer = null;
      controlsTimer?.cancel();
      wakelockTimer?.cancel();
      wakelockTimer = null;
      _activeSession?.prefetcher?.pause();
      setState(() {
        controlsVisible = true;
        volumeSliderVisible = false;
      });
      unawaited(_save());
      unawaited(_syncWakelock());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _isAppForeground = false;
      final generation = ++_lifecycleGeneration;
      final current = controller;
      _stopSpeedBoost(current);
      saveTimer?.cancel();
      saveTimer = null;
      controlsTimer?.cancel();
      _activeSession?.prefetcher?.pause();
      if (current?.value.isPlaying == true) {
        unawaited(() async {
          try {
            await current!.pause();
          } catch (_) {}
          if (!mounted) return;
          if (generation != _lifecycleGeneration &&
              _isAppForeground &&
              _playbackDesired) {
            await _resumePlayback(current);
          } else {
            await _syncWakelock();
          }
        }());
      } else {
        unawaited(_syncWakelock());
      }
      wakelockTimer?.cancel();
      wakelockTimer = null;
      unawaited(_save());
    } else if (state == AppLifecycleState.resumed) {
      _isAppForeground = true;
      _lifecycleGeneration++;
      final prefetcher = _activeSession?.prefetcher;
      final current = controller;
      if (_playbackDesired && prefetcher != null && current != null) {
        prefetcher.resume();
        unawaited(prefetcher.updatePosition(current.value.position));
      } else {
        prefetcher?.pause();
      }
      if (_playbackDesired &&
          current != null &&
          current.value.isInitialized &&
          !current.value.isCompleted) {
        unawaited(_resumePlayback(current));
      } else {
        // The OS can release a wakelock while the app is inactive.
        unawaited(_syncWakelock());
      }
    }
  }

  /// Keeps the screen awake only while this page is actively playing.
  /// Wakelocks may be released by the OS, so this is called at playback and
  /// lifecycle transitions instead of only during setup.
  Future<void> _syncWakelock() async {
    final shouldKeepAwake =
        mounted &&
        _isAppForeground &&
        !failed &&
        controller?.value.isPlaying == true;
    try {
      await WakelockPlus.toggle(enable: shouldKeepAwake);
    } catch (_) {
      // A wakelock failure must not interrupt video playback.
    }
  }

  void _startWakelockHeartbeat() {
    wakelockTimer?.cancel();
    wakelockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted || failed || controller?.value.isPlaying != true) {
        wakelockTimer?.cancel();
        wakelockTimer = null;
        unawaited(_syncWakelock());
        return;
      }
      unawaited(_syncWakelock());
    });
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
    if (!mounted) return;
    if (_fullScreenTransitionInFlight) {
      _fullScreenToggleQueued = !_fullScreenToggleQueued;
      return;
    }
    final previous = fullScreen;
    final target = !previous;
    _fullScreenTransitionInFlight = true;
    setState(() => fullScreen = target);
    final transition = _applyFullScreenSystemUi(target);
    _systemUiTransition = transition;
    try {
      await transition;
    } catch (_) {
      if (mounted) {
        setState(() => fullScreen = previous);
        try {
          final rollback = _applyFullScreenSystemUi(previous);
          _systemUiTransition = rollback;
          await rollback;
        } catch (_) {}
      }
    } finally {
      _fullScreenTransitionInFlight = false;
      if (_fullScreenToggleQueued && mounted) {
        _fullScreenToggleQueued = false;
        unawaited(_toggleFullScreen());
      }
    }
  }

  bool get _isPortraitVideo {
    final ratio = controller?.value.aspectRatio ?? 0;
    return ratio > 0 && ratio < 1;
  }

  bool _overlayLayoutOf(BuildContext context) =>
      fullScreen || MediaQuery.orientationOf(context) == Orientation.landscape;

  Future<void> _syncFullScreenOrientation() async {
    if (!mounted || !fullScreen) return;
    if (_isPortraitVideo == _fullScreenLockedPortrait) return;
    final transition = _applyFullScreenSystemUi(true);
    _systemUiTransition = transition;
    try {
      await transition;
    } catch (_) {}
  }

  Future<void> _applyFullScreenSystemUi(bool enabled) async {
    final portraitVideo = _isPortraitVideo;
    await SystemChrome.setPreferredOrientations(
      enabled
          ? (portraitVideo
                ? const [DeviceOrientation.portraitUp]
                : const [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ])
          : DeviceOrientation.values,
    );
    _fullScreenLockedPortrait = enabled && portraitVideo;
    await SystemChrome.setEnabledSystemUIMode(
      enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  Future<void> _switchEpisode(Episode next) async {
    if (_isSameEpisode(next, episode)) return;
    final nextSelection = _selectionForEpisodeInCurrentLine(next);
    if (_selection != null && nextSelection == null) {
      if (mounted) showAppToast(context, '当前线路没有该剧集');
      return;
    }
    final generation = ++setupGeneration;
    controlsTimer?.cancel();
    final save = _save();
    final detached = _detachPlayback();
    _resetSeekState();
    _playbackDesired = true;
    _completionHandled = false;
    episode = nextSelection?.episode ?? next;
    _selection = _bindPlaybackHeaders(
      nextSelection ?? selectionFor(widget.video, next),
    );
    if (!mounted) return;
    setState(() {
      failed = false;
      initializing = true;
      playbackStatus = const PlaybackStatus.preparing();
    });
    await Future.wait<void>([
      save.catchError((_) {}),
      _disposeDetachedPlayback(detached),
    ]);
    if (!mounted || generation != setupGeneration) return;
    await _setup(Duration.zero);
  }

  Future<PlaybackSelection> _resolvePlaybackSource(
    PlaybackSelection start,
  ) async {
    final client = _sessionClient ??= http.Client();
    final resolver = _urlResolver ??= PlaybackUrlResolver(client: client);
    final tried = <String>{};
    var current = start;
    final registry = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    final source = registry?.findById(current.sourceId);
    final adapter = source == null ? null : registry?.adapterFor(source);
    while (true) {
      tried.add(current.playbackLineIdentity);
      try {
        if (adapter is EpisodePlaybackResolver && source != null) {
          final playable = await adapter.resolveEpisodePlayback(
            source,
            current.episode.url,
          );
          var resolved = current.copyWith(
            episode: Episode(
              id: current.episode.id,
              name: current.episode.name,
              url: playable.url.toString(),
              identity: current.episode.identity,
            ),
            playbackSource: playable,
          );
          if (playable.format == PlaybackFormat.unknown) {
            resolved = await resolver.resolveSelection(resolved);
          }
          return resolved;
        }
        return await resolver.resolveSelection(current);
      } on VideoDataException catch (error) {
        final next = _selectionOnNextLine(current, tried);
        if (next == null) {
          throw PlaybackUrlResolutionException(error.message);
        }
        current = next;
      } on PlaybackUrlResolutionException {
        final next = _selectionOnNextLine(current, tried);
        if (next == null) rethrow;
        current = next;
      }
    }
  }

  PlaybackSelection? _selectionOnNextLine(
    PlaybackSelection current,
    Set<String> tried,
  ) {
    for (final line in widget.video.playbackLines) {
      if (line.identity.isEmpty || tried.contains(line.identity)) continue;
      Episode? matched;
      if (current.episodeIdentity.isNotEmpty) {
        matched = line.episodes
            .where((item) => item.identity == current.episodeIdentity)
            .firstOrNull;
      }
      matched ??= line.episodes
          .where((item) => item.name == current.episode.name)
          .firstOrNull;
      if (matched == null || matched.identity.isEmpty || matched.url.isEmpty) {
        continue;
      }
      return _bindPlaybackHeaders(
        PlaybackSelection(
          sourceId: current.sourceId,
          sourceVideoId: current.sourceVideoId,
          title: current.title,
          playbackLineIdentity: line.identity,
          episodeIdentity: matched.identity,
          episode: matched,
          playbackSource: PlaybackSource(
            url: Uri.tryParse(matched.url) ?? Uri(),
            format: inferPlaybackFormat(matched.url),
          ),
        ),
      );
    }
    return null;
  }

  PlaybackSelection? _bindPlaybackHeaders(PlaybackSelection? selection) {
    if (selection == null) return null;
    if (selection.playbackSource.headers.isNotEmpty) return selection;
    final url = selection.episode.url;
    // AGE resolver pages look like /m3u8/?url=age_…; Mac CMS direct URLs do not.
    if (!url.contains('/m3u8/?url=')) return selection;
    return selection.copyWith(
      playbackSource: selection.playbackSource.copyWith(
        headers: AgeAdapter.sessionHeaders(url),
      ),
    );
  }

  List<Episode> get _lineEpisodes {
    final lineId = _selection?.playbackLineIdentity ?? '';
    if (lineId.isNotEmpty) {
      for (final line in widget.video.playbackLines) {
        if (line.identity == lineId && line.episodes.isNotEmpty) {
          return line.episodes;
        }
      }
    }
    return widget.video.episodes;
  }

  bool _isSameEpisode(Episode left, Episode right) {
    if (left.identity.isNotEmpty && right.identity.isNotEmpty) {
      return left.identity == right.identity;
    }
    return left.id == right.id;
  }

  int get _currentEpisodeIndex {
    final episodes = _lineEpisodes;
    if (episode.identity.isNotEmpty) {
      final byIdentity = episodes.indexWhere(
        (item) => item.identity == episode.identity,
      );
      if (byIdentity >= 0) return byIdentity;
    }
    return episodes.indexWhere(
      (item) => item.id == episode.id || item.name == episode.name,
    );
  }

  Episode? _adjacentEpisode(int delta) {
    final index = _currentEpisodeIndex;
    final episodes = _lineEpisodes;
    final nextIndex = index + delta;
    if (index < 0 || nextIndex < 0 || nextIndex >= episodes.length) {
      return null;
    }
    return episodes[nextIndex];
  }

  Future<void> _switchToAdjacentEpisode(int delta) async {
    final next = _adjacentEpisode(delta);
    if (next == null) return;
    await _switchEpisode(next);
  }

  PlaybackSelection? _selectionForEpisodeInCurrentLine(Episode next) {
    final currentSelection = _selection;
    if (currentSelection == null) return selectionFor(widget.video, next);
    final line = widget.video.playbackLines
        .where((item) => item.identity == currentSelection.playbackLineIdentity)
        .firstOrNull;
    if (line == null || line.identity.isEmpty) return null;
    Episode? matched;
    if (next.identity.isNotEmpty) {
      matched = line.episodes
          .where((item) => item.identity == next.identity)
          .firstOrNull;
    }
    matched ??= line.episodes
        .where((item) => item.name == next.name || item.id == next.id)
        .firstOrNull;
    if (matched == null || matched.identity.isEmpty) return null;
    return PlaybackSelection(
      sourceId: widget.video.sourceId,
      sourceVideoId: widget.video.sourceVideoId,
      title: widget.video.title,
      playbackLineIdentity: line.identity,
      episodeIdentity: matched.identity,
      episode: matched,
      playbackSource: PlaybackSource(
        url: Uri.tryParse(matched.url) ?? Uri(),
        format: inferPlaybackFormat(matched.url),
        headers: currentSelection.playbackSource.headers,
      ),
    );
  }

  void _showControls() {
    controlsTimer?.cancel();
    if (mounted) setState(() => controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    if (_episodeMenuOpen) return;
    controlsTimer?.cancel();
    setState(() {
      controlsVisible = !controlsVisible;
      if (!controlsVisible) volumeSliderVisible = false;
    });
    if (controlsVisible) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    if (controller?.value.isPlaying != true || isSeeking || _episodeMenuOpen) {
      return;
    }
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_episodeMenuOpen) {
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
    _playbackDesired = false;
    playbackToggleInFlight = true;
    try {
      await current.pause();
      if (!mounted || !identical(controller, current)) return;
      await _syncWakelock();
      wakelockTimer?.cancel();
      wakelockTimer = null;
      saveTimer?.cancel();
      saveTimer = null;
      controlsTimer?.cancel();
      _activeSession?.prefetcher?.pause();
      unawaited(_save());
      if (mounted) setState(() => controlsVisible = true);
    } catch (_) {
      _playbackDesired = true;
      if (mounted) showAppToast(context, '暂停失败，请稍后重试');
    } finally {
      playbackToggleInFlight = false;
    }
  }

  Future<void> _resumePlayback([VideoPlayerController? target]) async {
    final current = target ?? controller;
    if (current == null) return;
    _playbackDesired = true;
    if (!_isAppForeground || playbackToggleInFlight) return;
    playbackToggleInFlight = true;
    try {
      if (current.value.isCompleted) {
        await current.seekTo(Duration.zero);
        if (!mounted || !identical(controller, current)) return;
        _completionHandled = false;
      }
      await current.play();
      if (!mounted || !identical(controller, current)) return;
      _activeSession?.prefetcher?.resume();
      unawaited(
        _activeSession?.prefetcher?.updatePosition(current.value.position),
      );
      _startPlaybackTimer();
      await _syncWakelock();
      _startWakelockHeartbeat();
      _scheduleControlsHide();
      if (mounted) setState(() => controlsVisible = true);
    } catch (_) {
      if (mounted) showAppToast(context, '继续播放失败，请稍后重试');
    } finally {
      playbackToggleInFlight = false;
    }
  }

  Future<void> _toggleMute() async {
    final current = controller;
    if (current == null || !current.value.isInitialized) return;
    if (playbackVolume > 0) {
      volumeBeforeMute = playbackVolume;
      _queueVolumeChange(0);
    } else {
      _queueVolumeChange(volumeBeforeMute);
    }
    _showControls();
  }

  void _queueVolumeChange(double value) {
    playbackVolume = value.clamp(0.0, 1.0);
    _pendingVolume = playbackVolume;
    if (!_applyingVolume) unawaited(_drainVolumeChanges());
  }

  Future<void> _drainVolumeChanges() async {
    _applyingVolume = true;
    try {
      while (_pendingVolume != null) {
        final value = _pendingVolume!;
        _pendingVolume = null;
        final current = controller;
        if (current == null || !current.value.isInitialized) continue;
        try {
          await current.setVolume(value);
        } catch (_) {}
      }
    } finally {
      _applyingVolume = false;
      if (_pendingVolume != null) unawaited(_drainVolumeChanges());
    }
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final current = controller;
    if (current == null || !current.value.isInitialized) return;
    try {
      await current.setPlaybackSpeed(speed);
      if (mounted && identical(controller, current)) {
        setState(() => playbackSpeed = speed);
        _showControls();
      }
    } catch (_) {
      if (mounted) showAppToast(context, '倍速切换失败，请稍后重试');
    }
  }

  @override
  void dispose() {
    setupGeneration++;
    _lifecycleGeneration++;
    _isAppForeground = false;
    _playbackDesired = false;
    WidgetsBinding.instance.removeObserver(this);
    saveTimer?.cancel();
    controlsTimer?.cancel();
    wakelockTimer?.cancel();
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
    seekCommitting.dispose();
    screenSeeking.dispose();
    speedBoosting.dispose();
    verticalDrag.dispose();
    unawaited(() async {
      try {
        await _systemUiTransition;
      } catch (_) {}
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }());
    unawaited(_resetScreenBrightness());
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 沉浸式 overlay：全屏，或设备本身是横屏（iPad 横屏未全屏）。
    // 退出横屏全屏时旋转动画有几帧延迟，期间 MediaQuery 仍可能是横屏尺寸，
    // 用 overlay 避免竖屏 Column 在横屏尺寸下溢出。
    final overlayLayout = _overlayLayoutOf(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (fullScreen) {
          unawaited(_toggleFullScreen());
          return;
        }
        unawaited(_saveAndPop());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
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
                        (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(
                          0.0,
                          1.0,
                        ),
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
        body: overlayLayout
            ? _overlayBody()
            : Column(
                children: [
                  _portraitPlayer(),
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
    );
  }

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
    Navigator.of(context).pop<Episode>(episode);
  }

  Widget _overlayBody() {
    final showStandaloneBack = failed || initializing;
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: failed
              ? SingleChildScrollView(child: _error())
              : initializing
              ? const CircularProgressIndicator()
              : _player(),
        ),
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
        Positioned(
          left: 24,
          top: 0,
          right: 0,
          bottom: 0,
          child: LayoutBuilder(
            builder: (_, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _togglePlayback,
              onHorizontalDragStart: _screenHorizontalDragStart,
              onHorizontalDragUpdate: (details) =>
                  _screenHorizontalDragUpdate(details, constraints.maxWidth),
              onHorizontalDragEnd: (_) => _screenHorizontalDragEnd(),
              onHorizontalDragCancel: _screenHorizontalDragCancel,
              onLongPressStart: (details) =>
                  _screenLongPressStart(details, constraints.maxWidth),
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
          animation: Listenable.merge([current, screenSeeking, seekCommitting]),
          builder: (_, _) {
            if (!current.value.isBuffering ||
                screenSeeking.value ||
                seekCommitting.value) {
              return const SizedBox.shrink();
            }
            return IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('player-buffering-indicator'),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            );
          },
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
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                              forward ? Icons.fast_forward : Icons.fast_rewind,
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
        // Overlay 布局没有 AppBar（全屏或 iPad 横屏未全屏），
        // 统一由播放器内顶栏提供返回和标题。
        if (overlayLayout)
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: Align(
                alignment: Alignment.topLeft,
                child: SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey('fullscreen-back'),
                          onPressed: fullScreen
                              ? _toggleFullScreen
                              : () => unawaited(_saveAndPop()),
                          tooltip: fullScreen ? '退出全屏' : '返回',
                          icon: const Icon(Icons.arrow_back),
                        ),
                        Flexible(
                          child: Text(
                            '${widget.video.title} · ${episode.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: false,
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
                        builder: (_, _) {
                          final timeAboveScrubber =
                              fullScreen &&
                              MediaQuery.orientationOf(context) ==
                                  Orientation.portrait;
                          final positionLabel = Text(
                            key: const ValueKey('player-position-label'),
                            '${formatPlaybackTime(previewPosition.value ?? current.value.position)} / ${formatPlaybackTime(current.value.duration)}',
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          );
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (timeAboveScrubber)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    0,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: positionLabel,
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: PlaybackScrubber(
                                  position:
                                      previewPosition.value ??
                                      current.value.position,
                                  duration: current.value.duration,
                                  buffered: [
                                    for (final range in current.value.buffered)
                                      (start: range.start, end: range.end),
                                  ],
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
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  6,
                                ),
                                child: Row(
                                  children: [
                                    if (showEpisodeNav)
                                      IconButton(
                                        key: const ValueKey(
                                          'player-previous-episode',
                                        ),
                                        tooltip: '上一集',
                                        onPressed: _adjacentEpisode(-1) == null
                                            ? null
                                            : () {
                                                _showControls();
                                                unawaited(
                                                  _switchToAdjacentEpisode(-1),
                                                );
                                              },
                                        icon: const Icon(Icons.skip_previous),
                                      ),
                                    IconButton(
                                      onPressed: _togglePlayback,
                                      tooltip: current.value.isPlaying
                                          ? '暂停'
                                          : current.value.isCompleted
                                          ? '重新播放'
                                          : '播放',
                                      iconSize: 30,
                                      icon: Icon(
                                        current.value.isPlaying
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                      ),
                                    ),
                                    if (showEpisodeNav)
                                      IconButton(
                                        key: const ValueKey(
                                          'player-next-episode',
                                        ),
                                        tooltip: '下一集',
                                        onPressed: _adjacentEpisode(1) == null
                                            ? null
                                            : () {
                                                _showControls();
                                                unawaited(
                                                  _switchToAdjacentEpisode(1),
                                                );
                                              },
                                        icon: const Icon(Icons.skip_next),
                                      ),
                                    if (!compactControls)
                                      IconButton(
                                        onPressed: () {
                                          _showControls();
                                          setState(
                                            () => volumeSliderVisible =
                                                !volumeSliderVisible,
                                          );
                                        },
                                        onLongPress: () =>
                                            unawaited(_toggleMute()),
                                        tooltip: '音量（长按静音）',
                                        icon: Icon(
                                          current.value.volume > 0.5
                                              ? Icons.volume_up
                                              : current.value.volume > 0
                                              ? Icons.volume_down
                                              : Icons.volume_off,
                                        ),
                                      ),
                                    if (timeAboveScrubber)
                                      const Spacer()
                                    else
                                      Expanded(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          alignment: Alignment.centerLeft,
                                          child: positionLabel,
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
                                    PopupMenuButton<double>(
                                      key: const ValueKey(
                                        'playback-speed-menu',
                                      ),
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
                                    if (showEpisodeNav)
                                      PopupMenuButton<Episode>(
                                        key: const ValueKey(
                                          'player-episode-menu',
                                        ),
                                        tooltip: '选集',
                                        constraints: const BoxConstraints(
                                          maxHeight: 320,
                                          minWidth: 128,
                                        ),
                                        onOpened: () {
                                          controlsTimer?.cancel();
                                          setState(
                                            () => _episodeMenuOpen = true,
                                          );
                                        },
                                        onCanceled: () {
                                          if (!mounted) return;
                                          setState(
                                            () => _episodeMenuOpen = false,
                                          );
                                          _scheduleControlsHide();
                                        },
                                        onSelected: (next) {
                                          setState(
                                            () => _episodeMenuOpen = false,
                                          );
                                          unawaited(_switchEpisode(next));
                                          _scheduleControlsHide();
                                        },
                                        itemBuilder: (_) {
                                          final episodes = _lineEpisodes;
                                          return [
                                            for (final item in episodes)
                                              PopupMenuItem(
                                                value: item,
                                                child: Text(
                                                  item.name,
                                                  style: TextStyle(
                                                    fontWeight:
                                                        _isSameEpisode(
                                                          item,
                                                          episode,
                                                        )
                                                        ? FontWeight.w700
                                                        : FontWeight.w400,
                                                    color:
                                                        _isSameEpisode(
                                                          item,
                                                          episode,
                                                        )
                                                        ? AppColors.accent
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                          ];
                                        },
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 10,
                                          ),
                                          child: Text(
                                            '选集',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (overlayLayout &&
                                        !compactControls &&
                                        !(fullScreen && _isPortraitVideo))
                                      IconButton(
                                        onPressed: () {
                                          _showControls();
                                          setState(
                                            () => fillScreen = !fillScreen,
                                          );
                                          if (fillScreen) {
                                            showAppToast(
                                              context,
                                              '已切换为铺满模式，画面边缘可能被裁剪',
                                            );
                                          }
                                        },
                                        tooltip: fillScreen ? '适应' : '铺满',
                                        icon: Icon(
                                          fillScreen
                                              ? Icons.fit_screen
                                              : Icons.crop_free,
                                        ),
                                      ),
                                    // 横屏片在 iPad 横屏已经是横屏布局，全屏按钮没有作用。
                                    // 竖屏片即使当前是设备横屏，全屏也会转到竖屏展开。
                                    if (fullScreen ||
                                        MediaQuery.orientationOf(context) ==
                                            Orientation.portrait ||
                                        _isPortraitVideo)
                                      IconButton(
                                        tooltip: fullScreen ? '退出全屏' : '进入全屏',
                                        onPressed: () {
                                          _showControls();
                                          unawaited(_toggleFullScreen());
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
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Paint the paused-state button after the bottom controls so it
        // remains visible in the non-fullscreen player.
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
                          tooltip: current.value.isCompleted ? '重新播放' : '播放',
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
        if (!compactControls && volumeSliderVisible && controlsVisible)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.only(
                left:
                    46 +
                    (overlayLayout
                        ? MediaQuery.viewPaddingOf(context).left
                        : 0),
                bottom:
                    60 +
                    (overlayLayout
                        ? MediaQuery.viewPaddingOf(context).bottom
                        : 0),
              ),
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
                              _queueVolumeChange(value);
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
    );
    if (cover) return SizedBox.expand(child: stack);
    return AspectRatio(
      aspectRatio: portrait ? 16 / 9 : aspectRatio,
      child: stack,
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
      longPressSpeedChange = current.setPlaybackSpeed(2).catchError((_) {});
    }
  }

  void _screenHorizontalDragStart(DragStartDetails details) {
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
    controlsTimer?.cancel();
    _seekStart(screenSeekStartPosition);
    if (isSeeking) screenSeeking.value = true;
  }

  void _screenHorizontalDragUpdate(DragUpdateDetails details, double width) {
    final current = controller;
    if (current == null || !screenSeeking.value) return;
    final delta = details.localPosition.dx - screenSeekStartX;
    _seekUpdate(
      positionFromDragDelta(
        start: screenSeekStartPosition,
        delta: delta,
        width: width,
        duration: current.value.duration,
      ),
    );
  }

  void _screenHorizontalDragEnd() {
    if (!screenSeeking.value) {
      _scheduleControlsHide();
      return;
    }
    unawaited(_commitScreenSeek());
  }

  void _screenHorizontalDragCancel() {
    if (!screenSeeking.value) return;
    screenSeeking.value = false;
    unawaited(_seekCancel());
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
    verticalDragStartValue = isVolume ? playbackVolume : screenBrightness;
    verticalDragHasUpdated = false;
    controlsTimer?.cancel();
    verticalDragGeneration++;
    verticalDrag.value = (isVolume: isVolume, value: verticalDragStartValue);
    if (!isVolume && !screenBrightnessLoaded) {
      unawaited(_syncScreenBrightness(verticalDragGeneration));
    }
  }

  Future<void> _loadInitialScreenBrightness() async {
    try {
      final value = await ScreenBrightness().application;
      if (!mounted || verticalDrag.value != null) return;
      screenBrightness = value;
      screenBrightnessLoaded = true;
    } catch (_) {}
  }

  Future<void> _syncScreenBrightness(int generation) async {
    try {
      final value = await ScreenBrightness().application;
      if (!mounted ||
          generation != verticalDragGeneration ||
          verticalDragHasUpdated) {
        return;
      }
      screenBrightness = value;
      screenBrightnessLoaded = true;
      verticalDragStartValue = value;
      verticalDrag.value = (isVolume: false, value: value);
    } catch (_) {}
  }

  void _screenVerticalDragUpdate(DragUpdateDetails details, double height) {
    final drag = verticalDrag.value;
    if (drag == null || height <= 0) return;
    final delta = (verticalDragStartY - details.localPosition.dy) / height;
    final value = (verticalDragStartValue + delta).clamp(0.0, 1.0);
    verticalDragHasUpdated = true;
    verticalDrag.value = (isVolume: drag.isVolume, value: value);
    if (drag.isVolume) {
      final current = controller;
      if (current != null && current.value.isInitialized) {
        _queueVolumeChange(value);
        if (value > 0) volumeBeforeMute = value;
      }
    } else {
      screenBrightness = value;
      screenBrightnessLoaded = true;
      _queueBrightnessChange(value);
    }
  }

  void _queueBrightnessChange(double value) {
    _pendingBrightness = value.clamp(0.0, 1.0);
    if (_applyingBrightness) return;
    final task = _drainBrightnessChanges();
    _brightnessChangeTask = task;
    unawaited(task);
  }

  Future<void> _drainBrightnessChanges() async {
    _applyingBrightness = true;
    try {
      while (_pendingBrightness != null) {
        final value = _pendingBrightness!;
        _pendingBrightness = null;
        try {
          await ScreenBrightness().setApplicationScreenBrightness(value);
        } catch (_) {}
      }
    } finally {
      _applyingBrightness = false;
      if (_pendingBrightness != null) {
        final task = _drainBrightnessChanges();
        _brightnessChangeTask = task;
        unawaited(task);
      }
    }
  }

  Future<void> _resetScreenBrightness() async {
    _pendingBrightness = null;
    try {
      await _brightnessChangeTask;
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
      longPressSpeedChange = longPressSpeedChange.catchError((_) {}).then((
        _,
      ) async {
        if (identical(controller, current)) {
          try {
            await current.setPlaybackSpeed(playbackSpeed);
          } catch (_) {}
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
      if (finalTarget < seekController.value.duration) {
        _completionHandled = false;
      }
      if (wasPlayingBeforeSeek && _isAppForeground && _playbackDesired) {
        await seekController.play();
      }
      if (!_isCurrentSeek(seekController, generation)) return;
      previewPosition.value = null;
      seekCommitting.value = false;
      await _save();
      // seek 成功后立即按新位置重排预取窗口，不等下一次定时拍。
      unawaited(_activeSession?.prefetcher?.updatePosition(finalTarget));
      if (seekController.value.isPlaying) {
        _startPlaybackTimer();
        _startWakelockHeartbeat();
      }
      unawaited(_syncWakelock());
      _scheduleControlsHide();
    } catch (_) {
      if (!_isCurrentSeek(seekController, generation)) return;
      previewPosition.value = positionBeforeSeek;
      seekCommitting.value = false;
      if (wasPlayingBeforeSeek && _isAppForeground && _playbackDesired) {
        try {
          await seekController.play();
        } catch (_) {}
      }
      if (mounted) {
        showAppToast(context, '跳转失败，请稍后重试');
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
      if (_isCurrentSeek(seekController, generation) &&
          wasPlayingBeforeSeek &&
          _isAppForeground &&
          _playbackDesired) {
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

/// 播放链路状态指示：视觉上只有一个彩色小圆点，不打断观看；
/// 长按弹出「当前播放模式」详情底栏（含降级原因），语义标签保留完整状态文案。
class PlaybackStatusIndicator extends StatelessWidget {
  const PlaybackStatusIndicator({
    super.key,
    required this.status,
    required this.onLongPress,
  });

  final PlaybackStatus status;
  final VoidCallback onLongPress;

  /// 圆点颜色与播放状态的对应关系：
  /// - 灰  preparing：会话建立中；
  /// - 绿  streamingAndCaching：走本地代理且分片正在写穿缓存（边下边播）；
  /// - 蓝  cachePlayback：命中完整缓存离线播放，零流量；
  /// - 橙  proxyWithoutCaching：走代理但缓存不可用（如配额已满）；
  /// - 白灰 direct：回退直连（直播、加密流或 manifest 解析失败）。
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
      // 语义层保留完整状态文案（如「边下边播」），供无障碍与长按详情使用。
      label: '${status.label}，长按查看详情',
      onLongPress: onLongPress,
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const ValueKey('playback-status-gesture'),
          onLongPress: onLongPress,
          behavior: HitTestBehavior.opaque,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              // 视觉元素保持为 8px 圆点，交互热区扩大到 48px。
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
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
  /// 剧集超过该数量时按每组 100 集折叠展示，与详情页一致。
  static const int _epsGroupSize = 100;

  bool expanded = false;
  late Set<int> _expandedEpsGroups;

  int get _currentIndex =>
      indexOfEpisode(widget.video.episodes, widget.current) ?? 0;

  @override
  void initState() {
    super.initState();
    _expandedEpsGroups = {_groupOf(_currentIndex)};
  }

  @override
  void didUpdateWidget(PlayerInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current.identity != widget.current.identity ||
        oldWidget.current.id != widget.current.id ||
        oldWidget.current.name != widget.current.name ||
        oldWidget.video.episodes.length != widget.video.episodes.length) {
      _expandedEpsGroups.add(_groupOf(_currentIndex));
    }
  }

  int _groupOf(int index) {
    final last = math.max(widget.video.episodes.length - 1, 0);
    return index.clamp(0, last) ~/ _epsGroupSize;
  }

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
        if (video.episodes.length <= _epsGroupSize)
          _epsWrap(video.episodes, 0, video.episodes.length)
        else
          _epsGroups(video.episodes),
      ],
    );
  }

  Widget _epsGroups(List<Episode> episodes) {
    final total = episodes.length;
    final groupCount = (total + _epsGroupSize - 1) ~/ _epsGroupSize;
    return Column(
      children: [
        for (var g = 0; g < groupCount; g++) ...[
          _epsGroupHeader(total, g),
          if (_expandedEpsGroups.contains(g))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _epsWrap(
                episodes,
                g * _epsGroupSize,
                math.min((g + 1) * _epsGroupSize, total),
              ),
            ),
        ],
      ],
    );
  }

  Widget _epsGroupHeader(int total, int group) {
    final start = group * _epsGroupSize;
    final end = math.min(start + _epsGroupSize, total);
    final isExpanded = _expandedEpsGroups.contains(group);
    return InkWell(
      onTap: () => setState(() {
        if (isExpanded) {
          _expandedEpsGroups.remove(group);
        } else {
          _expandedEpsGroups.add(group);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '第 ${start + 1}–$end 集',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondary,
                ),
              ),
            ),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: AppColors.secondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _epsWrap(List<Episode> episodes, int start, int end) {
    final selectedIndex = _currentIndex;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var idx = start; idx < end; idx++)
          ChoiceChip(
            label: Text(episodes[idx].name),
            selected: idx == selectedIndex,
            selectedColor: AppColors.accent,
            labelStyle: TextStyle(
              color: idx == selectedIndex
                  ? AppColors.onAccent
                  : AppColors.secondary,
            ),
            showCheckmark: false,
            onSelected: (_) => widget.onEpisodeTap(episodes[idx]),
          ),
      ],
    );
  }
}
