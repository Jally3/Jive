import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final connectivityProvider = Provider<Connectivity>((ref) => Connectivity());

class _ConnectivityLifecycleObserver with WidgetsBindingObserver {
  _ConnectivityLifecycleObserver(this.onResume);

  final VoidCallback onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

/// 当前网络连接类型。首次/恢复前台读取，其他时间持续转发网络变化。
/// 最后一个消费者离开时释放监听；后台下载仍可独立持有订阅。
final connectivityResultsProvider =
    StreamProvider.autoDispose<List<ConnectivityResult>>((ref) {
      final connectivity = ref.watch(connectivityProvider);
      final output = StreamController<List<ConnectivityResult>>();
      var disposed = false;
      var revision = 0;
      StreamSubscription<List<ConnectivityResult>>? subscription;
      Future<void> refresh() async {
        final current = ++revision;
        try {
          final results = await connectivity.checkConnectivity();
          if (!disposed && revision == current) output.add(results);
          if (!disposed && subscription == null) {
            subscription = connectivity.onConnectivityChanged.listen(
              (results) {
                revision++;
                if (!disposed) output.add(results);
              },
              onError: (Object error, StackTrace stack) {
                revision++;
                if (!disposed) output.addError(error, stack);
              },
            );
          }
        } catch (error, stack) {
          if (!disposed && revision == current) output.addError(error, stack);
        }
      }

      final lifecycle = _ConnectivityLifecycleObserver(
        () => unawaited(refresh()),
      );
      WidgetsBinding.instance.addObserver(lifecycle);
      unawaited(refresh());
      ref.onDispose(() {
        disposed = true;
        WidgetsBinding.instance.removeObserver(lifecycle);
        unawaited(subscription?.cancel());
        unawaited(output.close());
      });
      return output.stream;
    });
