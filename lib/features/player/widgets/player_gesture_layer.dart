import 'package:flutter/material.dart';

/// 播放画面上的手势层：单击切换控制条、双击播放/暂停、
/// 横向滑动快进快退、长按右侧 2 倍速、纵向滑动调亮度/音量。
/// 具体手势逻辑由宿主页面通过回调实现；涉及区域尺寸的回调
/// 会把手势区域的宽/高一并传出。
class PlayerGestureLayer extends StatelessWidget {
  const PlayerGestureLayer({
    super.key,
    required this.onTap,
    required this.onDoubleTap,
    required this.onHorizontalDragStart,
    required this.onHorizontalDragUpdate,
    required this.onHorizontalDragEnd,
    required this.onHorizontalDragCancel,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
    required this.onVerticalDragStart,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
  });

  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(DragStartDetails details) onHorizontalDragStart;
  final void Function(DragUpdateDetails details, double width)
  onHorizontalDragUpdate;
  final VoidCallback onHorizontalDragEnd;
  final VoidCallback onHorizontalDragCancel;
  final void Function(LongPressStartDetails details, double width)
  onLongPressStart;
  final VoidCallback onLongPressEnd;
  final VoidCallback onLongPressCancel;
  final void Function(DragStartDetails details, double width)
  onVerticalDragStart;
  final void Function(DragUpdateDetails details, double height)
  onVerticalDragUpdate;
  final VoidCallback onVerticalDragEnd;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 24,
      top: 0,
      right: 0,
      bottom: 0,
      child: LayoutBuilder(
        builder: (_, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          onHorizontalDragStart: onHorizontalDragStart,
          onHorizontalDragUpdate: (details) =>
              onHorizontalDragUpdate(details, constraints.maxWidth),
          onHorizontalDragEnd: (_) => onHorizontalDragEnd(),
          onHorizontalDragCancel: onHorizontalDragCancel,
          onLongPressStart: (details) =>
              onLongPressStart(details, constraints.maxWidth),
          onLongPressEnd: (_) => onLongPressEnd(),
          onLongPressCancel: onLongPressCancel,
          onVerticalDragStart: (details) =>
              onVerticalDragStart(details, constraints.maxWidth),
          onVerticalDragUpdate: (details) =>
              onVerticalDragUpdate(details, constraints.maxHeight),
          onVerticalDragEnd: (_) => onVerticalDragEnd(),
          onVerticalDragCancel: onVerticalDragEnd,
          child: const ColoredBox(color: Colors.transparent),
        ),
      ),
    );
  }
}
