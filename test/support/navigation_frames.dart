import 'package:flutter_test/flutter_test.dart';

/// 导航含持续呼吸动画，等待有限的换页、键盘与选中动画即可。
Future<void> pumpNavigationFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}
