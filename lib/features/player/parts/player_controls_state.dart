part of '../player_page.dart';

/// 控制栏显隐、屏幕锁、TV 遥控器按键与全屏/系统 UI。
mixin PlayerControlsState on PlayerStateBase {
  @override
  void _showControls() {
    if (_screenLocked) return;
    controlsTimer?.cancel();
    if (mounted) setState(() => controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    if (_screenLocked || _popupMenuOpen) return;
    controlsTimer?.cancel();
    setState(() {
      controlsVisible = !controlsVisible;
      if (!controlsVisible) volumeSliderVisible = false;
    });
    if (controlsVisible) _scheduleControlsHide();
  }

  @override
  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    final value = controller?.value;
    if (_screenLocked ||
        value == null ||
        !value.isInitialized ||
        failed ||
        isSeeking ||
        _popupMenuOpen ||
        (_isTv && !value.isPlaying)) {
      return;
    }
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_popupMenuOpen && !_screenLocked) {
        _hideControls();
      }
    });
  }

  bool get _popupMenuOpen => _episodeMenuOpen || _speedMenuOpen;

  void _toggleScreenLock() {
    final next = !_screenLocked;
    controlsTimer?.cancel();
    _lockButtonTimer?.cancel();
    _stopSpeedBoost(controller);
    setState(() {
      _screenLocked = next;
      _lockButtonVisible = true;
      controlsVisible = !next;
      volumeSliderVisible = false;
    });
    unawaited(HapticFeedback.lightImpact());
    if (next) {
      _scheduleLockButtonHide();
    } else {
      _scheduleControlsHide();
    }
  }

  void _toggleLockedControls() {
    if (!_screenLocked) return;
    _lockButtonTimer?.cancel();
    setState(() => _lockButtonVisible = !_lockButtonVisible);
    if (_lockButtonVisible) _scheduleLockButtonHide();
  }

  void _scheduleLockButtonHide() {
    _lockButtonTimer?.cancel();
    if (!_screenLocked || !_lockButtonVisible) return;
    _lockButtonTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _screenLocked) {
        setState(() => _lockButtonVisible = false);
      }
    });
  }

  void _unlockScreenForLayoutChange() {
    if (!_screenLocked) return;
    _lockButtonTimer?.cancel();
    _stopSpeedBoost(controller);
    setState(() {
      _screenLocked = false;
      _lockButtonVisible = true;
      controlsVisible = true;
    });
    _scheduleControlsHide();
  }

  /// 收起控制条（遥控器下/返回键，也是自动隐藏计时器的收尾）。
  /// TV 上顺带把焦点收回到页面根节点，保证后续遥控器按键仍被接管。
  void _hideControls() {
    controlsTimer?.cancel();
    if (!controlsVisible) return;
    setState(() {
      controlsVisible = false;
      volumeSliderVisible = false;
    });
    if (_isTv) _remoteKeyFocusNode.requestFocus();
  }

  /// TV 遥控器/D-pad 按键映射（仅 TV 生效，手机端不拦截任何按键）：
  /// - OK/确定：控制条隐藏时先唤出，否则播放/暂停；
  /// - 左/右：以当前位置快退/快进 10 秒；
  /// - 上/下：唤出/收起控制条；
  /// - 返回：控制条显示时先收起，否则走与 PopScope 一致的退出逻辑；
  /// - 菜单键：打开选集菜单（单集没有选集入口时打开倍速菜单）。
  KeyEventResult _handleRemoteKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isTv || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // 返回/菜单/上下不依赖焦点位置：焦点在控制条按钮上时同样生效。
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (controlsVisible) {
        _hideControls();
        return KeyEventResult.handled;
      }
      if (fullScreen) {
        unawaited(_toggleFullScreen());
      } else {
        unawaited(_saveAndPop());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu) {
      _openEpisodeMenuFromRemote();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!failed && !initializing) _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _hideControls();
      return KeyEventResult.handled;
    }
    // OK 与左右仅在焦点停留在播放层时接管；焦点移到控制条按钮等控件上时
    // 交还默认的焦点导航与控件激活，不抢焦点。
    if (FocusManager.instance.primaryFocus != _remoteKeyFocusNode) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (!controlsVisible) {
        if (!failed && !initializing) _showControls();
      } else {
        unawaited(_togglePlayback());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekByRemote(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekByRemote(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 遥控器左右键：以当前播放位置为基准快退/快进 [delta]，
  /// 复用 scrubber 的 seek 管线（暂停-跳转-恢复-保存-预取重锚定），
  /// 并唤出控制条让进度变化可见（自动隐藏计时照旧）。
  void _seekByRemote(Duration delta) {
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
    final target = _clampSeekTarget(current.value.position + delta, clock);
    _showControls();
    _seekStart(target);
    unawaited(_seekEnd(target));
  }

  /// 遥控器菜单键：唤出控制条并直接打开选集菜单；
  /// 单集没有选集入口时退化为倍速菜单。
  void _openEpisodeMenuFromRemote() {
    if (failed || initializing) return;
    _showControls();
    final episodeMenu = _episodeMenuKey.currentState;
    if (episodeMenu != null) {
      episodeMenu.showButtonMenu();
    } else {
      _speedMenuKey.currentState?.showButtonMenu();
    }
  }

  Future<void> _showPlaybackStatusDetails() async {
    if (!mounted || playbackStatus.mode == PlaybackMode.preparing) return;
    final status = playbackStatus;
    final report = _activeSession?.adFilterReport;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202124),
      builder: (context) => PlaybackStatusDetails(
        status: status,
        adFilterStatus: report?.statusText,
        adFilterDebug: kDebugMode ? report?.debugLines ?? const [] : const [],
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
    if (!target) {
      _lockButtonTimer?.cancel();
      _stopSpeedBoost(controller);
    }
    setState(() {
      fullScreen = target;
      if (!target) {
        _screenLocked = false;
        _lockButtonVisible = true;
        controlsVisible = true;
      }
    });
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

  @override
  bool get _isPortraitVideo {
    final ratio = controller?.value.aspectRatio ?? 0;
    return ratio > 0 && ratio < 1;
  }

  bool _overlayLayoutOf(BuildContext context) =>
      fullScreen || MediaQuery.orientationOf(context) == Orientation.landscape;

  @override
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
    // 电视面板固定横屏：竖屏视频也不请求竖屏方向。
    final isTv = ref
        .read(isTvProvider)
        .maybeWhen(data: (v) => v, orElse: () => false);
    if (mounted) {
      _lockPortraitOnExit =
          !isTv && MediaQuery.sizeOf(context).shortestSide < 600;
    }
    final portraitVideo = _isPortraitVideo && !isTv;
    await SystemChrome.setPreferredOrientations(
      enabled
          ? (portraitVideo
                ? const [DeviceOrientation.portraitUp]
                : const [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ])
          : _idlePreferredOrientations(),
    );
    _fullScreenLockedPortrait = enabled && portraitVideo;
    await SystemChrome.setEnabledSystemUIMode(
      enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  List<DeviceOrientation> _idlePreferredOrientations() => _lockPortraitOnExit
      ? const [DeviceOrientation.portraitUp]
      : DeviceOrientation.values;
}
