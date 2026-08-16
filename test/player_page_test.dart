import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/playback_status.dart';
import 'package:jive/features/player_page.dart';

Video _video() => Video(
  id: '1',
  title: '测试剧集',
  description: '这是一部测试剧集的简介。',
  episodes: List.generate(
    3,
    (i) => Episode(
      id: '${i + 1}',
      name: '第${i + 1}集',
      url: 'https://example.com/$i.m3u8',
    ),
  ),
);

void main() {
  testWidgets('PlaybackStatusIndicator shows mode and handles long press', (
    tester,
  ) async {
    var longPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackStatusIndicator(
            status: const PlaybackStatus(
              mode: PlaybackMode.streamingAndCaching,
            ),
            onLongPress: () => longPressed = true,
          ),
        ),
      ),
    );

    expect(find.text('边下边播'), findsOneWidget);
    await tester.longPress(find.byType(PlaybackStatusIndicator));
    expect(longPressed, isTrue);
  });

  testWidgets(
    'PlayerInfoPanel shows description and selectable episode chips',
    (tester) async {
      final video = _video();
      Episode? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerInfoPanel(
              video: video,
              current: video.episodes[1],
              onEpisodeTap: (e) => tapped = e,
            ),
          ),
        ),
      );

      expect(find.text('简介'), findsOneWidget);
      expect(find.text('这是一部测试剧集的简介。'), findsOneWidget);
      expect(find.text('选集（3）'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(3));

      final current = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '第2集'),
      );
      expect(current.selected, isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '第3集'));
      expect(tapped?.id, '3');
      expect(tapped?.name, '第3集');
    },
  );

  testWidgets('PlayerInfoPanel shows fallback when description is empty', (
    tester,
  ) async {
    final video = _video();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerInfoPanel(
            video: Video(
              id: video.id,
              title: video.title,
              episodes: video.episodes,
            ),
            current: video.episodes.first,
            onEpisodeTap: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('暂无简介'), findsOneWidget);
  });
}
