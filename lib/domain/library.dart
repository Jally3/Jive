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

class VideoPlaylist {
  const VideoPlaylist({
    required this.id,
    required this.name,
    required this.videos,
    required this.createdAt,
    required this.updatedAt,
  });
  final String id;
  final String name;
  final List<Video> videos;
  final DateTime createdAt;
  final DateTime updatedAt;

  VideoPlaylist copyWith({List<Video>? videos, DateTime? updatedAt}) =>
      VideoPlaylist(
        id: id,
        name: name,
        videos: videos ?? this.videos,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'videos': videos.map((v) => v.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static VideoPlaylist? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      final id = value['id'];
      final name = value['name'];
      final createdAt = DateTime.tryParse('${value['createdAt'] ?? ''}');
      final updatedAt = DateTime.tryParse('${value['updatedAt'] ?? ''}');
      if (id is! String ||
          id.isEmpty ||
          name is! String ||
          name.trim().isEmpty ||
          createdAt == null ||
          updatedAt == null) {
        return null;
      }
      final seen = <String>{};
      final videos = <Video>[];
      for (final item
          in value['videos'] is List ? value['videos'] as List : const []) {
        if (item is! Map) continue;
        final video = Video.fromJson(Map<String, dynamic>.from(item));
        if (video.id.isNotEmpty &&
            video.title.isNotEmpty &&
            seen.add(video.id)) {
          videos.add(video);
        }
      }
      return VideoPlaylist(
        id: id,
        name: name.trim(),
        videos: videos,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }
}
