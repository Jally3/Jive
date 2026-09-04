import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// TV 横向控件的确定性焦点移动。移动后自动把目标滚入可视区域；到达
/// 左右边界时返回 ignored，交给页面级焦点路由进入相邻区域。
class TvHorizontalFocus extends StatefulWidget {
  const TvHorizontalFocus({
    super.key,
    required this.index,
    required this.nodes,
    required this.focusNode,
    required this.scrollController,
    required this.onActivate,
    required this.child,
    this.upTarget,
    this.downTarget,
  });

  final int index;
  final List<FocusNode> nodes;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final VoidCallback onActivate;
  final FocusNode? upTarget;
  final FocusNode? downTarget;
  final Widget child;

  @override
  State<TvHorizontalFocus> createState() => _TvHorizontalFocusState();
}

class _TvHorizontalFocusState extends State<TvHorizontalFocus> {
  final _revealKey = GlobalKey();

  void _focusIndex(int targetIndex) {
    widget.nodes[targetIndex].requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) return;
      final position = widget.scrollController.position;
      final denominator = widget.nodes.length - 1;
      final fraction = denominator <= 0 ? 0.0 : targetIndex / denominator;
      widget.scrollController.animateTo(
        position.maxScrollExtent * fraction,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.scrollController.hasClients) {
        final position = widget.scrollController.position;
        final denominator = widget.nodes.length - 1;
        final fraction = denominator <= 0 ? 0.0 : widget.index / denominator;
        final target = position.maxScrollExtent * fraction;
        widget.scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      final targetContext = _revealKey.currentContext;
      if (targetContext == null || !targetContext.mounted) return;
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft && widget.index > 0) {
      _focusIndex(widget.index - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight &&
        widget.index + 1 < widget.nodes.length) {
      _focusIndex(widget.index + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && widget.upTarget != null) {
      widget.upTarget!.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && widget.downTarget != null) {
      widget.downTarget!.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      widget.onActivate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.focusNode,
    builder: (context, _) => Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _handleKey,
      onFocusChange: (focused) {
        if (focused) _reveal();
      },
      child: AnimatedContainer(
        key: _revealKey,
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: widget.focusNode.hasFocus
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                )
              : null,
        ),
        child: ExcludeFocus(child: widget.child),
      ),
    ),
  );
}
