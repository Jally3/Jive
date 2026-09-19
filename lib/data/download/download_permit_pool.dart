import 'dart:async';
import 'dart:math';

/// 下载分片并发许可池：限制同时进行的网络分片数。
class DownloadPermitPool {
  DownloadPermitPool(int capacity) : _available = max(1, capacity);

  int _available;
  final List<Completer<void>> _waiters = [];

  Future<void Function()> acquire() async {
    if (_available > 0) {
      _available--;
    } else {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
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
