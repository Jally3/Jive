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
      if (s.contains('m3u8') || s.contains('hls')) return PlaybackFormat.hls;
      if (s.contains('mp4')) return PlaybackFormat.mp4;
      if (s.contains('mpd') || s.contains('dash')) return PlaybackFormat.dash;
    }
    final query = uri.query.toLowerCase();
    if (query.contains('m3u8')) return PlaybackFormat.hls;
    if (query.contains('mp4')) return PlaybackFormat.mp4;
    if (query.contains('mpd')) return PlaybackFormat.dash;
  }
  return PlaybackFormat.unknown;
}
