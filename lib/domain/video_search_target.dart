import 'tmdb_catalog.dart';
import 'video.dart';

/// 跨来源检索使用的稳定目标，不依赖某个来源已经存在的 [VideoRef]。
class VideoSearchTarget {
  const VideoSearchTarget({
    required this.title,
    this.originalTitle = '',
    this.aliases = const [],
    this.year = '',
    this.category = '',
    this.mediaType,
    this.latestSeasonNumber,
  });

  factory VideoSearchTarget.fromCatalog(TmdbCatalogItem item) =>
      VideoSearchTarget(
        title: item.localizedTitle,
        originalTitle: item.originalTitle,
        aliases: item.aliases,
        year: _year(item.releaseDate).isNotEmpty
            ? _year(item.releaseDate)
            : _year(item.sortDate),
        category: item.category,
        mediaType: item.mediaType,
        latestSeasonNumber: item.latestSeasonNumber,
      );

  factory VideoSearchTarget.fromVideo(Video video) => VideoSearchTarget(
    title: video.title,
    year: _year(video.year),
    category: _catalogCategory(video),
    mediaType: _inferMediaType(video),
    latestSeasonNumber: parseVideoSeasonNumber(video.title),
  );

  final String title;
  final String originalTitle;
  final List<String> aliases;
  final String year;
  final String category;
  final TmdbMediaType? mediaType;
  final int? latestSeasonNumber;

  List<String> get searchQueries {
    final seen = <String>{};
    return [title, originalTitle, ...aliases]
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .toList(growable: false);
  }
}

String _catalogCategory(Video video) {
  final value = '${video.category} ${video.remarks}'.toLowerCase();
  return RegExp(r'综艺|variety').hasMatch(value) ? 'variety' : '';
}

TmdbMediaType? _inferMediaType(Video video) {
  final value = '${video.category} ${video.remarks}'.toLowerCase();
  if (RegExp(r'电影|movie|剧场版').hasMatch(value)) {
    return TmdbMediaType.movie;
  }
  if (RegExp(r'电视剧|连续剧|番剧|综艺|tv|series').hasMatch(value)) {
    return TmdbMediaType.tv;
  }
  return null;
}

int? parseVideoSeasonNumber(String value) {
  final normalized = value.toLowerCase();
  final digit = RegExp(r'(?:第\s*|season\s*)(\d+)\s*季?').firstMatch(normalized);
  if (digit != null) return int.tryParse(digit.group(1)!);
  final chinese = RegExp(r'第\s*([一二三四五六七八九十]+)\s*季').firstMatch(normalized);
  return chinese == null ? null : _parseChineseNumber(chinese.group(1)!);
}

int? _parseChineseNumber(String value) {
  const digits = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (value == '十') return 10;
  if (value.startsWith('十')) return 10 + (digits[value.substring(1)] ?? 0);
  if (value.endsWith('十')) return (digits[value.substring(0, 1)] ?? 0) * 10;
  if (value.contains('十')) {
    final parts = value.split('十');
    return (digits[parts[0]] ?? 0) * 10 + (digits[parts[1]] ?? 0);
  }
  return digits[value];
}

String _year(String value) =>
    RegExp(r'(19|20)\d{2}').firstMatch(value)?.group(0) ?? '';
