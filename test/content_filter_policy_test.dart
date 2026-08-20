import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/content_filter_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('content filter defaults to enabled', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(contentFilterEnabledProvider.future), isTrue);
  });

  test('toggle persists across rebuilds', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(contentFilterEnabledProvider.notifier)
        .setEnabled(false);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('content_filter_enabled'), isFalse);

    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    expect(await fresh.read(contentFilterEnabledProvider.future), isFalse);
  });
}
