import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/prefetch_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prefetchWindowFor', () {
    test('wifi yields the full window', () {
      expect(
        prefetchWindowFor(PrefetchMode.auto, [ConnectivityResult.wifi]),
        prefetchWindowWifi,
      );
    });

    test('ethernet yields the full window', () {
      expect(
        prefetchWindowFor(PrefetchMode.auto, [ConnectivityResult.ethernet]),
        prefetchWindowWifi,
      );
    });

    test('cellular yields the reduced window', () {
      expect(
        prefetchWindowFor(PrefetchMode.auto, [ConnectivityResult.mobile]),
        prefetchWindowCellular,
      );
    });

    test('unknown connectivity disables prefetching', () {
      expect(prefetchWindowFor(PrefetchMode.auto, null), 0);
      expect(prefetchWindowFor(PrefetchMode.auto, const []), 0);
    });

    test('no network disables prefetching', () {
      expect(
        prefetchWindowFor(PrefetchMode.auto, [ConnectivityResult.none]),
        0,
      );
    });

    test('off mode disables prefetching even on wifi', () {
      expect(prefetchWindowFor(PrefetchMode.off, [ConnectivityResult.wifi]), 0);
    });
  });

  group('PrefetchModeNotifier', () {
    test('defaults to auto and persists mode changes', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(prefetchModeProvider.future),
        PrefetchMode.auto,
      );

      await container
          .read(prefetchModeProvider.notifier)
          .setMode(PrefetchMode.off);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prefetch_mode'), PrefetchMode.off.name);
    });

    test('restores a previously saved off mode', () async {
      SharedPreferences.setMockInitialValues({
        'prefetch_mode': PrefetchMode.off.name,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(prefetchModeProvider.future),
        PrefetchMode.off,
      );
    });
  });
}
