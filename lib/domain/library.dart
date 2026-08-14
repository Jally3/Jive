import 'video.dart';

class FavoriteRecord {
  const FavoriteRecord({
    required this.video,
    required this.createdAt,
    required this.updatedAt,
  });
  final Video video;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static FavoriteRecord? tryFromJson(Object? value) {
    if (value is! Map || value['video'] is! Map) return null;
    try {
      final video = Video.fromJson(
        Map<String, dynamic>.from(value['video'] as Map),
      );
      final createdAt = DateTime.tryParse('${value['createdAt'] ?? ''}');
      final updatedAt = DateTime.tryParse('${value['updatedAt'] ?? ''}');
      if (video.id.isEmpty ||
          video.title.isEmpty ||
          createdAt == null ||
          updatedAt == null) {
        return null;
      }
      return FavoriteRecord(
        video: video,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }
}
