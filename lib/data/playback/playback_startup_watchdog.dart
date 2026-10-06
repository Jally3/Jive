import 'dart:async';

enum PlaybackStartupTimeoutReason { noProgress, deadline }

final class PlaybackStartupTimeout extends TimeoutException {
  PlaybackStartupTimeout(this.reason, Duration duration)
    : super('Proxy initialization timed out: ${reason.name}', duration);

  final PlaybackStartupTimeoutReason reason;
}

/// Watches bytes delivered to the native player while a proxy initializes.
/// Useful bytes reset the idle deadline, but never extend the hard deadline.
/// It does not cancel the operation: its owner must dispose the failed player.
final class PlaybackStartupWatchdog {
  PlaybackStartupWatchdog({
    this.noProgressTimeout = const Duration(seconds: 8),
    this.deadline = const Duration(seconds: 20),
  });

  final Duration noProgressTimeout;
  final Duration deadline;
  Timer? _idleTimer;
  Timer? _deadlineTimer;
  Completer<void>? _result;
  int receivedBytes = 0;

  Future<void> waitFor(Future<void> initialization) {
    if (_result != null) throw StateError('Watchdog can only be used once');
    final result = _result = Completer<void>();
    _armIdleTimer();
    _deadlineTimer = Timer(deadline, () {
      _timeout(PlaybackStartupTimeoutReason.deadline, deadline);
    });
    initialization.then(
      (_) {
        if (!result.isCompleted) result.complete();
        _stopTimers();
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
        _stopTimers();
      },
    );
    return result.future;
  }

  void recordBytes(int bytes) {
    if (bytes <= 0 || _result == null || _result!.isCompleted) return;
    receivedBytes += bytes;
    _armIdleTimer();
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(noProgressTimeout, () {
      _timeout(PlaybackStartupTimeoutReason.noProgress, noProgressTimeout);
    });
  }

  void cancel() {
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.completeError(StateError('Playback initialization cancelled'));
    }
    _stopTimers();
  }

  void _timeout(PlaybackStartupTimeoutReason reason, Duration duration) {
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.completeError(PlaybackStartupTimeout(reason, duration));
    }
    _stopTimers();
  }

  void _stopTimers() {
    _idleTimer?.cancel();
    _deadlineTimer?.cancel();
  }
}
