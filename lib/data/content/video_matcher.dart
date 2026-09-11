import '../../domain/tmdb_catalog.dart';
import '../../domain/video.dart';
import '../../domain/video_search_target.dart';

class VideoMatch {
  const VideoMatch({
    required this.video,
    required this.score,
    this.strategy = VideoMatchStrategy.strict,
  });
  final Video video;
  final int score;
  final VideoMatchStrategy strategy;
}

enum VideoMatchStrategy { strict, varietyLatestSeason }

enum VideoMatchOutcome { matched, notFound, ambiguous }

class VideoMatchResult {
  const VideoMatchResult._(this.outcome, this.match);

  const VideoMatchResult.matched(VideoMatch match)
    : this._(VideoMatchOutcome.matched, match);
  const VideoMatchResult.notFound() : this._(VideoMatchOutcome.notFound, null);
  const VideoMatchResult.ambiguous()
    : this._(VideoMatchOutcome.ambiguous, null);

  final VideoMatchOutcome outcome;
  final VideoMatch? match;
}

class VideoMatcher {
  const VideoMatcher({this.minimumScore = 120, this.minimumLead = 25});

  final int minimumScore;
  final int minimumLead;

  VideoMatch? match(TmdbCatalogItem target, List<Video> results) =>
      matchTarget(VideoSearchTarget.fromCatalog(target), results).match;

  VideoMatchResult matchTarget(VideoSearchTarget target, List<Video> results) {
    final strict = _matchStrict(target, results);
    if (strict.outcome != VideoMatchOutcome.notFound ||
        target.category != 'variety') {
      return strict;
    }
    return _matchVarietyLatestSeason(target, results);
  }

  VideoMatchResult _matchStrict(VideoSearchTarget target, List<Video> results) {
    final scored = <({Video video, int score, int? season})>[];
    for (final candidate in results.take(10)) {
      final score = _score(target, candidate);
      if (score == null) continue;
      scored.add((
        video: candidate,
        score: score,
        season: parseSeasonNumber(candidate.title),
      ));
    }
    if (scored.isEmpty) return const VideoMatchResult.notFound();

    var eligible = scored;
    if (target.mediaType == TmdbMediaType.tv) {
      final desiredSeason = target.latestSeasonNumber;
      if (desiredSeason != null) {
        final exactSeason = eligible
            .where((entry) => entry.season == desiredSeason)
            .toList();
        if (exactSeason.isNotEmpty) eligible = exactSeason;
      } else {
        final seasons = eligible.map((entry) => entry.season).whereType<int>();
        if (seasons.isNotEmpty) {
          final latest = seasons.reduce((a, b) => a > b ? a : b);
          eligible = eligible.where((entry) => entry.season == latest).toList();
        }
      }
    }

    eligible.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.video.updatedAt.compareTo(a.video.updatedAt);
    });
    final best = eligible.first;
    if (best.score < minimumScore) return const VideoMatchResult.notFound();
    if (eligible.length > 1 && best.score - eligible[1].score < minimumLead) {
      final differentIdentity =
          best.video.sourceVideoId != eligible[1].video.sourceVideoId;
      if (differentIdentity) return const VideoMatchResult.ambiguous();
    }
    return VideoMatchResult.matched(
      VideoMatch(video: best.video, score: best.score),
    );
  }

  VideoMatchResult _matchVarietyLatestSeason(
    VideoSearchTarget target,
    List<Video> results,
  ) {
    final targetBases = {
      baseVideoTitle(target.title),
      baseVideoTitle(target.originalTitle),
      ...target.aliases.map(baseVideoTitle),
    }..remove('');
    final candidates = <({Video video, int season, int year})>[];
    for (final candidate in results.take(20)) {
      if (!_isVariety(candidate)) continue;
      final season = parseSeasonNumber(candidate.title);
      if (season == null || season <= 0) continue;
      if (!targetBases.contains(baseVideoTitle(candidate.title))) continue;
      candidates.add((
        video: candidate,
        season: season,
        year: int.tryParse(_year(candidate.year)) ?? 0,
      ));
    }
    if (candidates.isEmpty) return const VideoMatchResult.notFound();
    candidates.sort((a, b) {
      final bySeason = b.season.compareTo(a.season);
      if (bySeason != 0) return bySeason;
      final byYear = b.year.compareTo(a.year);
      if (byYear != 0) return byYear;
      return b.video.updatedAt.compareTo(a.video.updatedAt);
    });
    return VideoMatchResult.matched(
      VideoMatch(
        video: candidates.first.video,
        score: minimumScore,
        strategy: VideoMatchStrategy.varietyLatestSeason,
      ),
    );
  }

  int? _score(VideoSearchTarget target, Video candidate) {
    final title = normalizeVideoTitle(candidate.title);
    if (title.isEmpty) return null;
    final localized = normalizeVideoTitle(target.title);
    final original = normalizeVideoTitle(target.originalTitle);
    final aliases = target.aliases
        .map(normalizeVideoTitle)
        .where((value) => value.isNotEmpty);
    final candidateBase = baseVideoTitle(candidate.title);
    final targetBases = {
      baseVideoTitle(target.title),
      baseVideoTitle(target.originalTitle),
      ...target.aliases.map(baseVideoTitle),
    }..remove('');

    var score = 0;
    var titleMatched = false;
    if (title == localized && localized.isNotEmpty) {
      score += 120;
      titleMatched = true;
    } else if ((title == original && original.isNotEmpty) ||
        aliases.contains(title)) {
      score += 100;
      titleMatched = true;
    } else if (targetBases.contains(candidateBase)) {
      score += 70;
      titleMatched = true;
    } else if (_longContains(title, localized) ||
        _longContains(localized, title) ||
        _longContains(title, original) ||
        _longContains(original, title)) {
      score += 35;
      titleMatched = true;
    }
    if (!titleMatched) return null;

    final candidateType = _inferMediaType(candidate);
    if (candidateType != null && target.mediaType != null) {
      if (candidateType == target.mediaType) {
        score += 20;
      } else {
        return null;
      }
    }

    final season = parseSeasonNumber(candidate.title);
    final desiredSeason = target.latestSeasonNumber;
    if (desiredSeason != null && season != null) {
      if (desiredSeason == season) {
        score += 40;
      } else {
        return null;
      }
    }

    final targetYear = _year(target.year);
    final candidateYear = _year(candidate.year);
    if (targetYear.isNotEmpty && candidateYear.isNotEmpty) {
      final difference = (int.parse(targetYear) - int.parse(candidateYear))
          .abs();
      if (difference == 0) {
        score += 30;
      } else if (difference == 1) {
        score += 10;
      } else if (!(target.mediaType == TmdbMediaType.tv &&
          target.latestSeasonNumber != null)) {
        score -= 40;
      }
    }
    return score;
  }

  bool _longContains(String a, String b) =>
      a.length >= 4 && b.length >= 4 && a.contains(b);

  bool _isVariety(Video video) =>
      RegExp(r'综艺|variety').hasMatch(video.category.toLowerCase());

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
}

String normalizeVideoTitle(String value) => value
    .toLowerCase()
    .replaceAll('Ⅱ', '2')
    .replaceAll('Ⅲ', '3')
    .replaceAll(RegExp(r'[\s·・—_\-:：/\\,.，。!！?？()（）\[\]【】]+'), '');

String baseVideoTitle(String value) {
  var normalized = normalizeVideoTitle(value);
  normalized = normalized.replaceAll(
    RegExp(r'(?:第?[0-9一二三四五六七八九十]+季|season[0-9]+)$'),
    '',
  );
  return normalized;
}

int? parseSeasonNumber(String value) => parseVideoSeasonNumber(value);

String _year(String value) =>
    RegExp(r'(19|20)\d{2}').firstMatch(value)?.group(0) ?? '';
