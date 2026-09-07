import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_toast.dart';

/// 判定两次返回是否发生在同一个退出时间窗口内。
class DoubleBackExitController {
  DoubleBackExitController({
    this.interval = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration interval;
  final DateTime Function() _now;
  DateTime? _firstBackAt;

  /// 首次或超时返回 `false`；时间窗口内第二次返回 `true`。
  bool registerBackPress() {
    final current = _now();
    final firstBackAt = _firstBackAt;
    final elapsed = firstBackAt == null
        ? null
        : current.difference(firstBackAt);
    if (elapsed != null && !elapsed.isNegative && elapsed <= interval) {
      _firstBackAt = null;
      return true;
    }

    _firstBackAt = current;
    return false;
  }
}

/// Android 根页面的“双击返回退出”行为。
///
/// 此组件只应由 Android 根页面使用；子路由和弹窗会先消费返回事件。
class DoubleBackExitScope extends StatefulWidget {
  const DoubleBackExitScope({
    required this.child,
    this.message = '再按一次退出应用',
    this.onExit,
    super.key,
  });

  final Widget child;
  final String message;
  final Future<void> Function()? onExit;

  @override
  State<DoubleBackExitScope> createState() => _DoubleBackExitScopeState();
}

class _DoubleBackExitScopeState extends State<DoubleBackExitScope> {
  final _controller = DoubleBackExitController();

  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    if (_controller.registerBackPress()) {
      unawaited((widget.onExit ?? SystemNavigator.pop).call());
      return;
    }
    showAppToast(context, widget.message);
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: _onPopInvoked,
    child: widget.child,
  );
}
