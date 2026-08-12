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
  const Episode({required this.id, required this.name, required this.url});

  final String id;
  final String name;
  final String url;
}

class Video {
  const Video({
    required this.id,
    required this.title,
    this.posterUrl = '',
    this.typeId = 0,
    this.category = '',
    this.remarks = '',
    this.description = '',
    this.updatedAt = '',
    this.episodes = const [],
  });

  final String id;
  final String title;
  final String posterUrl;
  final int typeId;
  final String category;
  final String remarks;
  final String description;
  final String updatedAt;
  final List<Episode> episodes;

  Video copyWith({
    String? posterUrl,
    String? description,
    String? updatedAt,
    List<Episode>? episodes,
  }) => Video(
    id: id,
    title: title,
    posterUrl: posterUrl ?? this.posterUrl,
    typeId: typeId,
    category: category,
    remarks: remarks,
    description: description ?? this.description,
    updatedAt: updatedAt ?? this.updatedAt,
    episodes: episodes ?? this.episodes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'posterUrl': posterUrl,
    'typeId': typeId,
    'category': category,
    'remarks': remarks,
    'description': description,
    'updatedAt': updatedAt,
  };

  factory Video.fromJson(Map<String, dynamic> json) => Video(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? '未命名视频'}',
    posterUrl: '${json['posterUrl'] ?? ''}',
    typeId: _asInt(json['typeId']),
    category: '${json['category'] ?? ''}',
    remarks: '${json['remarks'] ?? ''}',
    description: '${json['description'] ?? ''}',
    updatedAt: '${json['updatedAt'] ?? ''}',
  );
}

class VideoPage {
  const VideoPage({
    required this.items,
    required this.page,
    required this.pageCount,
  });

  final List<Video> items;
  final int page;
  final int pageCount;
  bool get hasMore => page < pageCount;
}

int _asInt(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;
