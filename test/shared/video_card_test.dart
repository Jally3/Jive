import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/shared/video_card.dart';

const _video = Video(id: '1', title: '测试影片', sourceId: 'storm');

Future<void> _pumpCard(
  WidgetTester tester, {
  VoidCallback? onTap,
  VideoCardOverlay? overlay,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 320,
            child: VideoCard(
              video: _video,
              onTap: onTap ?? () {},
              overlay: overlay,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpVideo(
  WidgetTester tester,
  Video video, {
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 320,
          child: VideoCard(video: video, onTap: onTap ?? () {}),
        ),
      ),
    ),
  );
}

BoxDecoration? _cardForegroundDecoration(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .ancestor(of: find.byType(InkWell), matching: find.byType(Container))
        .first,
  );
  return container.foregroundDecoration as BoxDecoration?;
}

void main() {
  testWidgets('shows TMDB rank and rating badges', (tester) async {
    await _pumpVideo(
      tester,
      const Video(id: '1', title: '测试影片', rank: 3, rating: 8.26),
    );

    expect(find.text('#3'), findsOneWidget);
    expect(find.text('8.3'), findsOneWidget);
  });

  testWidgets('touch mode keeps the focus border hidden', (tester) async {
    await _pumpCard(tester);
    // 触摸点击不应留下焦点描边。
    await tester.tap(find.byType(VideoCard));
    await tester.pump();
    expect(_cardForegroundDecoration(tester), isNull);
  });

  testWidgets('d-pad focus shows an accent border and enter activates', (
    tester,
  ) async {
    var tapped = 0;
    await _pumpCard(tester, onTap: () => tapped++);

    // 任意按键将焦点高亮切到 traditional 模式（模拟遥控器环境）。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    final cardFocusNode = Focus.of(tester.element(find.byType(InkWell)));
    cardFocusNode.requestFocus();
    await tester.pump();

    final decoration = _cardForegroundDecoration(tester);
    expect(decoration, isNotNull);
    expect(decoration!.border, Border.all(color: AppColors.accent, width: 2));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tapped, 1);

    // 失焦后描边消失。失焦回调与依赖重建分两帧完成，需要两次 pump。
    cardFocusNode.unfocus();
    await tester.pump();
    await tester.pump();
    expect(_cardForegroundDecoration(tester), isNull);
  });

  testWidgets('renders latest episode and unread episode badge on poster', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      overlay: const VideoCardOverlay(
        bottomLabel: '更新至 第12集',
        badgeLabel: '新增2集',
      ),
    );

    expect(
      find.byKey(const ValueKey('video-card-bottom-label')),
      findsOneWidget,
    );
    expect(find.text('更新至 第12集'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-card-badge')), findsOneWidget);
    expect(find.text('新增2集'), findsOneWidget);
    final badge = find.byKey(const ValueKey('video-card-badge'));
    expect(tester.widget<CustomPaint>(badge).painter, isNotNull);
    expect(tester.widget<Text>(find.text('新增2集')).style?.color, Colors.white);
    final poster = find.byType(AspectRatio).first;
    expect(tester.getRect(badge).top, tester.getRect(poster).top);
    expect(tester.getRect(badge).right, tester.getRect(poster).right);
  });

  testWidgets('keeps latest episode when unread badge is absent', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      overlay: const VideoCardOverlay(bottomLabel: '更新至 第12集'),
    );

    expect(find.text('更新至 第12集'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-card-badge')), findsNothing);
  });
}
