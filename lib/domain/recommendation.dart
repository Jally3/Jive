import 'tmdb_catalog.dart';
import 'video_search_target.dart';

enum RecommendationMode { personalized, coldStart }

enum RecommendationSource { llm, none }

class RecommendationUsage {
  const RecommendationUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
  });

  factory RecommendationUsage.fromJson(Object? value) {
    if (value is! Map) return const RecommendationUsage();
    return RecommendationUsage(
      promptTokens: _int(value['prompt_tokens']),
      completionTokens: _int(value['completion_tokens']),
      totalTokens: _int(value['total_tokens']),
    );
  }

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  Map<String, dynamic> toJson() => {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
  };
}

class RecommendationCandidate {
  const RecommendationCandidate({
    required this.title,
    required this.mediaType,
    this.originalTitle = '',
    this.aliases = const [],
    this.year = '',
    this.category = '',
    this.latestSeasonNumber,
    double? modelConfidence,
    @Deprecated('Use modelConfidence') double? confidence,
    this.reason = '',
  }) : modelConfidence = modelConfidence ?? confidence ?? 0.5;

  static RecommendationCandidate? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final title = '${json['title'] ?? ''}'.trim();
    final mediaType = switch ('${json['mediaType'] ?? ''}'.toLowerCase()) {
      'movie' => TmdbMediaType.movie,
      'tv' => TmdbMediaType.tv,
      _ => null,
    };
    if (title.isEmpty || title.length > 100 || mediaType == null) return null;
    final rawYear = '${json['year'] ?? ''}'.trim();
    final year = RegExp(r'^(19|20)\d{2}$').hasMatch(rawYear) ? rawYear : '';
    final category = '${json['category'] ?? ''}'.trim().toLowerCase();
    if (!const {'movie', 'tv', 'animation', 'variety'}.contains(category)) {
      return null;
    }
    final rawSeason = json['latestSeasonNumber'];
    final season = rawSeason is int
        ? rawSeason
        : int.tryParse('${rawSeason ?? ''}');
    final rawConfidence = json['modelConfidence'] ?? json['confidence'];
    if (rawConfidence != null && rawConfidence is! num) return null;
    final modelConfidence = (rawConfidence as num?)?.toDouble() ?? 0.5;
    if (modelConfidence < 0 || modelConfidence > 1) return null;
    final aliases = <String>[];
    if (json['aliases'] case final List rawAliases) {
      for (final item in rawAliases) {
        final alias = '$item'.trim();
        if (alias.isNotEmpty &&
            alias.length <= 100 &&
            !aliases.contains(alias)) {
          aliases.add(alias);
        }
        if (aliases.length == 3) break;
      }
    }
    return RecommendationCandidate(
      title: title,
      originalTitle: _trim('${json['originalTitle'] ?? ''}', 100),
      aliases: aliases,
      year: year,
      mediaType: mediaType,
      category: category,
      latestSeasonNumber: season != null && season > 0 ? season : null,
      modelConfidence: modelConfidence,
      reason: _trim('${json['reason'] ?? ''}', 50),
    );
  }

  final String title;
  final String originalTitle;
  final List<String> aliases;
  final String year;
  final TmdbMediaType mediaType;
  final String category;
  final int? latestSeasonNumber;
  final double modelConfidence;
  final String reason;

  @Deprecated('Use modelConfidence')
  double get confidence => modelConfidence;

  String get identity =>
      [mediaType.name, _normalizeTitle(title), year].join(':');
  VideoSearchTarget get searchTarget => VideoSearchTarget(
    title: title,
    originalTitle: originalTitle,
    aliases: aliases,
    year: year,
    category: category,
    mediaType: mediaType,
    latestSeasonNumber: latestSeasonNumber,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'originalTitle': originalTitle,
    'aliases': aliases,
    'year': year,
    'mediaType': mediaType.name,
    'category': category.isEmpty ? mediaType.name : category,
    'latestSeasonNumber': latestSeasonNumber,
    'modelConfidence': modelConfidence,
    'reason': reason,
  };
}

class RecommendationPage {
  const RecommendationPage({
    this.index = 1,
    this.pageSize = 24,
    this.hasMore = false,
    this.nextCursor,
  });
  final int index;
  final int pageSize;
  final bool hasMore;
  final String? nextCursor;

  factory RecommendationPage.fromJson(Object? value) {
    if (value is! Map) return const RecommendationPage();
    final cursor = '${value['nextCursor'] ?? ''}'.trim();
    final index = _int(value['index']);
    final pageSize = _int(value['pageSize']);
    return RecommendationPage(
      index: index.clamp(1, 3),
      pageSize: pageSize.clamp(12, 24),
      hasMore: value['hasMore'] == true && cursor.isNotEmpty,
      nextCursor: cursor.isEmpty ? null : cursor,
    );
  }

  Map<String, dynamic> toJson() => {
    'index': index,
    'pageSize': pageSize,
    'hasMore': hasMore,
    'nextCursor': nextCursor,
  };
}

class RecommendationBatch {
  const RecommendationBatch({
    required this.items,
    required this.generatedAt,
    DateTime? servedAt,
    this.requestId = '',
    this.clientRequestId = '',
    this.mode = RecommendationMode.personalized,
    this.source = RecommendationSource.llm,
    this.expiresAt,
    this.sessionId,
    this.page = const RecommendationPage(),
    this.meta = const {},
    this.usage = const RecommendationUsage(),
    this.fromCache = false,
  }) : servedAt = servedAt ?? generatedAt;

  final String requestId;
  final String clientRequestId;
  final RecommendationMode mode;
  final RecommendationSource source;
  final DateTime generatedAt;
  final DateTime servedAt;
  final DateTime? expiresAt;
  final String? sessionId;
  final List<RecommendationCandidate> items;
  final RecommendationPage page;
  final Map<String, dynamic> meta;
  final RecommendationUsage usage;
  final bool fromCache;

  bool get isColdStart => mode == RecommendationMode.coldStart;
  RecommendationBatch asCached() => RecommendationBatch(
    requestId: requestId,
    clientRequestId: clientRequestId,
    mode: mode,
    source: source,
    items: items,
    generatedAt: generatedAt,
    servedAt: servedAt,
    expiresAt: expiresAt,
    sessionId: sessionId,
    page: page,
    meta: meta,
    usage: usage,
    fromCache: true,
  );

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'clientRequestId': clientRequestId,
    'mode': mode == RecommendationMode.coldStart
        ? 'cold_start'
        : 'personalized',
    'source': source.name,
    'items': items.map((item) => item.toJson()).toList(),
    'generatedAt': generatedAt.toIso8601String(),
    'servedAt': servedAt.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'sessionId': sessionId,
    'page': page.toJson(),
    'meta': meta,
    if (usage.totalTokens > 0) 'usage': usage.toJson(),
  };

  static RecommendationBatch? tryFromJson(Object? value) {
    if (value is! Map || value['items'] is! List) return null;
    final mode = switch ('${value['mode'] ?? ''}') {
      'cold_start' => RecommendationMode.coldStart,
      'personalized' || '' => RecommendationMode.personalized,
      _ => null,
    };
    final source = switch ('${value['source'] ?? ''}') {
      'none' => RecommendationSource.none,
      'llm' || '' => RecommendationSource.llm,
      _ => null,
    };
    if (mode == null || source == null) return null;
    final items = (value['items'] as List)
        .map(RecommendationCandidate.tryFromJson)
        .whereType<RecommendationCandidate>()
        .toList(growable: false);
    final generatedAt = DateTime.tryParse('${value['generatedAt'] ?? ''}');
    final servedAt =
        DateTime.tryParse('${value['servedAt'] ?? ''}') ?? generatedAt;
    if (generatedAt == null || servedAt == null) return null;
    return RecommendationBatch(
      requestId: '${value['requestId'] ?? ''}',
      clientRequestId: '${value['clientRequestId'] ?? ''}',
      mode: mode,
      source: source,
      items: items,
      generatedAt: generatedAt,
      servedAt: servedAt,
      expiresAt: DateTime.tryParse('${value['expiresAt'] ?? ''}'),
      sessionId: _nullableString(value['sessionId']),
      page: RecommendationPage.fromJson(value['page']),
      meta: value['meta'] is Map
          ? Map<String, dynamic>.from(value['meta'] as Map)
          : const {},
      usage: RecommendationUsage.fromJson(value['usage']),
    );
  }
}

String _normalizeTitle(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[\s·・—_\-:：/\\,.，。!！?？()（）\[\]【】]+'),
  '',
);
String _trim(String value, int maximum) {
  final trimmed = value.trim();
  return trimmed.length <= maximum ? trimmed : trimmed.substring(0, maximum);
}

String? _nullableString(Object? value) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;
