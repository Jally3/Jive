import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/features/home/curated_feed_controller.dart';
import 'package:jive/features/home/curated_video_card.dart';

void main() {
  testWidgets('renders Catalog metadata before a VOD match is ready', (
    tester,
  ) async {
    final slot = CuratedSearchSlot(
      catalogIndex: 0,
      catalogItem: const TmdbCatalogItem(
        tmdbId: 42,
        mediaType: TmdbMediaType.movie,
        category: 'movie',
        localizedTitle: '榜单影片',
        originalTitle: 'Catalog Movie',
        rating: 8.7,
        rank: 1,
      ),
      generation: 1,
      sourceName: '测试源',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            height: 280,
            child: CuratedVideoCard(slot: slot, onTap: () {}),
          ),
        ),
      ),
    );

    expect(find.text('榜单影片'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('8.7'), findsOneWidget);
    expect(find.text('等待搜索'), findsOneWidget);
  });

  testWidgets(
    'available state hides its status pill but keeps source metadata',
    (tester) async {
      final slot =
          CuratedSearchSlot(
              catalogIndex: 0,
              catalogItem: const TmdbCatalogItem(
                tmdbId: 42,
                mediaType: TmdbMediaType.movie,
                category: 'movie',
                localizedTitle: '榜单影片',
                originalTitle: 'Catalog Movie',
              ),
              generation: 1,
              sourceName: '测试源',
            )
            ..status = CuratedSlotStatus.available
            ..matchedVideo = const Video(id: '42', title: 'VOD 影片');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 180,
              height: 280,
              child: CuratedVideoCard(slot: slot, onTap: () {}),
            ),
          ),
        ),
      );

      expect(find.text('测试源 可播放'), findsNothing);
      expect(find.textContaining('测试源'), findsOneWidget);
    },
  );
}
