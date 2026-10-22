part of '../player_page.dart';

/// 屏幕手势状态机：横向拖动快进、纵向拖动亮度/音量（排队写系统亮度）、
/// 长按 2 倍速（含缓冲自动回退与一次重试）。
mixin PlayerScreenGestures on PlayerStateBase {
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
      unawaited(HapticFeedback.lightImpact());
      speedBoosting.value = true;
      speedBoostFallback.value = current.value.isBuffering;
      _speedBoostRetried = false;
      if (!speedBoostFallback.value) _queueSpeedBoostChange(current, 2);
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
        duration: seekClock.value ?? current.value.duration,
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

  @override
  void _stopSpeedBoost(VideoPlayerController? current) {
    if (!speedBoosting.value) return;
    _speedBoostRetryTimer?.cancel();
    _speedBoostRetryTimer = null;
    speedBoosting.value = false;
    speedBoostFallback.value = false;
    _speedBoostRetried = false;
    if (current != null) {
      _queueSpeedBoostChange(current, playbackSpeed);
    }
  }

  void _queueSpeedBoostChange(VideoPlayerController current, double speed) {
    longPressSpeedChange = longPressSpeedChange.catchError((_) {}).then((
      _,
    ) async {
      if (!mounted || !identical(controller, current)) return;
      try {
        await current.setPlaybackSpeed(speed);
      } catch (_) {}
    });
  }

  @override
  void _handleSpeedBoostBuffering(VideoPlayerController current) {
    if (!speedBoosting.value || !identical(controller, current)) return;
    if (current.value.isBuffering) {
      _speedBoostRetryTimer?.cancel();
      _speedBoostRetryTimer = null;
      if (!speedBoostFallback.value) {
        speedBoostFallback.value = true;
        _queueSpeedBoostChange(current, playbackSpeed);
      }
      return;
    }
    if (!speedBoostFallback.value ||
        _speedBoostRetried ||
        _speedBoostRetryTimer != null) {
      return;
    }
    _speedBoostRetryTimer = Timer(const Duration(seconds: 2), () {
      _speedBoostRetryTimer = null;
      if (!mounted ||
          !identical(controller, current) ||
          !speedBoosting.value ||
          !_isAppForeground ||
          !_playbackDesired ||
          !current.value.isPlaying ||
          current.value.isBuffering) {
        return;
      }
      final position = current.value.position;
      final ranges = current.value.buffered;
      final ahead = ranges
          .where((range) => range.start <= position && range.end > position)
          .map((range) => range.end - position)
          .fold<Duration>(
            Duration.zero,
            (best, value) => value > best ? value : best,
          );
      if (ranges.isNotEmpty && ahead < const Duration(seconds: 8)) return;
      _speedBoostRetried = true;
      speedBoostFallback.value = false;
      _queueSpeedBoostChange(current, 2);
    });
  }
}
