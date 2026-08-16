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
}

PlaybackSelection? selectionFor(Video video, Episode episode) {
  if (video.playbackLines.isEmpty) return null;
  final line = video.playbackLines.first;
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
      format: _formatFor(matched.url),
    ),
  );
}

PlaybackFormat _formatFor(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8')) return PlaybackFormat.hls;
  if (lower.contains('.mp4') || lower.contains('mp4')) {
    return PlaybackFormat.mp4;
  }
  if (lower.contains('.mpd')) return PlaybackFormat.dash;
  return PlaybackFormat.unknown;
}
