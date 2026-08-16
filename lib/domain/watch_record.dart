import 'video.dart';

class WatchRecord {
  const WatchRecord({
    required this.video,
    required this.episodeId,
    required this.episodeName,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.completed = false,
    this.playbackLineIdentity = '',
    this.episodeIdentity = '',
    this.filterVersion = 0,
    this.timelineVersion = 0,
    this.manifestFingerprint,
  });

  static const int schemaVersion = 2;

  final Video video;
  final String episodeId;
  final String episodeName;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  final bool completed;
  final String playbackLineIdentity;
  final String episodeIdentity;
  final int filterVersion;
  final int timelineVersion;
  final String? manifestFingerprint;

  String get timelineType => 'source';

  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'video': video.toJson(),
    'episodeId': episodeId,
    'episodeName': episodeName,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'timelineType': timelineType,
    'filterVersion': filterVersion,
    'timelineVersion': timelineVersion,
    'manifestFingerprint': manifestFingerprint,
    'playbackLineIdentity': playbackLineIdentity,
    'episodeIdentity': episodeIdentity,
    'updatedAt': updatedAt.toIso8601String(),
    'completed': completed,
  };

  factory WatchRecord.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != null && version != schemaVersion) {
      throw const FormatException('不支持的观看记录版本');
    }
    return WatchRecord(
      video: Video.fromJson(Map<String, dynamic>.from(json['video'] as Map)),
      episodeId: '${json['episodeId'] ?? ''}',
      episodeName: '${json['episodeName'] ?? ''}',
      positionMs: _normalizedPosition(json['positionMs'], json['durationMs']),
      durationMs: _int(json['durationMs']).clamp(0, 1 << 53),
      updatedAt:
          DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime(1970),
      completed: json['completed'] == true,
      playbackLineIdentity: '${json['playbackLineIdentity'] ?? ''}',
      episodeIdentity: '${json['episodeIdentity'] ?? ''}',
      filterVersion: _int(json['filterVersion']),
      timelineVersion: _int(json['timelineVersion']),
      manifestFingerprint: json['manifestFingerprint'] as String?,
    );
  }
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

int _normalizedPosition(Object? position, Object? duration) {
  final safeDuration = _int(duration).clamp(0, 1 << 53);
  return _int(position).clamp(0, safeDuration);
}
