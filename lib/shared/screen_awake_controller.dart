import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

typedef ScreenAwakeSetter = Future<void> Function(bool enabled);

final screenAwakeControllerProvider = Provider<ScreenAwakeController>((ref) {
  final controller = ScreenAwakeController();
  ref.onDispose(() => unawaited(controller.dispose()));
  return controller;
});

final screenAwakeRouteObserverProvider =
    Provider<RouteObserver<PageRoute<dynamic>>>(
      (ref) => RouteObserver<PageRoute<dynamic>>(),
    );

/// Combines requests from visible pages so one page cannot release another's
/// screen-awake request. This controls the display only, not background work.
class ScreenAwakeController with WidgetsBindingObserver {
  ScreenAwakeController({ScreenAwakeSetter? setEnabled})
    : _setEnabled = setEnabled ?? _toggleWakelock {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  static Future<void> _toggleWakelock(bool enabled) =>
      WakelockPlus.toggle(enable: enabled);

  final ScreenAwakeSetter _setEnabled;
  final Set<Object> _owners = HashSet<Object>.identity();
  Future<void> _tail = Future<void>.value();
  Timer? _heartbeat;
  bool _foreground = true;
  bool? _lastApplied;
  bool _disposed = false;

  bool get _desired => _foreground && _owners.isNotEmpty;

  Future<void> setRequested(Object owner, bool requested) {
    if (_disposed) return Future<void>.value();
    if (requested) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    _updateHeartbeat();
    return _enqueue();
  }

  Future<void> release(Object owner) => setRequested(owner, false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateHeartbeat();
    unawaited(_enqueue());
  }

  void _updateHeartbeat() {
    if (_desired && _heartbeat == null) {
      _heartbeat = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_enqueue(force: true)),
      );
    } else if (!_desired) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  Future<void> _enqueue({bool force = false}) {
    _tail = _tail.then((_) async {
      if (_disposed) return;
      final desired = _desired;
      if (!force && _lastApplied == desired) return;
      try {
        await _setEnabled(desired);
        _lastApplied = desired;
      } catch (_) {
        // A platform wakelock error must not interrupt playback or downloads.
      }
    });
    return _tail;
  }

  Future<void> dispose() {
    if (_disposed) return _tail;
    _disposed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    _owners.clear();
    WidgetsBinding.instance.removeObserver(this);
    _tail = _tail.then((_) async {
      try {
        await _setEnabled(false);
      } catch (_) {}
    });
    return _tail;
  }
}
