import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_ttl_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CacheTtlNotifier', () {
    test('defaults to clean one hour after exit', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(cacheTtlProvider.future),
        CacheTtlOption.hours1,
      );
    });

    test('keeps newly supported legacy values', () async {
      SharedPreferences.setMockInitialValues({'cache_ttl_option': 'days3'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(cacheTtlProvider.future),
        CacheTtlOption.days3,
      );
    });

    test(
      'migrates removed legacy values without shortening retention',
      () async {
        for (final migration in {
          'off': CacheTtlOption.never,
          'days5': CacheTtlOption.days7,
          'days30': CacheTtlOption.never,
        }.entries) {
          SharedPreferences.setMockInitialValues({
            'cache_ttl_option': migration.key,
          });
          final container = ProviderContainer();
          expect(
            await container.read(cacheTtlProvider.future),
            migration.value,
          );
          container.dispose();
        }
      },
    );

    test('persists option changes', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(cacheTtlProvider.notifier)
          .setOption(CacheTtlOption.hours5);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cache_ttl_option'), 'hours5');
    });

    test('persists disabled automatic cleanup', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(cacheTtlProvider.notifier)
          .setOption(CacheTtlOption.never);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cache_ttl_option'), 'never');
    });
  });

  group('CacheTtlOptionMaxAge', () {
    test('only onExit triggers exit cleanup', () {
      expect(CacheTtlOption.onExit.cleanOnExit, isTrue);
      expect(CacheTtlOption.never.cleanOnExit, isFalse);
      expect(CacheTtlOption.hours1.cleanOnExit, isFalse);
      expect(CacheTtlOption.hours5.cleanOnExit, isFalse);
      expect(CacheTtlOption.days1.cleanOnExit, isFalse);
      expect(CacheTtlOption.days3.cleanOnExit, isFalse);
      expect(CacheTtlOption.days7.cleanOnExit, isFalse);
    });

    test('fallback max ages', () {
      expect(CacheTtlOption.never.maxAge, isNull);
      expect(CacheTtlOption.onExit.maxAge, const Duration(days: 1));
      expect(CacheTtlOption.hours1.maxAge, const Duration(hours: 1));
      expect(CacheTtlOption.hours5.maxAge, const Duration(hours: 5));
      expect(CacheTtlOption.days1.maxAge, const Duration(days: 1));
      expect(CacheTtlOption.days3.maxAge, const Duration(days: 3));
      expect(CacheTtlOption.days7.maxAge, const Duration(days: 7));
    });
  });
}
