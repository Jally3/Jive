import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/app_update_info.dart';

void main() {
  test('parses a valid version manifest', () {
    final update = AppUpdateInfo.tryParse({
      'latestVersionName': '1.0.14',
      'apkUrl': 'https://download.example.com/jive.apk',
      'releaseNotes': [' Fix playback ', '', 42, 'TV controls'],
    });

    expect(update, isNotNull);
    expect(update!.versionName, '1.0.14');
    expect(update.apkUrl.host, 'download.example.com');
    expect(update.releaseNotes, ['Fix playback', 'TV controls']);
  });

  test('accepts the legacy versionName key', () {
    final update = AppUpdateInfo.tryParse({
      'versionName': '1.0.15',
      'apkUrl': 'https://download.example.com/jive.apk',
    });

    expect(update?.versionName, '1.0.15');
  });

  test('rejects invalid or insecure manifests', () {
    expect(AppUpdateInfo.tryParse(null), isNull);
    expect(
      AppUpdateInfo.tryParse({
        'latestVersionName': '1.0.14',
        'apkUrl': 'http://download.example.com/jive.apk',
      }),
      isNull,
    );
    expect(
      AppUpdateInfo.tryParse({
        'latestVersionName': 'not-a-version',
        'apkUrl': 'https://download.example.com/jive.apk',
      }),
      isNull,
    );
  });

  test('compares version names by numeric segments', () {
    expect(compareVersionNames('1.0.14', '1.0.13'), 1);
    expect(compareVersionNames('1.10.0', '1.9.9'), 1);
    expect(compareVersionNames('1.0', '1.0.0'), 0);
    expect(compareVersionNames('v2.0.0+8', '1.99.99+100'), 1);
  });

  test('orders pre-release versions before stable versions', () {
    expect(compareVersionNames('1.0.0-beta.2', '1.0.0-beta.1'), 1);
    expect(compareVersionNames('1.0.0', '1.0.0-rc.1'), 1);
    expect(compareVersionNames('invalid', '1.0.0'), isNull);
  });
}
