import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/theme.dart';

void main() {
  test('light theme exposes the warm daylight semantic palette', () {
    final theme = buildLightTheme();
    final palette = theme.extension<AppPalette>()!;

    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, const Color(0xFFF7F5F0));
    expect(palette.surface, const Color(0xFFFFFFFF));
    expect(palette.accentForeground, const Color(0xFF8A5700));
    expect(theme.colorScheme.onSurface, palette.text);
  });

  test('dark theme preserves the Midnight Cinema palette', () {
    final theme = buildDarkTheme();
    final palette = theme.extension<AppPalette>()!;

    expect(theme.brightness, Brightness.dark);
    expect(palette.background, AppColors.background);
    expect(palette.accent, AppColors.accent);
    expect(palette.accentForeground, AppColors.accent);
  });

  testWidgets('context palette follows the active Material theme', (
    tester,
  ) async {
    late AppPalette palette;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) {
            palette = context.appColors;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(palette, AppPalette.light);
  });
}
