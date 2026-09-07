import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/update/app_update_service.dart';
import 'package:jive/domain/app_update_info.dart';

void main() {
  final manifestUri = Uri.parse('https://example.com/version.json');

  test('returns an update when remote version name is newer', () async {
    final service = AppUpdateService(
      manifestUri: manifestUri,
      currentVersionName: () async => '1.0.13',
      client: MockClient(
        (_) async => http.Response('''{
            "latestVersionCode": 1,
            "latestVersionName": "1.0.14",
            "apkUrl": "https://example.com/jive.apk",
            "releaseNotes": ["Fix playback"]
          }''', 200),
      ),
    );

    final update = await service.checkForUpdate();

    expect(update?.versionName, '1.0.14');
    expect(update?.releaseNotes, ['Fix playback']);
  });

  test('returns null when current version is up to date', () async {
    final service = AppUpdateService(
      manifestUri: manifestUri,
      currentVersionName: () async => '1.0.14',
      client: MockClient(
        (_) async => http.Response('''{
            "latestVersionName": "1.0.14",
            "apkUrl": "https://example.com/jive.apk"
          }''', 200),
      ),
    );

    expect(await service.checkForUpdate(), isNull);
  });

  test('uses version name and ignores APK build number fields', () async {
    final service = AppUpdateService(
      manifestUri: manifestUri,
      currentVersionName: () async => '2.0.0',
      client: MockClient(
        (_) async => http.Response('''{
            "latestVersionCode": 999999,
            "latestVersionName": "1.9.9",
            "apkUrl": "https://example.com/jive.apk"
          }''', 200),
      ),
    );

    expect(await service.checkForUpdate(), isNull);
  });

  test('network and invalid response failures degrade to no update', () async {
    final failingService = AppUpdateService(
      manifestUri: manifestUri,
      currentVersionName: () async => '1.0.13',
      client: MockClient((_) async => throw Exception('offline')),
    );
    final invalidService = AppUpdateService(
      manifestUri: manifestUri,
      currentVersionName: () async => '1.0.13',
      client: MockClient((_) async => http.Response('not json', 200)),
    );

    expect(await failingService.checkForUpdate(), isNull);
    expect(await invalidService.checkForUpdate(), isNull);
  });

  test('opens a valid APK URL with the injected external launcher', () async {
    Uri? openedUri;
    final service = AppUpdateService(
      openExternalUrl: (uri) async {
        openedUri = uri;
        return true;
      },
    );
    final update = AppUpdateInfo(
      versionName: '1.0.14',
      apkUrl: Uri.parse('https://example.com/jive.apk'),
    );

    expect(await service.openDownload(update), isTrue);
    expect(openedUri, update.apkUrl);
  });
}
