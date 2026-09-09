import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/app_update_info.dart';

abstract interface class AppUpdateGateway {
  Future<AppUpdateInfo?> checkForUpdate();

  Future<bool> openDownload(AppUpdateInfo update);
}

class AppUpdateService implements AppUpdateGateway {
  AppUpdateService({
    http.Client? client,
    Uri? manifestUri,
    Future<String> Function()? currentVersionName,
    Future<bool> Function(Uri uri)? openExternalUrl,
  }) : _client = client,
       _manifestUri = manifestUri ?? defaultManifestUri,
       _currentVersionName = currentVersionName ?? _readCurrentVersionName,
       _openExternalUrl = openExternalUrl ?? _launchExternalUrl;

  static final Uri defaultManifestUri = Uri.parse(
    'https://hey-rickytse.com/data/version.json',
  );
  static const requestTimeout = Duration(seconds: 8);
  static const maxManifestBytes = 32 * 1024;

  final http.Client? _client;
  final Uri _manifestUri;
  final Future<String> Function() _currentVersionName;
  final Future<bool> Function(Uri uri) _openExternalUrl;

  @override
  Future<AppUpdateInfo?> checkForUpdate() async {
    if (_manifestUri.scheme != 'https' || _manifestUri.host.isEmpty) {
      return null;
    }
    final ownedClient = _client == null ? http.Client() : null;
    final client = _client ?? ownedClient!;
    try {
      final currentVersionName = await _currentVersionName();
      final response = await client.get(_manifestUri).timeout(requestTimeout);
      if (response.statusCode != 200 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > maxManifestBytes) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final update = AppUpdateInfo.tryParse(decoded);
      if (update == null ||
          !update.updatePromptEnabled ||
          compareVersionNames(update.versionName, currentVersionName) != 1) {
        return null;
      }
      return update;
    } catch (_) {
      return null;
    } finally {
      ownedClient?.close();
    }
  }

  @override
  Future<bool> openDownload(AppUpdateInfo update) async {
    if (update.apkUrl.scheme != 'https' || update.apkUrl.host.isEmpty) {
      return false;
    }
    try {
      return await _openExternalUrl(update.apkUrl);
    } catch (_) {
      return false;
    }
  }

  static Future<String> _readCurrentVersionName() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static Future<bool> _launchExternalUrl(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}

final appUpdateGatewayProvider = Provider<AppUpdateGateway>((ref) {
  return AppUpdateService();
});
