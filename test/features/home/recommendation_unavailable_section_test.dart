import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/recommendation.dart';
import 'package:jive/domain/tmdb_catalog.dart';
import 'package:jive/features/home/recommendation_unavailable_section.dart';
import 'package:jive/features/home/recommended_feed_controller.dart';

void main() {
  testWidgets('many unavailable candidates stay collapsed with a summary', (
    tester,
  ) async {
    final slots = List.generate(
      5,
      (index) => _slot('候选 $index', RecommendedCandidateStatus.notFound),
    );
    await _pump(tester, slots: slots, playableCount: 2);

    expect(find.text('5 部需要手动确认'), findsOneWidget);
    expect(find.text('未找到 5'), findsOneWidget);
    expect(find.text('候选 0'), findsNothing);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('候选 0'), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsNWidgets(5));
  });

  testWidgets('four or fewer candidates are expanded automatically', (
    tester,
  ) async {
    final slot = _slot('待确认影片', RecommendedCandidateStatus.ambiguous)
      ..rawResultCount = 8;
    var tapped = false;
    await _pump(
      tester,
      slots: [slot],
      playableCount: 3,
      onTap: (_) => tapped = true,
    );
    await tester.pumpAndSettle();

    expect(find.text('待确认影片'), findsOneWidget);
    expect(find.text('有 8 条结果，点击确认'), findsOneWidget);
    await tester.tap(
      find.byKey(
        ValueKey('recommendation-unavailable-${slot.candidate.identity}'),
      ),
    );
    expect(tapped, isTrue);
  });

  testWidgets('no playable result expands unavailable candidates', (
    tester,
  ) async {
    final slots = List.generate(
      5,
      (index) => _slot('无资源 $index', RecommendedCandidateStatus.notFound),
    );
    await _pump(tester, slots: slots, playableCount: 0);
    await tester.pumpAndSettle();

    expect(find.text('无资源 0'), findsOneWidget);
  });
}

RecommendedCandidateSlot _slot(
  String title,
  RecommendedCandidateStatus status,
) => RecommendedCandidateSlot(
  candidate: RecommendationCandidate(
    title: title,
    mediaType: TmdbMediaType.movie,
  ),
  pageIndex: 1,
  candidatePosition: 1,
  sessionId: 'session',
)..status = status;

Future<void> _pump(
  WidgetTester tester, {
  required List<RecommendedCandidateSlot> slots,
  required int playableCount,
  ValueChanged<RecommendedCandidateSlot>? onTap,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: RecommendationUnavailableSection(
          slots: slots,
          playableCount: playableCount,
          onTap: onTap ?? (_) {},
        ),
      ),
    ),
  ),
);
