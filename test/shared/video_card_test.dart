import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/shared/video_card.dart';

const _video = Video(id: '1', title: '测试影片', sourceId: 'storm');

Future<void> _pumpCard(WidgetTester tester, {VoidCallback? onTap}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 320,
            child: VideoCard(video: _video, onTap: onTap ?? () {}),
          ),
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
}
