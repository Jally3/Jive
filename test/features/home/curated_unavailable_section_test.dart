import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/features/home/curated_feed_controller.dart';
import 'package:jive/features/home/curated_unavailable_section.dart';

void main() {
  testWidgets('unmatched titles stay collapsed until explicitly expanded', (
    tester,
  ) async {
    const item = TmdbCatalogItem(
      tmdbId: 1,
      mediaType: TmdbMediaType.movie,
      category: 'movie',
      localizedTitle: '未匹配影片',
      originalTitle: 'Unmatched',
    );
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CuratedUnavailableSection(
              entries: const [
                CuratedFeedEntry(
                  catalogItem: item,
                  status: CuratedMatchStatus.notFound,
                ),
              ],
              onSearch: (_) => tapped = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('当前来源无结果 1 部'), findsOneWidget);
    expect(find.text('未匹配影片'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('curated-unavailable-section')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('curated-unavailable-tmdb:movie:1')),
    );

    expect(tapped, isTrue);
  });

  testWidgets('distinguishes raw candidates from an empty source result', (
    tester,
  ) async {
    const item = TmdbCatalogItem(
      tmdbId: 2,
      mediaType: TmdbMediaType.tv,
      category: 'variety',
      localizedTitle: '待确认综艺',
      originalTitle: 'Review Show',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CuratedUnavailableSection(
              entries: const [
                CuratedFeedEntry(
                  catalogItem: item,
                  status: CuratedMatchStatus.ambiguous,
                  rawResultCount: 13,
                  query: '待确认综艺',
                  candidateTitles: ['待确认综艺 第七季'],
                ),
              ],
              onSearch: (_) {},
              failedCount: 2,
            ),
          ),
        ),
      ),
    );

    expect(find.text('当前来源有结果但无法确认 1 部'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('curated-unavailable-section')));
    await tester.pumpAndSettle();
    expect(find.text('有 13 条结果，点击确认'), findsOneWidget);
    expect(find.text('另有 2 部当前来源请求失败，下拉刷新后重试'), findsOneWidget);
  });
}
