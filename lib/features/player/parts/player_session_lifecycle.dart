part of '../player_page.dart';

/// 会话建立与降级：解析播放地址（缓存优先 → 代理 HLS → 直链回退）、
/// 安装控制器、切换/重试时安全地释放旧播放资源。
mixin PlayerSessionLifecycle on PlayerStateBase {
  @override
  Future<void> _setup(Duration resume) => _setupAttempt(resume);

  Future<void> _setupAttempt(
    Duration resume, {
    bool refreshAttempted = false,
  }) async {
    if (_startupTrace == null || _startupTrace!.isFinished) {
      _startupTrace = PlaybackStartupTrace.maybeStart(
        videoTitle: widget.video.title,
        sourceId: widget.video.sourceId,
        sourceVideoId: widget.video.sourceVideoId,
        episode: episode,
        offlineOnly: widget.offlineOnly,
      );
    }
    final startupTrace = _startupTrace;
    startupTrace?.updateEpisode(episode);
    _lockButtonTimer?.cancel();
    _screenLocked = false;
    _lockButtonVisible = true;
    _observedDuration = Duration.zero;
    _introSkipped = false;
    _outroSkipped = false;
    _introDecisionPosition = Duration.zero;
    _resetSeekState();
    final generation = ++setupGeneration;
    _selection = _bindPlaybackHeaders(_selection);
    final skipPolicyLoad = startupTrace?.startStage(
      PlaybackTraceStage.skipPolicyLoad,
    );
    await _loadSkipPolicy();
    startupTrace?.finishStage(skipPolicyLoad);
    if (!mounted || generation != setupGeneration) return;
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
      int? addressHttpStatusCode;
      if (target != null) {
        try {
          if (widget.offlineOnly) {
            final sessionPrepare = startupTrace?.startStage(
              PlaybackTraceStage.hlsSessionPrepare,
              metadata: const {'kind': 'offlineOnly'},
            );
            final preparation = await _prepareSession(
              target,
              generation,
              offlineOnly: true,
            );
            startupTrace?.finishStage(
              sessionPrepare,
              result: preparation.session == null ? 'miss' : 'success',
              metadata: {'mode': preparation.status.mode.name},
            );
            if (preparation.session == null ||
                preparation.status.mode != PlaybackMode.cachePlayback) {
              if (mounted && generation == setupGeneration) {
                setState(() {
                  failed = true;
                  initializing = false;
                  errorMessage = '该集离线文件不完整，请重新下载';
                });
              }
              startupTrace?.fail(
                StateError('offline cache is incomplete'),
                failedStage: PlaybackTraceStage.hlsSessionPrepare,
              );
              return;
            }
            session = preparation.session;
            preparedStatus = preparation.status;
            target = target.copyWith(
              playbackSource: target.playbackSource.copyWith(
                format: PlaybackFormat.hls,
              ),
            );
          }
          // Try the cache before resolving an unknown URL through the network.
          // Downloaded HLS endpoints are often extensionless and cannot be
          // reconstructed from the persisted URL alone.
          if (!widget.offlineOnly &&
              target.playbackSource.format == PlaybackFormat.unknown &&
              target.hasStableIdentity &&
              !target.playbackSource.url.toString().contains('/m3u8/?url=')) {
            final unknownPrecheck = startupTrace?.startStage(
              PlaybackTraceStage.unknownCachePrecheck,
            );
            final offlinePreparation = await _prepareSession(
              target,
              generation,
            );
            startupTrace?.finishStage(
              unknownPrecheck,
              result: offlinePreparation.status.mode.name,
              metadata: {'sessionCreated': offlinePreparation.session != null},
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
          if (!widget.offlineOnly && session == null) {
            final sourceResolve = startupTrace?.startStage(
              PlaybackTraceStage.playbackSourceResolve,
            );
            target = await _resolvePlaybackSource(target);
            startupTrace?.finishStage(sourceResolve);
            if (!mounted || generation != setupGeneration) return;
            _selection = target;
            episode = target.episode;
            startupTrace?.updateEpisode(episode);
          }
        } on PlaybackUrlResolutionException catch (error) {
          if (!refreshAttempted &&
              await _refreshRejectedAddress(error.httpStatusCode, generation)) {
            if (mounted && generation == setupGeneration) {
              await _setupAttempt(resume, refreshAttempted: true);
            }
            return;
          }
          if (mounted && generation == setupGeneration) {
            setState(() {
              failed = true;
              initializing = false;
              errorMessage = error.message;
            });
            unawaited(screenAwakeController.release(screenAwakeOwner));
          }
          startupTrace?.fail(
            error,
            failedStage: PlaybackTraceStage.playbackSourceResolve,
          );
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
          final contentTypeSniff = startupTrace?.startStage(
            PlaybackTraceStage.contentTypeSniff,
          );
          final sniffed = await ContentTypeSniffer().sniff(
            target.playbackSource.url.toString(),
          );
          startupTrace?.finishStage(contentTypeSniff, result: sniffed.name);
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
            final sessionPrepare = startupTrace?.startStage(
              PlaybackTraceStage.hlsSessionPrepare,
            );
            final preparation = await _prepareSession(target, generation);
            startupTrace?.finishStage(
              sessionPrepare,
              result: preparation.status.mode.name,
            );
            session = preparation.session;
            status = preparation.status;
            addressHttpStatusCode = preparation.addressHttpStatusCode;
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
        final sessionPrepare = startupTrace?.startStage(
          PlaybackTraceStage.hlsSessionPrepare,
        );
        final preparation = await _prepareSession(target, generation);
        startupTrace?.finishStage(
          sessionPrepare,
          result: preparation.status.mode.name,
        );
        session = preparation.session;
        status = preparation.status;
        addressHttpStatusCode = preparation.addressHttpStatusCode;
      }
      if (!mounted || generation != setupGeneration) {
        if (session != null) await _closeSession(session);
        return;
      }
      if (!refreshAttempted &&
          await _refreshRejectedAddress(addressHttpStatusCode, generation)) {
        if (mounted && generation == setupGeneration) {
          await _setupAttempt(resume, refreshAttempted: true);
        }
        return;
      }
      setState(() => playbackStatus = status);
      final proxyUrl = session?.proxyManifestUrl;
      final isHls = target?.playbackSource.format == PlaybackFormat.hls;
      final requestHeaders =
          target?.playbackSource.headers ?? const <String, String>{};
      startupTrace?.updatePlayback(
        format: target?.playbackSource.format.name,
        mode: status.mode.name,
        usedProxy: proxyUrl != null,
      );
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
      PlaybackTraceSpan? controllerInitialize = startupTrace?.startStage(
        proxyUrl == null
            ? PlaybackTraceStage.controllerInitializeDirect
            : PlaybackTraceStage.controllerInitializeProxy,
      );
      try {
        await next.initialize().timeout(const Duration(seconds: 20));
        startupTrace?.finishStage(controllerInitialize);
        controllerInitialize = null;
        if (!mounted || generation != setupGeneration) {
          await next.dispose();
          if (session != null) await _closeSession(session);
          return;
        }
        await _installController(next, session, resume, generation);
      } catch (error) {
        startupTrace?.finishStage(
          controllerInitialize,
          result: 'failed',
          metadata: {'errorType': error.runtimeType.toString()},
        );
        await next.dispose();
        if (!mounted || generation != setupGeneration) {
          if (session != null) await _closeSession(session);
          return;
        }
        if (session != null && widget.offlineOnly) {
          await _closeSession(session);
          session = null;
        }
        if (session != null && !widget.offlineOnly) {
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
          final directInitialize = startupTrace?.startStage(
            PlaybackTraceStage.controllerInitializeDirect,
          );
          try {
            await next.initialize().timeout(const Duration(seconds: 20));
            startupTrace?.finishStage(directInitialize);
            if (!mounted || generation != setupGeneration) {
              await next.dispose();
              return;
            }
            await _installController(next, null, resume, generation);
          } catch (directError) {
            startupTrace?.finishStage(
              directInitialize,
              result: 'failed',
              metadata: {'errorType': directError.runtimeType.toString()},
            );
            await next.dispose();
            if (mounted && generation == setupGeneration) {
              setState(() {
                failed = true;
                initializing = false;
                errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
              });
              unawaited(screenAwakeController.release(screenAwakeOwner));
            }
            startupTrace?.fail(
              directError,
              failedStage: PlaybackTraceStage.controllerInitializeDirect,
            );
          }
        } else if (mounted && generation == setupGeneration) {
          setState(() {
            failed = true;
            initializing = false;
            errorMessage = '无法播放当前视频，请重试或返回选择其他剧集';
          });
          unawaited(screenAwakeController.release(screenAwakeOwner));
          startupTrace?.fail(
            error,
            failedStage: proxyUrl == null
                ? PlaybackTraceStage.controllerInitializeDirect
                : PlaybackTraceStage.controllerInitializeProxy,
          );
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
        unawaited(screenAwakeController.release(screenAwakeOwner));
      }
      startupTrace?.fail(error);
    }
  }

  /// Structured HTTP failures can indicate an expired cached MacCMS address.
  /// Native error strings are not used to guess expiry; those use explicit retry.
  Future<bool> _refreshRejectedAddress(int? statusCode, int generation) async {
    if (widget.offlineOnly ||
        !const {401, 403, 404, 410}.contains(statusCode) ||
        !mounted ||
        generation != setupGeneration) {
      return false;
    }
    final registry = ref.read(vodSourceRegistryProvider).value;
    final source = registry?.findById(widget.video.sourceId);
    if (source == null ||
        registry?.adapterFor(source) is! ReusablePlaybackDetailAdapter) {
      return false;
    }
    final previousSelection = _selection;
    final previousEpisode = episode;
    final fresh = await ref
        .read(videoRepositoryProvider)
        .resolvePlayback(source, widget.video.ref, forceRefresh: true);
    if (!mounted || generation != setupGeneration) return true;
    final refreshed = refreshSelectionFor(
      freshVideo: fresh,
      priorEpisode: previousEpisode,
      previousSelection: previousSelection,
    );
    if (refreshed == null) {
      throw const VideoDataException('该剧集的播放地址已经失效');
    }
    if (previousSelection != null) {
      _urlResolver?.clearCacheFor(previousSelection.playbackSource.url);
    }
    _urlResolver?.clearCacheFor(refreshed.playbackSource.url);
    episode = refreshed.episode;
    _selection = refreshed;
    return true;
  }

  Future<void> _installController(
    VideoPlayerController next,
    PlaybackSession? session,
    Duration resume,
    int generation,
  ) async {
    final startupTrace = _startupTrace;
    final configure = startupTrace?.startStage(
      PlaybackTraceStage.controllerConfigure,
    );
    // 先完成所有准备（seek/倍速/播放），每次 await 后校验 generation，
    // 最后一次性提交，避免旧任务在提交后反向覆盖新任务。
    final mapping = session?.timelineMapping;
    var target = mapping == null ? resume : mapping.sourceToFiltered(resume);
    _introDecisionPosition = target;
    if (shouldSkipIntro(
      introSeconds: _skipPolicy.introSeconds,
      position: target,
      duration: next.value.duration,
    )) {
      target = Duration(seconds: _skipPolicy.introSeconds);
      _introSkipped = true;
    } else if (_skipPolicy.introEnabled) {
      // 续播已过片头窗口：钉死本集不再补跳，避免策略晚到时 position 仍为 0。
      _introSkipped = true;
    }
    if (target > Duration.zero && target < next.value.duration) {
      final resumeSeek = startupTrace?.startStage(
        PlaybackTraceStage.resumeSeek,
      );
      try {
        await next.seekTo(target);
        startupTrace?.finishStage(resumeSeek);
      } catch (error) {
        startupTrace?.finishStage(
          resumeSeek,
          result: 'failed',
          metadata: {'errorType': error.runtimeType.toString()},
        );
      }
    }
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    final setSpeed = startupTrace?.startStage(
      PlaybackTraceStage.controllerSetSpeed,
    );
    await next.setPlaybackSpeed(playbackSpeed);
    startupTrace?.finishStage(setSpeed);
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    final setVolume = startupTrace?.startStage(
      PlaybackTraceStage.controllerSetVolume,
    );
    await next.setVolume(playbackVolume);
    startupTrace?.finishStage(setVolume);
    if (!mounted || generation != setupGeneration) {
      await next.dispose();
      if (session != null) await _closeSession(session);
      return;
    }
    startupTrace?.finishStage(configure);
    final play = startupTrace?.startStage(PlaybackTraceStage.controllerPlay);
    if (_isAppForeground && _playbackDesired) {
      await next.play();
      startupTrace?.finishStage(play);
      if (!mounted || generation != setupGeneration) {
        await next.dispose();
        if (session != null) await _closeSession(session);
        return;
      }
    } else {
      startupTrace?.finishStage(play, result: 'skipped');
    }
    _activeSession = session;
    controller = next;
    _lastBuffering = next.value.isBuffering;
    _notePlaybackDuration(next.value.duration);
    _completionHandled = false;
    next.addListener(_handlePlayerValueChanged);
    setState(() => initializing = false);
    startupTrace?.complete();
    if (fullScreen) unawaited(_syncFullScreenOrientation());
    if (next.value.isPlaying) {
      _startPlaybackTimer();
      _scheduleControlsHide();
    }
    unawaited(_save());
    await _syncWakelock();
    if (session != null) {
      try {
        final prefetcher = session.buildPrefetcher(
          windowSize: () => _prefetchAhead,
        );
        if (prefetcher != null) {
          if (!_isAppForeground || next.value.isBuffering) {
            prefetcher.pause();
          } else {
            unawaited(prefetcher.prefetch(fromPosition: target));
          }
        }
      } catch (_) {}
    }
  }

  Future<PlaybackSessionPreparation> _prepareSession(
    PlaybackSelection target,
    int generation, {
    bool offlineOnly = false,
  }) async {
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
        offlineOnly: offlineOnly,
        onCacheBypass: (reason) {
          _setPlaybackStatus(
            PlaybackStatus(
              mode: PlaybackMode.proxyWithoutCaching,
              reason: reason,
            ),
            generation: generation,
          );
        },
        onStartupTraceEvent: _startupTrace?.recordStartupIoEvent,
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

  @override
  ({VideoPlayerController? controller, PlaybackSession? session})
  _detachPlayback() {
    saveTimer?.cancel();
    saveTimer = null;
    final current = controller;
    final session = _activeSession;
    _stopSpeedBoost(current);
    _lastBuffering = null;
    controller = null;
    _activeSession = null;
    current?.removeListener(_handlePlayerValueChanged);
    _pendingVolume = null;
    return (controller: current, session: session);
  }

  @override
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

  /// 播放器状态总泵：缓冲/倍速调试日志、时长记忆、错误中断、
  /// 竖屏视频全屏方向同步、片尾跳过与自动连播都从这里触发。
  void _handlePlayerValueChanged() {
    final current = controller;
    if (current == null || !mounted) return;
    final value = current.value;
    final wasBuffering = _lastBuffering;
    if (kDebugMode && wasBuffering != value.isBuffering) {
      debugPrint(
        'Player buffering=${value.isBuffering} playing=${value.isPlaying} '
        'desired=$_playbackDesired speed=${value.playbackSpeed} '
        'position=${value.position} buffered=${value.buffered} '
        'boosting=${speedBoosting.value} seeking=$isSeeking',
      );
    }
    _lastBuffering = value.isBuffering;
    if (wasBuffering != value.isBuffering) {
      final prefetcher = _activeSession?.prefetcher;
      if (value.isBuffering) {
        // 播放请求优先：缓冲期间不再启动新的后台分片批次。
        prefetcher?.pause();
      } else if (_playbackDesired && _isAppForeground && !failed) {
        prefetcher?.resume();
        unawaited(prefetcher?.updatePosition(value.position));
      }
      // 缓冲是播放过程的一部分，不应让瞬时 isPlaying=false 释放常亮锁。
      unawaited(_syncWakelock());
    }
    _handleSpeedBoostBuffering(current);
    if (value.isInitialized) _notePlaybackDuration(value.duration);
    if (value.hasError && !failed) {
      saveTimer?.cancel();
      saveTimer = null;
      controlsTimer?.cancel();
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
    if (!failed &&
        !isSeeking &&
        !seekCommitting.value &&
        value.isPlaying &&
        !_outroSkipped &&
        shouldSkipOutro(
          outroSeconds: _skipPolicy.outroSeconds,
          position: value.position,
          duration: value.duration,
        )) {
      _outroSkipped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _skipOutro();
      });
      return;
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
      _activeSession?.prefetcher?.pause();
      setState(() {
        controlsVisible = true;
        volumeSliderVisible = false;
      });
      unawaited(_save());
      unawaited(_syncWakelock());
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
      if (widget.offlineOnly) {
        await _setup(oldPosition);
        return;
      }
      final source = ref
          .read(vodSourceRegistryProvider)
          .maybeWhen(
            data: (r) => r.findById(widget.video.sourceId),
            orElse: () => null,
          );
      if (source == null) throw const VideoDataException('未知来源');
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, widget.video.ref, forceRefresh: true);
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
      await _setupAttempt(oldPosition, refreshAttempted: true);
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
        unawaited(screenAwakeController.release(screenAwakeOwner));
      }
    }
  }
}
