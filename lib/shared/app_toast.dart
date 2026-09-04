import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app/theme.dart';

/// 全局统一的居中提示：挂在 root Overlay 上，2 秒自动消失，同时只显示一条
/// （新 toast 替换旧 toast）。无 action 时指针事件穿透，不拦截下层手势。
/// 同步场景用这个；跨 async gap 已捕获 [OverlayState] 的场景用
/// [showAppToastVia]。
void showAppToast(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) => showAppToastVia(
  Overlay.of(context),
  message,
  actionLabel: actionLabel,
  onAction: onAction,
);

/// 已持有 [OverlayState] 的场景（如 async 回调里提前捕获的 overlay）。
void showAppToastVia(
  OverlayState overlay,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  _dismissCurrent();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _AppToast(
      message: message,
      actionLabel: actionLabel,
      onAction: onAction == null
          ? null
          : () {
              _dismissCurrent();
              onAction();
            },
      onDismissed: () {
        if (identical(_currentEntry, entry)) _currentEntry = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _currentEntry = entry;
  overlay.insert(entry);
}

OverlayEntry? _currentEntry;

void _dismissCurrent() {
  final entry = _currentEntry;
  if (entry == null) return;
  _currentEntry = null;
  if (entry.mounted) entry.remove();
}

class _AppToast extends StatefulWidget {
  const _AppToast({
    required this.message,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismissed;

  @override
  State<_AppToast> createState() => _AppToastState();
}

class _AppToastState extends State<_AppToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 200),
      reverseDuration: Duration(milliseconds: 150),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) widget.onDismissed();
    });
    unawaited(_controller.forward());
    _timer = Timer(Duration(seconds: 2), () {
      if (mounted) unawaited(_controller.reverse());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = math.min(MediaQuery.widthOf(context) * 0.7, 360.0);
    final child = FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, 0.06),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.appColors.elevated,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.appColors.divider),
              boxShadow: [
                BoxShadow(
                  color: context.appColors.scrim,
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appColors.text,
                        fontSize: 13,
                        height: 18 / 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.actionLabel != null &&
                      widget.onAction != null) ...[
                    SizedBox(width: 12),
                    GestureDetector(
                      onTap: widget.onAction,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          widget.actionLabel!,
                          style: TextStyle(
                            color: context.appColors.accentForeground,
                            fontSize: 13,
                            height: 18 / 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return IgnorePointer(
      ignoring: widget.onAction == null,
      child: Center(
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}
