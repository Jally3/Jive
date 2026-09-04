import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/theme_mode_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('theme mode codec falls back safely to system', () {
    expect(decodeThemeMode(null), ThemeMode.system);
    expect(decodeThemeMode('unknown'), ThemeMode.system);
    expect(decodeThemeMode('light'), ThemeMode.light);
    expect(decodeThemeMode('dark'), ThemeMode.dark);
    expect(encodeThemeMode(ThemeMode.system), 'system');
  });

  test(
    'notifier starts from the preloaded mode and persists changes',
    () async {
      final container = ProviderContainer(
        overrides: [initialThemeModeProvider.overrideWithValue(ThemeMode.dark)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), ThemeMode.dark);
      await container.read(themeModeProvider.notifier).setMode(ThemeMode.light);

      expect(container.read(themeModeProvider), ThemeMode.light);
      expect(await loadThemeMode(), ThemeMode.light);
    },
  );
}
