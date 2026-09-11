import 'dart:async';

import '../../domain/video.dart';
import '../../domain/video_search_target.dart';
import '../../domain/vod_source.dart';
import '../video_repository.dart';
import '../vod_source/vod_source_registry.dart';
import 'video_matcher.dart';

enum CrossSourceSearchStatus { matched, notFound, ambiguous, requestFailed }

class CrossSourceSearchResult {
  const CrossSourceSearchResult({
    required this.source,
    required this.status,
    this.candidate,
    this.error,
  });

  final VodSource source;
  final CrossSourceSearchStatus status;
  final Video? candidate;
  final String? error;
}

/// 首页与详情页共用的跨来源检索、严格匹配和播放信息解析入口。
class CrossSourceSearchService {
  const CrossSourceSearchService({
    required this.repository,
    required this.registry,
    this.matcher = const VideoMatcher(),
    this.requestTimeout = const Duration(seconds: 8),
  });

  final VideoRepository repository;
  final VodSourceRegistry registry;
  final VideoMatcher matcher;
  final Duration requestTimeout;

  List<VodSource> candidateSources({String? excludedSourceId, int? limit = 3}) {
    final sources = registry.searchableSources.where(
      (source) => source.id != excludedSourceId,
    );
    return limit == null ? sources.toList() : sources.take(limit).toList();
  }

  Future<CrossSourceSearchResult> searchSource(
    VodSource source,
    VideoSearchTarget target,
  ) async {
    final queries = target.searchQueries;
    if (queries.isEmpty) {
      return CrossSourceSearchResult(
        source: source,
        status: CrossSourceSearchStatus.notFound,
      );
    }
    var sawAmbiguous = false;
    try {
      for (final query in queries.take(2)) {
        final page = await repository
            .fetchPage(source, page: 1, keyword: query)
            .timeout(requestTimeout);
        final result = matcher.matchTarget(target, page.items);
        if (result.outcome == VideoMatchOutcome.matched) {
          return CrossSourceSearchResult(
            source: source,
            status: CrossSourceSearchStatus.matched,
            candidate: result.match!.video,
          );
        }
        sawAmbiguous =
            sawAmbiguous || result.outcome == VideoMatchOutcome.ambiguous;
      }
      return CrossSourceSearchResult(
        source: source,
        status: sawAmbiguous
            ? CrossSourceSearchStatus.ambiguous
            : CrossSourceSearchStatus.notFound,
      );
    } catch (error) {
      return CrossSourceSearchResult(
        source: source,
        status: CrossSourceSearchStatus.requestFailed,
        error: '$error',
      );
    }
  }

  Future<List<CrossSourceSearchResult>> search(
    VideoSearchTarget target, {
    String? excludedSourceId,
    int? limit = 3,
  }) async {
    final sources = candidateSources(
      excludedSourceId: excludedSourceId,
      limit: limit,
    );
    return Future.wait([
      for (final source in sources) searchSource(source, target),
    ]);
  }

  Future<Video> resolve(CrossSourceSearchResult result) {
    final candidate = result.candidate;
    if (candidate == null || result.status != CrossSourceSearchStatus.matched) {
      throw StateError('该来源没有可解析的影片');
    }
    return repository.resolvePlayback(result.source, candidate.ref);
  }
}
