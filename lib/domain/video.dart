class VideoCategory {
  const VideoCategory({
    required this.id,
    required this.name,
    this.parentId = 0,
  });

  final int id;
  final String name;
  final int parentId;
}

class Episode {
  const Episode({
    required this.id,
    required this.name,
    required this.url,
    this.identity = '',
  });

  final String id;
  final String name;
  final String url;
  final String identity;

  int? get parsedEpisodeNumber {
    final match = RegExp(r'(\d+)').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  String get normalizedName =>
      name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
}

class VideoRef {
  const VideoRef({required this.sourceId, required this.sourceVideoId});

  factory VideoRef.fromVideo(Video video) =>
      VideoRef(sourceId: video.sourceId, sourceVideoId: video.sourceVideoId);

  final String sourceId;
  final String sourceVideoId;

  String get globalId => '$sourceId:$sourceVideoId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoRef &&
          sourceId == other.sourceId &&
          sourceVideoId == other.sourceVideoId;

  @override
  int get hashCode => Object.hash(sourceId, sourceVideoId);

  @override
  String toString() => 'VideoRef($globalId)';
}

class PlaybackLine {
  const PlaybackLine({
    required this.id,
    required this.name,
    this.episodes = const [],
    this.identity = '',
  });

  final String id;
  final String name;
  final List<Episode> episodes;
  final String identity;
}

class Video {
  const Video({
    required this.id,
    required this.title,
    this.sourceId = defaultSourceId,
    String? sourceVideoId,
    this.posterUrl = '',
    this.typeId = 0,
    this.category = '',
    this.remarks = '',
    this.description = '',
    this.updatedAt = '',
    this.year = '',
    this.area = '',
    this.actors = '',
    this.director = '',
    this.episodes = const [],
    this.playbackLines = const [],
  }) : sourceVideoId = sourceVideoId ?? id;

  static const defaultSourceId = 'storm';

  final String id;
  final String title;
  final String sourceId;
  final String sourceVideoId;
  final String posterUrl;
  final int typeId;
  final String category;
  final String remarks;
  final String description;
  final String updatedAt;
  final String year;
  final String area;
  final String actors;
  final String director;
  final List<Episode> episodes;
  final List<PlaybackLine> playbackLines;

  String get globalId => '$sourceId:$sourceVideoId';

  VideoRef get ref =>
      VideoRef(sourceId: sourceId, sourceVideoId: sourceVideoId);

  Video copyWith({
    String? title,
    String? posterUrl,
    String? description,
    String? updatedAt,
    List<Episode>? episodes,
    List<PlaybackLine>? playbackLines,
    String? year,
    String? area,
    String? actors,
    String? director,
    String? remarks,
    String? category,
  }) => Video(
    id: id,
    title: title ?? this.title,
    sourceId: sourceId,
    sourceVideoId: sourceVideoId,
    posterUrl: posterUrl ?? this.posterUrl,
    typeId: typeId,
    category: category ?? this.category,
    remarks: remarks ?? this.remarks,
    description: description ?? this.description,
    updatedAt: updatedAt ?? this.updatedAt,
    year: year ?? this.year,
    area: area ?? this.area,
    actors: actors ?? this.actors,
    director: director ?? this.director,
    episodes: episodes ?? this.episodes,
    playbackLines: playbackLines ?? this.playbackLines,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'sourceId': sourceId,
    'sourceVideoId': sourceVideoId,
    'posterUrl': posterUrl,
    'typeId': typeId,
    'category': category,
    'remarks': remarks,
    'description': description,
    'updatedAt': updatedAt,
    'year': year,
    'area': area,
    'actors': actors,
    'director': director,
  };

  factory Video.fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? ''}';
    final rawSourceId = '${json['sourceId'] ?? ''}';
    final rawSourceVideoId = '${json['sourceVideoId'] ?? ''}';
    return Video(
      id: id,
      title: '${json['title'] ?? '未命名视频'}',
      sourceId: rawSourceId.isEmpty ? defaultSourceId : rawSourceId,
      sourceVideoId: rawSourceVideoId.isEmpty ? id : rawSourceVideoId,
      posterUrl: '${json['posterUrl'] ?? ''}',
      typeId: _asInt(json['typeId']),
      category: '${json['category'] ?? ''}',
      remarks: '${json['remarks'] ?? ''}',
      description: '${json['description'] ?? ''}',
      updatedAt: '${json['updatedAt'] ?? ''}',
      year: '${json['year'] ?? ''}',
      area: '${json['area'] ?? ''}',
      actors: '${json['actors'] ?? ''}',
      director: '${json['director'] ?? ''}',
    );
  }
}

class VideoPage {
  const VideoPage({
    required this.items,
    required this.page,
    required this.pageCount,
    this.total,
  });

  final List<Video> items;
  final int page;
  final int pageCount;
  final int? total;
  bool get hasMore => page < pageCount;
}

int _asInt(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;
