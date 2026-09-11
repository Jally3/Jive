import 'video_feed.dart';

enum TmdbMediaType { movie, tv }

enum TmdbCatalogScope { all, movie, tv, animation, variety }

extension TmdbCatalogScopeLabel on TmdbCatalogScope {
  String get label => switch (this) {
    TmdbCatalogScope.all => '全部',
    TmdbCatalogScope.movie => '电影',
    TmdbCatalogScope.tv => '电视剧',
    TmdbCatalogScope.animation => '动漫',
    TmdbCatalogScope.variety => '综艺',
  };
}

class TmdbCatalogItem {
  const TmdbCatalogItem({
    required this.tmdbId,
    required this.mediaType,
    required this.category,
    required this.localizedTitle,
    required this.originalTitle,
    this.aliases = const [],
    this.releaseDate = '',
    this.sortDate = '',
    this.latestSeasonNumber,
    this.rating = 0,
    this.voteCount = 0,
    this.popularity = 0,
    this.posterPath = '',
    this.rank = 0,
  });

  factory TmdbCatalogItem.fromJson(Map<String, dynamic> json) {
    final mediaType = switch ('${json['mediaType'] ?? ''}') {
      'movie' => TmdbMediaType.movie,
      'tv' => TmdbMediaType.tv,
      _ => throw const FormatException('TMDB mediaType 无效'),
    };
    final id = _asInt(json['tmdbId']);
    final localizedTitle = '${json['localizedTitle'] ?? ''}'.trim();
    final originalTitle = '${json['originalTitle'] ?? ''}'.trim();
    if (id <= 0 || (localizedTitle.isEmpty && originalTitle.isEmpty)) {
      throw const FormatException('TMDB 条目缺少 ID 或标题');
    }
    return TmdbCatalogItem(
      tmdbId: id,
      mediaType: mediaType,
      category: '${json['category'] ?? mediaType.name}',
      localizedTitle: localizedTitle.isEmpty ? originalTitle : localizedTitle,
      originalTitle: originalTitle,
      aliases: [
        for (final value in _asList(json['aliases']))
          if ('$value'.trim().isNotEmpty) '$value'.trim(),
      ],
      releaseDate: '${json['releaseDate'] ?? ''}',
      sortDate: '${json['sortDate'] ?? json['releaseDate'] ?? ''}',
      latestSeasonNumber: _nullablePositiveInt(json['latestSeasonNumber']),
      rating: _asDouble(json['rating']),
      voteCount: _asInt(json['voteCount']),
      popularity: _asDouble(json['popularity']),
      posterPath: '${json['posterPath'] ?? ''}',
      rank: _asInt(json['rank']),
    );
  }

  final int tmdbId;
  final TmdbMediaType mediaType;
  final String category;
  final String localizedTitle;
  final String originalTitle;
  final List<String> aliases;
  final String releaseDate;
  final String sortDate;
  final int? latestSeasonNumber;
  final double rating;
  final int voteCount;
  final double popularity;
  final String posterPath;
  final int rank;

  String get globalId => 'tmdb:${mediaType.name}:$tmdbId';

  String get posterUrl {
    final value = posterPath.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('https://')) return value;
    return 'https://image.tmdb.org/t/p/w500${value.startsWith('/') ? value : '/$value'}';
  }

  List<String> get searchQueries {
    final seen = <String>{};
    return [localizedTitle, originalTitle, ...aliases]
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .toList(growable: false);
  }

  TmdbCatalogItem withRank(int value) => TmdbCatalogItem(
    tmdbId: tmdbId,
    mediaType: mediaType,
    category: category,
    localizedTitle: localizedTitle,
    originalTitle: originalTitle,
    aliases: aliases,
    releaseDate: releaseDate,
    sortDate: sortDate,
    latestSeasonNumber: latestSeasonNumber,
    rating: rating,
    voteCount: voteCount,
    popularity: popularity,
    posterPath: posterPath,
    rank: value,
  );
}

class TmdbCatalogSnapshot {
  const TmdbCatalogSnapshot({
    this.schemaVersion = 1,
    required this.feed,
    required this.revision,
    this.generatedAt,
    this.expiresAt,
    this.stale = false,
    required this.supportedScopes,
    required this.groups,
    required this.items,
  });

  factory TmdbCatalogSnapshot.fromJson(Map<String, dynamic> json) {
    if (_asInt(json['schemaVersion']) != 1) {
      throw const FormatException('TMDB schemaVersion 不受支持');
    }
    final feed = switch ('${json['feed'] ?? ''}') {
      'latest' => VideoFeed.newReleases,
      'popular' => VideoFeed.popular,
      'top_rated' || 'top-rated' => VideoFeed.topRated,
      _ => throw const FormatException('TMDB feed 无效'),
    };
    final rawItems = json['items'];
    final rawGroups = json['groups'];
    if (rawItems is! Map || rawGroups is! Map) {
      throw const FormatException('TMDB 榜单结构无效');
    }
    final items = <String, TmdbCatalogItem>{};
    for (final entry in rawItems.entries) {
      if (entry.value is! Map) continue;
      try {
        final item = TmdbCatalogItem.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (entry.key == item.globalId) items[item.globalId] = item;
      } on FormatException {
        // 单条坏数据不影响整份榜单。
      }
    }
    if (items.isEmpty) throw const FormatException('TMDB 榜单为空');
    final groups = <TmdbCatalogScope, List<String>>{};
    final supportedScopes = <TmdbCatalogScope>{};
    for (final scope in TmdbCatalogScope.values) {
      if (rawGroups[scope.name] is List) supportedScopes.add(scope);
      final ids = _asList(rawGroups[scope.name])
          .map((value) => '$value')
          .where(items.containsKey)
          .toSet()
          .take(200)
          .toList(growable: false);
      groups[scope] = ids;
    }
    return TmdbCatalogSnapshot(
      schemaVersion: 1,
      feed: feed,
      revision: '${json['revision'] ?? ''}',
      generatedAt: DateTime.tryParse('${json['generatedAt'] ?? ''}'),
      expiresAt: DateTime.tryParse('${json['expiresAt'] ?? ''}'),
      stale: json['stale'] == true,
      supportedScopes: supportedScopes,
      groups: groups,
      items: items,
    );
  }

  final int schemaVersion;
  final VideoFeed feed;
  final String revision;
  final DateTime? generatedAt;
  final DateTime? expiresAt;
  final bool stale;
  final Set<TmdbCatalogScope> supportedScopes;
  final Map<TmdbCatalogScope, List<String>> groups;
  final Map<String, TmdbCatalogItem> items;

  List<TmdbCatalogItem> itemsFor(TmdbCatalogScope scope) {
    final ids = groups[scope] ?? const <String>[];
    return [
      for (var index = 0; index < ids.length; index++)
        if (items[ids[index]] case final item?) item.withRank(index + 1),
    ];
  }
}

List<Object?> _asList(Object? value) => value is List ? value : const [];
int _asInt(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;
double _asDouble(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
int? _nullablePositiveInt(Object? value) {
  final parsed = _asInt(value);
  return parsed > 0 ? parsed : null;
}
