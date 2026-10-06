import 'dart:async';
import 'dart:collection';

import '../../domain/video.dart';
import '../../domain/vod_source.dart';

typedef VideoDetailCacheKey = ({
  String sourceId,
  String sourceVideoId,
  Uri baseUri,
  String adapterType,
  Uri? pluginConfigUri,
});

VideoDetailCacheKey videoDetailCacheKey(VodSource source, VideoRef ref) => (
  sourceId: source.id,
  sourceVideoId: ref.sourceVideoId,
  baseUri: source.baseUri,
  adapterType: source.adapterType,
  pluginConfigUri: source.pluginConfigUri,
);

/// Holds one detail model per resource, bounded by age, count and estimated size.
/// The byte budget is an estimate of retained Dart data, not a heap/RSS limit.
class VideoDetailCache {
  VideoDetailCache({
    this.ttl = const Duration(minutes: 2),
    this.maxEntries = 32,
    this.maxEstimatedBytes = 8 * 1024 * 1024,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final int maxEstimatedBytes;
  final DateTime Function() _now;
  final Map<VideoDetailCacheKey, _DetailEntry> _entries = {};
  Timer? _expiryTimer;
  bool _disposed = false;
  int _estimatedBytes = 0;

  int get entryCount => _entries.length;
  int get estimatedBytes => _estimatedBytes;

  Video? get(VideoDetailCacheKey key) {
    _removeExpired();
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return entry.video;
  }

  void put(VideoDetailCacheKey key, Video video) {
    if (_disposed) return;
    _removeExpired();
    remove(key);
    final bytes = estimateVideoBytes(video);
    if (ttl <= Duration.zero || maxEntries <= 0 || bytes > maxEstimatedBytes) {
      return;
    }
    while (_entries.isNotEmpty &&
        (_entries.length >= maxEntries ||
            _estimatedBytes + bytes > maxEstimatedBytes)) {
      remove(_entries.keys.first);
    }
    _entries[key] = _DetailEntry(video, _now().add(ttl), bytes);
    _estimatedBytes += bytes;
    _scheduleExpiry();
  }

  void remove(VideoDetailCacheKey key) {
    final entry = _entries.remove(key);
    if (entry != null) _estimatedBytes -= entry.bytes;
    _scheduleExpiry();
  }

  void _removeExpired() {
    final now = _now();
    final expired = _entries.keys
        .where((key) => !_entries[key]!.expiresAt.isAfter(now))
        .toList();
    for (final key in expired) {
      final entry = _entries.remove(key)!;
      _estimatedBytes -= entry.bytes;
    }
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_disposed || _entries.isEmpty) return;
    final earliest = _entries.values
        .map((entry) => entry.expiresAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final remaining = earliest.difference(_now());
    _expiryTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      _removeExpired,
    );
  }

  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _entries.clear();
    _estimatedBytes = 0;
  }

  /// Uses two bytes per character plus approximate object/list overhead.
  /// Shared objects and strings are counted once within a detail model.
  static int estimateVideoBytes(Video video) {
    final seen = HashSet<Object>.identity();
    var bytes = 256;
    void string(String value) {
      if (seen.add(value)) bytes += 48 + value.length * 2;
    }

    void episodes(List<Episode> items) {
      if (!seen.add(items)) return;
      bytes += 32 + items.length * 8;
      for (final episode in items) {
        if (!seen.add(episode)) continue;
        bytes += 64;
        string(episode.id);
        string(episode.name);
        string(episode.url);
        string(episode.identity);
      }
    }

    for (final value in [
      video.id,
      video.sourceId,
      video.sourceVideoId,
      video.title,
      video.posterUrl,
      video.backupPosterUrl,
      video.category,
      video.remarks,
      video.description,
      video.updatedAt,
      video.year,
      video.area,
      video.actors,
      video.director,
    ]) {
      string(value);
    }
    episodes(video.episodes);
    bytes += 32 + video.playbackLines.length * 8;
    for (final line in video.playbackLines) {
      if (!seen.add(line)) continue;
      bytes += 64;
      string(line.id);
      string(line.name);
      string(line.identity);
      episodes(line.episodes);
    }
    return bytes;
  }
}

class _DetailEntry {
  const _DetailEntry(this.video, this.expiresAt, this.bytes);

  final Video video;
  final DateTime expiresAt;
  final int bytes;
}
