import 'dart:async';
import 'dart:math';

/// 下载分片并发许可池：限制同时进行的网络分片数。
class DownloadPermitPool {
  DownloadPermitPool(int capacity) : _available = max(1, capacity);

  int _available;
  final List<Completer<void>> _waiters = [];

  Future<void Function()?> acquire({Future<void>? cancelled}) async {
    if (_available > 0) {
      _available--;
    } else {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      if (cancelled == null) {
        await waiter.future;
      } else {
        final acquired = await Future.any<bool>([
          waiter.future.then((_) => true),
          cancelled.then((_) => false),
        ]);
        if (!acquired) {
          if (!_waiters.remove(waiter)) {
            // The permit was granted concurrently with cancellation.
            if (_waiters.isNotEmpty) {
              _waiters.removeAt(0).complete();
            } else {
              _available++;
            }
          }
          return null;
        }
      }
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _available++;
      }
    };
  }
}
