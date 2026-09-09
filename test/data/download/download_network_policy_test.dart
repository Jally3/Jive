import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/download/download_network_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Wi-Fi and ethernet always allow downloads', () {
    expect(
      downloadNetworkAccessFor(false, [ConnectivityResult.wifi]),
      DownloadNetworkAccess.allowed,
    );
    expect(
      downloadNetworkAccessFor(false, [ConnectivityResult.ethernet]),
      DownloadNetworkAccess.allowed,
    );
  });

  test('cellular downloads require explicit permission', () {
    expect(
      downloadNetworkAccessFor(false, [ConnectivityResult.mobile]),
      DownloadNetworkAccess.cellularBlocked,
    );
    expect(
      downloadNetworkAccessFor(true, [ConnectivityResult.mobile]),
      DownloadNetworkAccess.allowed,
    );
  });

  test('missing or unknown connectivity blocks downloads', () {
    expect(
      downloadNetworkAccessFor(false, null),
      DownloadNetworkAccess.unavailable,
    );
    expect(
      downloadNetworkAccessFor(false, [ConnectivityResult.none]),
      DownloadNetworkAccess.unavailable,
    );
  });

  test('cellular preference defaults off and persists changes', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container.read(allowCellularDownloadsProvider.future),
      isFalse,
    );
    await container
        .read(allowCellularDownloadsProvider.notifier)
        .setAllowed(true);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(downloadAllowCellularKey), isTrue);
  });
}
