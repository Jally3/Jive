import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../network/connectivity_provider.dart';

const downloadAllowCellularKey = 'download_allow_cellular';

enum DownloadNetworkAccess { allowed, cellularBlocked, unavailable }

final allowCellularDownloadsProvider =
    AsyncNotifierProvider<AllowCellularDownloadsNotifier, bool>(
      AllowCellularDownloadsNotifier.new,
    );

class AllowCellularDownloadsNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(downloadAllowCellularKey) ?? false;
  }

  Future<void> setAllowed(bool allowed) async {
    state = AsyncData(allowed);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(downloadAllowCellularKey, allowed);
  }
}

DownloadNetworkAccess downloadNetworkAccessFor(
  bool allowCellular,
  List<ConnectivityResult>? results,
) {
  if (results == null || results.isEmpty) {
    return DownloadNetworkAccess.unavailable;
  }
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return DownloadNetworkAccess.allowed;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return allowCellular
        ? DownloadNetworkAccess.allowed
        : DownloadNetworkAccess.cellularBlocked;
  }
  return DownloadNetworkAccess.unavailable;
}

final downloadNetworkAccessProvider = Provider<DownloadNetworkAccess>((ref) {
  final allowCellular =
      ref.watch(allowCellularDownloadsProvider).value ?? false;
  final connectivity = ref.watch(connectivityResultsProvider).value;
  return downloadNetworkAccessFor(allowCellular, connectivity);
});
