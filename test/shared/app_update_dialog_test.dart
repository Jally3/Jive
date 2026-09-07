import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/theme.dart';
import 'package:jive/data/update/app_update_service.dart';
import 'package:jive/domain/app_update_info.dart';
import 'package:jive/shared/app_update_dialog.dart';

class _FakeGateway implements AppUpdateGateway {
  var openCalls = 0;

  @override
  Future<AppUpdateInfo?> checkForUpdate() async => null;

  @override
  Future<bool> openDownload(AppUpdateInfo update) async {
    openCalls++;
    return true;
  }
}

void main() {
  testWidgets('shows release notes and opens download on confirmation', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final update = AppUpdateInfo(
      versionName: '1.0.14',
      apkUrl: Uri.parse('https://example.com/jive.apk'),
      releaseNotes: const ['修复播放失败', '优化电视操作'],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () =>
                showAppUpdateDialog(context, update: update, gateway: gateway),
            child: const Text('show'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 1.0.14'), findsOneWidget);
    expect(find.textContaining('修复播放失败'), findsOneWidget);
    final laterButton = find.widgetWithText(OutlinedButton, '稍后');
    final downloadButton = find.widgetWithText(FilledButton, '立即下载');
    expect(
      tester.getSize(laterButton).width,
      tester.getSize(downloadButton).width,
    );
    expect(tester.getSize(laterButton).height, 48);
    expect(tester.getSize(downloadButton).height, 48);
    final laterStyle = tester.widget<OutlinedButton>(laterButton).style!;
    expect(
      laterStyle.foregroundColor?.resolve(const <WidgetState>{}),
      AppPalette.light.text,
    );
    expect(
      laterStyle.backgroundColor?.resolve(const <WidgetState>{}),
      AppPalette.light.elevated,
    );

    await tester.tap(find.text('立即下载'));
    await tester.pumpAndSettle();

    expect(gateway.openCalls, 1);
    expect(find.text('发现新版本 1.0.14'), findsNothing);
  });

  testWidgets('later closes the dialog without opening download', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final update = AppUpdateInfo(
      versionName: '1.0.14',
      apkUrl: Uri.parse('https://example.com/jive.apk'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showAppUpdateDialog(context, update: update, gateway: gateway),
            child: const Text('show'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();

    expect(gateway.openCalls, 0);
    expect(find.text('发现新版本 1.0.14'), findsNothing);
  });
}
