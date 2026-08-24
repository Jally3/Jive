import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/playback/prefetch_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prefetchAheadFor', () {
    test('wifi yields the full ahead target', () {
      expect(
        prefetchAheadFor(PrefetchMode.auto, [ConnectivityResult.wifi]),
        prefetchAheadWifi,
      );
    });

    test('ethernet yields the full ahead target', () {
      expect(
        prefetchAheadFor(PrefetchMode.auto, [ConnectivityResult.ethernet]),
        prefetchAheadWifi,
      );
    });

    test('cellular yields the reduced ahead target', () {
      expect(
        prefetchAheadFor(PrefetchMode.auto, [ConnectivityResult.mobile]),
        prefetchAheadCellular,
      );
    });

    test('unknown connectivity disables prefetching', () {
      expect(prefetchAheadFor(PrefetchMode.auto, null), Duration.zero);
      expect(prefetchAheadFor(PrefetchMode.auto, const []), Duration.zero);
    });

    test('no network disables prefetching', () {
      expect(
        prefetchAheadFor(PrefetchMode.auto, [ConnectivityResult.none]),
        Duration.zero,
      );
    });

    test('off mode disables prefetching even on wifi', () {
      expect(
        prefetchAheadFor(PrefetchMode.off, [ConnectivityResult.wifi]),
        Duration.zero,
      );
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
