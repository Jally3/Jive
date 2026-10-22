import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const downloadKeepScreenAwakeKey = 'download_keep_screen_awake';

final downloadKeepScreenAwakeProvider =
    AsyncNotifierProvider<DownloadKeepScreenAwakeNotifier, bool>(
      DownloadKeepScreenAwakeNotifier.new,
    );

class DownloadKeepScreenAwakeNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(downloadKeepScreenAwakeKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    state = AsyncData(enabled);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(downloadKeepScreenAwakeKey, enabled);
  }
}
