import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/network/connectivity_provider.dart';
import 'package:jive/data/device/device_status_provider.dart';
import 'package:jive/data/download/download_network_policy.dart';
import 'package:jive/data/playback/prefetch_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Connectivity implements Connectivity {
  final events = StreamController<List<ConnectivityResult>>.broadcast();
  List<ConnectivityResult> current = [ConnectivityResult.wifi];
  Completer<List<ConnectivityResult>>? pending;
  int reads = 0;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    reads++;
    return pending == null ? current : pending!.future;
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('player exit releases network unless another consumer needs it', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Connectivity();
    final container = ProviderContainer(
      overrides: [connectivityProvider.overrideWithValue(network)],
    );
    await container.read(prefetchModeProvider.future);
    final status = container.listen(deviceNetworkTypeProvider, (_, _) {});
    final prefetch = container.listen(prefetchAheadProvider, (_, _) {});
    final download = container.listen(downloadNetworkAccessProvider, (_, _) {});
    await tester.pump();
    expect(network.events.hasListener, isTrue);
    expect(container.read(prefetchAheadProvider), prefetchAheadWifi);
    status.close();
    prefetch.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.exists(deviceNetworkTypeProvider), isFalse);
    expect(container.exists(prefetchAheadProvider), isFalse);
    expect(network.events.hasListener, isTrue);
    network.events.add([ConnectivityResult.mobile]);
    await tester.pump();
    expect(
      container.read(downloadNetworkAccessProvider),
      DownloadNetworkAccess.cellularBlocked,
    );
    download.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.exists(downloadNetworkAccessProvider), isFalse);
    expect(container.exists(connectivityResultsProvider), isFalse);
    expect(network.events.hasListener, isFalse);
    final reads = network.reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(network.reads, reads);
    container.dispose();
    await network.events.close();
  });

  testWidgets('late network read cannot attach a listener after exit', (
    tester,
  ) async {
    final network = _Connectivity()
      ..pending = Completer<List<ConnectivityResult>>();
    final container = ProviderContainer(
      overrides: [connectivityProvider.overrideWithValue(network)],
    );
    final status = container.listen(deviceNetworkTypeProvider, (_, _) {});
    status.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    network.pending!.complete([ConnectivityResult.wifi]);
    await tester.pump();
    expect(container.exists(connectivityResultsProvider), isFalse);
    expect(network.events.hasListener, isFalse);
    container.dispose();
    await network.events.close();
  });

  testWidgets('network snapshot refreshes after returning from background', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Connectivity();
    final container = ProviderContainer(
      overrides: [connectivityProvider.overrideWithValue(network)],
    );
    container.listen(connectivityResultsProvider, (_, _) {});
    await tester.pump();
    expect(container.read(connectivityResultsProvider).value, network.current);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    network.current = [ConnectivityResult.mobile];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(network.reads, 2);
    expect(container.read(connectivityResultsProvider).value, network.current);
    container.dispose();
    expect(network.events.hasListener, isFalse);
    await network.events.close();
  });

  testWidgets('late resume snapshot cannot overwrite a newer network event', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Connectivity();
    final container = ProviderContainer(
      overrides: [connectivityProvider.overrideWithValue(network)],
    );
    container.listen(connectivityResultsProvider, (_, _) {});
    await tester.pump();
    network.pending = Completer<List<ConnectivityResult>>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    network.events.add([ConnectivityResult.wifi]);
    await tester.pump();
    network.pending!.complete([ConnectivityResult.mobile]);
    await tester.pump();
    expect(container.read(connectivityResultsProvider).value, [
      ConnectivityResult.wifi,
    ]);
    container.dispose();
    await network.events.close();
  });
}
