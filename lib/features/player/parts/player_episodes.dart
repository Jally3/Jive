part of '../player_page.dart';

/// 剧集/线路切换：选集入口统一走 [_switchEpisode]（换源重解析），
/// 播放地址失败时按线路顺序降级重试。
mixin PlayerEpisodeNavigation on PlayerStateBase {
  @override
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
    await _setup(
      widget.episodeResumePositions[episode.identity] ?? Duration.zero,
    );
  }

  @override
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

  @override
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

  @override
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
    final bundled = widget.episodeSelections[next.identity];
    if (bundled != null) return bundled;
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

  void _updateDownloadedEpisodeKeys(List<DownloadTask> tasks) {
    _downloadedEpisodeKeys = {
      for (final task in tasks)
        if (task.status == DownloadTaskStatus.completed)
          offlineProgressKeyForTask(task),
    };
  }
}
