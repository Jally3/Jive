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
  });

  final Video video;
  final String episodeId;
  final String episodeName;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  final bool completed;

  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    'episodeId': episodeId,
    'episodeName': episodeName,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toIso8601String(),
    'completed': completed,
  };

  factory WatchRecord.fromJson(Map<String, dynamic> json) => WatchRecord(
    video: Video.fromJson(Map<String, dynamic>.from(json['video'] as Map)),
    episodeId: '${json['episodeId'] ?? ''}',
    episodeName: '${json['episodeName'] ?? ''}',
    positionMs: _normalizedPosition(json['positionMs'], json['durationMs']),
    durationMs: _int(json['durationMs']).clamp(0, 1 << 53),
    updatedAt:
        DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime(1970),
    completed: json['completed'] == true,
  );
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

int _normalizedPosition(Object? position, Object? duration) {
  final safeDuration = _int(duration).clamp(0, 1 << 53);
  return _int(position).clamp(0, safeDuration);
}
