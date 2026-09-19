part of '../player_page.dart';

/// 拖动快进状态机：开始（暂停+冻结进度尺）→ 更新预览 →
/// 提交（native position 校验重试）/取消。片头片尾跳过与遥控器快进
/// 也复用 [_seekToAbsolute]/[_seekStart] 管线。
mixin PlayerSeekCoordinator on PlayerStateBase {
  /// 以过滤时间轴的绝对位置跳转（片头/片尾跳过共用入口）。
  @override
  void _seekToAbsolute(Duration target) {
    final current = controller;
    if (current == null ||
        !current.value.isInitialized ||
        failed ||
        isSeeking ||
        seekCommitting.value ||
        current.value.duration <= Duration.zero) {
      return;
    }
    _notePlaybackDuration(current.value.duration);
    final clock = freezeSeekClock(
      playerDuration: current.value.duration,
      observedDuration: _observedDuration,
    );
    final clamped = _clampSeekTarget(target, clock);
    _showControls();
    _seekStart(clamped);
    unawaited(_seekEnd(clamped));
  }

  @override
  void _seekStart(Duration target) {
    controlsTimer?.cancel();
    final current = controller;
    if (current == null || isSeeking || seekCommitting.value) return;
    // 先记下起点和尺子，再 pause：广告乱 PTS 时 pause 可能把 position 打成 0。
    _notePlaybackDuration(current.value.duration);
    final clock = freezeSeekClock(
      playerDuration: current.value.duration,
      observedDuration: _observedDuration,
    );
    seekGeneration++;
    isSeeking = true;
    positionBeforeSeek = current.value.position;
    wasPlayingBeforeSeek = current.value.isPlaying;
    seekClock.value = clock;
    previewPosition.value = _clampSeekTarget(target, clock);
    seekPause = wasPlayingBeforeSeek ? current.pause() : Future.value();
  }

  @override
  void _seekUpdate(Duration target) {
    if (!isSeeking) return;
    final clock =
        seekClock.value ?? controller?.value.duration ?? Duration.zero;
    previewPosition.value = _clampSeekTarget(target, clock);
  }

  @override
  Future<void> _seekEnd(Duration target) async {
    if (!isSeeking) return;
    final seekController = controller;
    if (seekController == null) {
      _resetSeekState();
      return;
    }
    final generation = seekGeneration;
    final clock = seekClock.value ?? seekController.value.duration;
    final finalTarget = _clampSeekTarget(
      previewPosition.value ?? target,
      clock,
    );
    isSeeking = false;
    previewPosition.value = finalTarget;
    seekCommitting.value = true;
    try {
      await seekPause;
      if (!_isCurrentSeek(seekController, generation)) return;
      var landed = positionBeforeSeek;
      if ((finalTarget - positionBeforeSeek).abs() >
          const Duration(milliseconds: 250)) {
        landed = await _seekAndRead(seekController, finalTarget);
        if (!_isCurrentSeek(seekController, generation)) return;
        if (!seekLandedNear(landed, finalTarget)) {
          landed = await _seekAndRead(seekController, finalTarget);
          if (!_isCurrentSeek(seekController, generation)) return;
        }
      }
      if (finalTarget < clock) {
        _completionHandled = false;
      }
      if (wasPlayingBeforeSeek && _isAppForeground && _playbackDesired) {
        await seekController.play();
      }
      if (!_isCurrentSeek(seekController, generation)) return;
      if (seekLandedNear(landed, finalTarget)) {
        previewPosition.value = null;
        seekClock.value = null;
      } else {
        previewPosition.value = finalTarget;
      }
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
      seekClock.value = null;
      _scheduleControlsHide();
    }
  }

  @override
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
        seekClock.value = null;
        _scheduleControlsHide();
      }
    }
  }

  bool _isCurrentSeek(VideoPlayerController? target, int generation) =>
      mounted && identical(controller, target) && seekGeneration == generation;

  @override
  Duration _clampSeekTarget(Duration target, Duration duration) {
    if (duration <= Duration.zero || target <= Duration.zero) {
      return Duration.zero;
    }
    return target > duration ? duration : target;
  }

  Duration? get _sessionPlayableDuration {
    final session = _activeSession;
    if (session == null || session.originalDurationMs <= 0) return null;
    return sessionPlayableDuration(
      originalDurationMs: session.originalDurationMs,
      removedMs: session.timelineMapping?.removedMs ?? 0,
    );
  }

  @override
  void _notePlaybackDuration(Duration playerDuration) {
    _observedDuration = rememberPlaybackDuration(
      playerDuration: playerDuration,
      observedDuration: _observedDuration,
      sessionPlayableDuration: _sessionPlayableDuration,
    );
  }

  Future<Duration> _nativePosition(VideoPlayerController current) async {
    try {
      return await current.position ?? current.value.position;
    } catch (_) {
      return current.value.position;
    }
  }

  Future<Duration> _seekAndRead(
    VideoPlayerController current,
    Duration target,
  ) async {
    await current.seekTo(target);
    return _nativePosition(current);
  }

  @override
  void _resetSeekState() {
    seekGeneration++;
    isSeeking = false;
    wasPlayingBeforeSeek = false;
    positionBeforeSeek = Duration.zero;
    previewPosition.value = null;
    seekClock.value = null;
    seekCommitting.value = false;
    screenSeeking.value = false;
    speedBoosting.value = false;
    verticalDrag.value = null;
    verticalDragGeneration++;
    seekPause = Future.value();
  }
}
