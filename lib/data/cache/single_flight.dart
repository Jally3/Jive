import 'dart:async';

class AsyncMutex {
  Future<void> _tail = Future.value();

  Future<T> synchronize<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.catchError((_) {}).then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}

class SingleFlight<T> {
  final Map<String, Future<T>> _inFlight = {};

  Future<T> run(String key, Future<T> Function() task) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = Future.sync(task);
    _inFlight[key] = future;
    future.whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }).ignore();
    return future;
  }

  bool get isIdle => _inFlight.isEmpty;

  void clear() => _inFlight.clear();
}
