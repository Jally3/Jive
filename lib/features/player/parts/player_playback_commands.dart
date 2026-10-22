part of '../player_page.dart';

/// 播放命令与片头/片尾跳过：播放/暂停、静音/音量（排队写）、倍速切换、
/// 当前集下载，以及跳过策略的加载与执行。
mixin PlayerPlaybackCommands on PlayerStateBase {
  @override
  Future<void> _loadSkipPolicy() async {
    try {
      final policy = await ref.read(
        skipPolicyProvider(widget.video.globalId).future,
      );
      if (mounted) _skipPolicy = policy;
    } catch (_) {}
  }

  void _maybeSkipIntro() {
    final current = controller;
    if (current == null ||
        !current.value.isInitialized ||
        _introSkipped ||
        failed ||
        isSeeking ||
        seekCommitting.value) {
      return;
    }
    final position = skipIntroDecisionPosition(
      resumePosition: _introDecisionPosition,
      playerPosition: current.value.position,
    );
    if (!shouldSkipIntro(
      introSeconds: _skipPolicy.introSeconds,
      position: position,
      duration: current.value.duration,
    )) {
      if (_skipPolicy.introEnabled) _introSkipped = true;
      return;
    }
    _introSkipped = true;
    _seekToAbsolute(Duration(seconds: _skipPolicy.introSeconds));
  }

  @override
  void _skipOutro() {
    final nextEpisode = _adjacentEpisode(1);
    if (nextEpisode != null) {
      unawaited(_switchEpisode(nextEpisode));
      return;
    }
    final current = controller;
    if (current == null || !current.value.isInitialized) return;
    _notePlaybackDuration(current.value.duration);
    final clock = freezeSeekClock(
      playerDuration: current.value.duration,
      observedDuration: _observedDuration,
    );
    _seekToAbsolute(clock);
  }

  @override
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
      saveTimer?.cancel();
      saveTimer = null;
      controlsTimer?.cancel();
      _activeSession?.prefetcher?.pause();
      unawaited(_save());
      if (mounted) {
        setState(() => controlsVisible = true);
        _scheduleControlsHide();
      }
    } catch (_) {
      _playbackDesired = true;
      if (mounted) {
        showAppToast(context, '暂停失败，请稍后重试');
      }
    } finally {
      playbackToggleInFlight = false;
    }
  }

  @override
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

  @override
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
}
