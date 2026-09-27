part of '../player_page.dart';

/// 进度记忆与前台/后台生命周期：定时保存观看进度（含离线进度）、
/// 前后台切换时暂停/恢复播放、wakelock 同步与心跳。
mixin PlayerProgressPersistence on PlayerStateBase {
  /// 播放期定时任务：每 15 秒保存观看进度，并按当前播放位置重锚定预取窗口，
  /// 让预取始终维持在播放点前方一个窗口（seek 后也会在下一拍跟上）。
  @override
  void _startPlaybackTimer() {
    saveTimer?.cancel();
    if (!_isAppForeground || controller?.value.isPlaying != true) return;
    saveTimer = Timer.periodic(
      const Duration(seconds: 15),
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

  @override
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
    final key = offlineProgressKey(
      sourceId: record.video.sourceId,
      sourceVideoId: record.video.sourceVideoId,
      playbackLineIdentity: record.playbackLineIdentity,
      episodeIdentity: record.episodeIdentity,
    );
    if (widget.offlineOnly || _downloadedEpisodeKeys.contains(key)) {
      await offlineProgressRepository.saveWatchRecord(record);
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
  @override
  Future<void> _syncWakelock() async {
    final shouldKeepAwake =
        mounted &&
        _isAppForeground &&
        !failed &&
        _playbackDesired &&
        controller?.value.isInitialized == true &&
        controller?.value.isCompleted != true;
    try {
      await WakelockPlus.toggle(enable: shouldKeepAwake);
    } catch (_) {
      // A wakelock failure must not interrupt video playback.
    }
  }

  @override
  void _startWakelockHeartbeat() {
    wakelockTimer?.cancel();
    wakelockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted ||
          failed ||
          !_playbackDesired ||
          controller?.value.isInitialized != true ||
          controller?.value.isCompleted == true) {
        wakelockTimer?.cancel();
        wakelockTimer = null;
        unawaited(_syncWakelock());
        return;
      }
      unawaited(_syncWakelock());
    });
  }
}
