import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/content/video_matcher.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/video_search_target.dart';

void main() {
  const matcher = VideoMatcher();

  test('matches exact movie title and year', () {
    final result = matcher.match(
      _item(mediaType: TmdbMediaType.movie, releaseDate: '2026-04-03'),
      const [Video(id: '1', title: '示例电影', category: '电影片', year: '2026')],
    );

    expect(result?.video.id, '1');
    expect(result!.score, greaterThanOrEqualTo(120));
  });

  test('rejects explicit movie and tv conflict', () {
    final result = matcher.match(_item(mediaType: TmdbMediaType.movie), const [
      Video(id: '1', title: '示例电影', category: '电视剧'),
    ]);

    expect(result, isNull);
  });

  test('selects the requested latest season', () {
    final result = matcher.match(
      _item(mediaType: TmdbMediaType.tv, latestSeasonNumber: 3),
      const [
        Video(id: '1', title: '示例电影 第一季', category: '电视剧'),
        Video(id: '3', title: '示例电影 第三季', category: '电视剧'),
        Video(id: '2', title: '示例电影 第二季', category: '电视剧'),
      ],
    );

    expect(result?.video.id, '3');
  });

  test('does not use containment for short titles', () {
    final result = matcher.match(
      const TmdbCatalogItem(
        tmdbId: 1,
        mediaType: TmdbMediaType.movie,
        category: 'movie',
        localizedTitle: '家',
        originalTitle: '',
      ),
      const [Video(id: '1', title: '回家', category: '电影片')],
    );

    expect(result, isNull);
  });

  test('treats generic animation category as media-type neutral', () {
    final result = matcher.match(
      const TmdbCatalogItem(
        tmdbId: 4,
        mediaType: TmdbMediaType.movie,
        category: 'animation',
        localizedTitle: '动画之家',
        originalTitle: 'Animation Home',
      ),
      const [Video(id: '4', title: '动画之家', category: '动漫')],
    );

    expect(result?.video.id, '4');
  });

  test('variety fallback selects the highest explicit season', () {
    final result = matcher.match(
      const TmdbCatalogItem(
        tmdbId: 121876,
        mediaType: TmdbMediaType.tv,
        category: 'variety',
        localizedTitle: '花儿与少年',
        originalTitle: '花儿与少年',
        releaseDate: '2014-04-25',
      ),
      const [
        Video(id: '8', title: '花儿与少年 第八季', category: '综艺', year: '2026'),
        Video(
          id: 'special',
          title: '花儿与少年 第九季 会员彩蛋',
          category: '综艺',
          year: '2027',
        ),
        Video(id: '6', title: '花儿与少年 第六季', category: '综艺', year: '2024'),
        Video(id: 'spin-off', title: '花儿与少年远行记', category: '综艺', year: '2027'),
      ],
    );

    expect(result?.video.id, '8');
    expect(result?.strategy, VideoMatchStrategy.varietyLatestSeason);
  });

  test('variety fallback can inspect results beyond the strict top ten', () {
    final results = [
      for (var i = 0; i < 10; i++)
        Video(id: 'other-$i', title: '其他节目$i', category: '综艺'),
      const Video(id: '3', title: '示例节目 第三季', category: '综艺', year: '2025'),
    ];

    final result = matcher.matchTarget(
      const VideoSearchTarget(
        title: '示例节目',
        year: '2018',
        category: 'variety',
        mediaType: TmdbMediaType.tv,
      ),
      results,
    );

    expect(result.match?.video.id, '3');
    expect(result.match?.strategy, VideoMatchStrategy.varietyLatestSeason);
  });

  test('latest-season fallback does not apply to an ordinary tv target', () {
    final result = matcher.matchTarget(
      const VideoSearchTarget(
        title: '示例剧集',
        year: '2014',
        category: 'tv',
        mediaType: TmdbMediaType.tv,
      ),
      const [Video(id: '8', title: '示例剧集 第八季', category: '电视剧', year: '2026')],
    );

    expect(result.outcome, VideoMatchOutcome.notFound);
  });

  test('variety fallback does not override an ambiguous strict match', () {
    final result = matcher.matchTarget(
      const VideoSearchTarget(
        title: '示例综艺',
        category: 'variety',
        mediaType: TmdbMediaType.tv,
      ),
      const [
        Video(id: '1', title: '示例综艺', category: '综艺'),
        Video(id: '2', title: '示例综艺', category: '综艺'),
      ],
    );

    expect(result.outcome, VideoMatchOutcome.ambiguous);
  });
}

TmdbCatalogItem _item({
  required TmdbMediaType mediaType,
  String releaseDate = '',
  int? latestSeasonNumber,
}) => TmdbCatalogItem(
  tmdbId: 1,
  mediaType: mediaType,
  category: mediaType.name,
  localizedTitle: '示例电影',
  originalTitle: 'Example',
  releaseDate: releaseDate,
  latestSeasonNumber: latestSeasonNumber,
);
