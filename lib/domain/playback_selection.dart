import 'playback_source.dart';
import 'video.dart';

class PlaybackSelection {
  const PlaybackSelection({
    required this.sourceId,
    required this.sourceVideoId,
    required this.title,
    required this.playbackLineIdentity,
    required this.episodeIdentity,
    required this.episode,
    required this.playbackSource,
  });

  final String sourceId;
  final String sourceVideoId;
  final String title;
  final String playbackLineIdentity;
  final String episodeIdentity;
  final Episode episode;
  final PlaybackSource playbackSource;

  bool get hasStableIdentity =>
      playbackLineIdentity.isNotEmpty && episodeIdentity.isNotEmpty;

  PlaybackSelection copyWith({
    PlaybackSource? playbackSource,
    Episode? episode,
  }) => PlaybackSelection(
    sourceId: sourceId,
    sourceVideoId: sourceVideoId,
    title: title,
    playbackLineIdentity: playbackLineIdentity,
    episodeIdentity: episodeIdentity,
    episode: episode ?? this.episode,
    playbackSource: playbackSource ?? this.playbackSource,
  );
}

/// Finds [target] in [episodes] by identity, then name, then id.
int? indexOfEpisode(List<Episode> episodes, Episode target) {
  if (target.identity.isNotEmpty) {
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].identity == target.identity) return i;
    }
  }
  if (target.name.isNotEmpty) {
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].name == target.name) return i;
    }
  }
  if (target.id.isNotEmpty) {
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].id == target.id) return i;
    }
  }
  return null;
}

PlaybackSelection? selectionFor(Video video, Episode episode) {
  if (video.playbackLines.isEmpty) return null;
  final line = preferredPlaybackLine(video)!;
  Episode matched = episode;
  if (episode.identity.isNotEmpty) {
    final byIdentity = line.episodes
        .where((e) => e.identity == episode.identity)
        .toList();
    if (byIdentity.isNotEmpty) {
      matched = byIdentity.first;
    } else {
      final byName = line.episodes
          .where(
            (e) =>
                e.name == episode.name ||
                (episode.name.isNotEmpty && e.id == episode.id),
          )
          .toList();
      if (byName.isNotEmpty) matched = byName.first;
    }
  } else if (episode.name.isNotEmpty || episode.id.isNotEmpty) {
    final byName = line.episodes
        .where((e) => e.name == episode.name || e.id == episode.id)
        .toList();
    if (byName.isNotEmpty) matched = byName.first;
  }
  if (line.identity.isEmpty || matched.identity.isEmpty) return null;
  return PlaybackSelection(
    sourceId: video.sourceId,
    sourceVideoId: video.sourceVideoId,
    title: video.title,
    playbackLineIdentity: line.identity,
    episodeIdentity: matched.identity,
    episode: matched,
    playbackSource: PlaybackSource(
      url: Uri.tryParse(matched.url) ?? Uri(),
      format: inferPlaybackFormat(matched.url),
    ),
  );
}

/// Rebuilds a playback selection from freshly resolved video data.
///
/// When [previousSelection] is present, matching is strictly limited to its
/// playback line. A missing line or episode returns `null` instead of silently
/// crossing to another line. When there is no previous selection, the fresh
/// video's preferred line is used for the legacy episode-only flow.
PlaybackSelection? refreshSelectionFor({
  required Video freshVideo,
  required Episode priorEpisode,
  PlaybackSelection? previousSelection,
}) {
  final PlaybackLine? line;
  if (previousSelection != null) {
    line = _lineByIdentity(
      freshVideo.playbackLines,
      previousSelection.playbackLineIdentity,
    );
    if (line == null) return null;
  } else {
    line = preferredPlaybackLine(freshVideo);
  }
  if (line == null || line.identity.isEmpty) return null;

  final episodeIdentity =
      previousSelection?.episodeIdentity ?? priorEpisode.identity;
  final episodeForFallback = previousSelection?.episode ?? priorEpisode;
  final episode = _episodeInLine(
    line,
    identity: episodeIdentity,
    fallback: episodeForFallback,
  );
  if (episode == null || episode.identity.isEmpty) return null;

  return PlaybackSelection(
    sourceId: freshVideo.sourceId,
    sourceVideoId: freshVideo.sourceVideoId,
    title: freshVideo.title,
    playbackLineIdentity: line.identity,
    episodeIdentity: episode.identity,
    episode: episode,
    playbackSource: PlaybackSource(
      url: Uri.tryParse(episode.url) ?? Uri(),
      format: inferPlaybackFormat(episode.url),
      headers: previousSelection?.playbackSource.headers ?? const {},
    ),
  );
}

PlaybackLine? _lineByIdentity(List<PlaybackLine> lines, String identity) {
  if (identity.isEmpty) return null;
  for (final line in lines) {
    if (line.identity == identity) return line;
  }
  return null;
}

Episode? _episodeInLine(
  PlaybackLine line, {
  required String identity,
  required Episode fallback,
}) {
  if (identity.isNotEmpty) {
    for (final episode in line.episodes) {
      if (episode.identity == identity) return episode;
    }
  }
  for (final episode in line.episodes) {
    final sameName = fallback.name.isNotEmpty && episode.name == fallback.name;
    final sameId = fallback.id.isNotEmpty && episode.id == fallback.id;
    if (sameName || sameId) return episode;
  }
  return null;
}

PlaybackLine? preferredPlaybackLine(Video video) {
  PlaybackLine? best;
  var bestScore = -1;
  for (final line in video.playbackLines) {
    final score = _lineScore(line);
    if (score > bestScore) {
      best = line;
      bestScore = score;
    }
  }
  return best;
}

int _lineScore(PlaybackLine line) {
  final name = line.name.toLowerCase();
  var score = name.contains('m3u8') || name.contains('hls') ? 30 : 0;
  for (final episode in line.episodes.take(3)) {
    final url = episode.url.toLowerCase();
    if (url.contains('.m3u8')) {
      score = score < 50 ? 50 : score;
    } else if (url.contains('.mp4')) {
      score = score < 40 ? 40 : score;
    } else if (url.contains('/play/')) {
      score = score < 10 ? 10 : score;
    }
  }
  return score;
}

PlaybackFormat inferPlaybackFormat(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8')) return PlaybackFormat.hls;
  if (lower.contains('.mp4') || lower.contains('mp4')) {
    return PlaybackFormat.mp4;
  }
  if (lower.contains('.mpd')) return PlaybackFormat.dash;

  final uri = Uri.tryParse(url);
  if (uri != null) {
    for (final seg in uri.pathSegments) {
      final s = seg.toLowerCase();
      // Bare path segments like `m3u8` or `hls` are resolver directories,
      // not media files. Only dotted extensions count here.
      if (s.contains('.m3u8')) return PlaybackFormat.hls;
      if (s.contains('.mp4')) return PlaybackFormat.mp4;
      if (s.contains('.mpd') || s.contains('.dash')) return PlaybackFormat.dash;
    }
    final query = uri.query.toLowerCase();
    if (query.contains('m3u8')) return PlaybackFormat.hls;
    if (query.contains('mp4')) return PlaybackFormat.mp4;
    if (query.contains('mpd')) return PlaybackFormat.dash;
  }
  return PlaybackFormat.unknown;
}
