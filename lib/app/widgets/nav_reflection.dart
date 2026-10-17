import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

typedef NavReflectionColors = ({Color left, Color middle, Color right});

ui.Gradient _navGradient(
  Offset center,
  NavReflectionColors colors,
  double alpha,
) => ui.Gradient.sweep(
  center,
  [
    colors.left.withValues(alpha: alpha),
    colors.middle.withValues(alpha: alpha),
    colors.right.withValues(alpha: alpha),
    colors.left.withValues(alpha: alpha),
  ],
  [0, 1 / 3, 2 / 3, 1],
  TileMode.clamp,
  -pi / 2,
  pi * 3 / 2,
);

/// 导航局部视觉状态：时间驱动切 Tab，距离驱动首页滚动。
class NavReflectionController extends ChangeNotifier {
  NavReflectionController({required TickerProvider vsync, Random? random})
    : _random = random ?? Random(),
      _animation = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 400),
      ) {
    _paletteIndex = _random.nextInt(_palettes.length);
    _colors = _from = _to = _palettes[_paletteIndex];
    _animation.addListener(_tick);
  }

  static const _palettes = <NavReflectionColors>[
    (
      left: Color(0xFF4DB6AC),
      middle: Color(0xFF64A8E8),
      right: Color(0xFFAB83DA),
    ),
    (
      left: Color(0xFFE4B365),
      middle: Color(0xFFE08E83),
      right: Color(0xFFAB83DA),
    ),
    (
      left: Color(0xFF64A8E8),
      middle: Color(0xFFAB83DA),
      right: Color(0xFFE4B365),
    ),
    (
      left: Color(0xFF4DB6AC),
      middle: Color(0xFF69BFCC),
      right: Color(0xFF64A8E8),
    ),
    (
      left: Color(0xFFAB83DA),
      middle: Color(0xFFD18CAC),
      right: Color(0xFFE4B365),
    ),
  ];
  static const _segmentLength = 240.0;

  final Random _random;
  final AnimationController _animation;
  late int _paletteIndex;
  late NavReflectionColors _colors;
  late NavReflectionColors _from;
  late NavReflectionColors _to;
  double _distance = 0;
  bool _scrollDriven = false;

  NavReflectionColors get colors => _colors;

  NavReflectionColors _nextPalette({bool excludeVisible = false}) {
    // 切 Tab / 接管滚动时额外排除可见色；段间仅排除前一目标，
    // 保证相同距离拆成不同数量的滚动事件仍产生相同配色。
    final candidates = [
      for (var i = 0; i < _palettes.length; i++)
        if (i != _paletteIndex && (!excludeVisible || _palettes[i] != _colors))
          i,
    ];
    _paletteIndex = candidates[_random.nextInt(candidates.length)];
    return _palettes[_paletteIndex];
  }

  static NavReflectionColors _lerp(
    NavReflectionColors from,
    NavReflectionColors to,
    double t,
  ) => (
    left: Color.lerp(from.left, to.left, t)!,
    middle: Color.lerp(from.middle, to.middle, t)!,
    right: Color.lerp(from.right, to.right, t)!,
  );

  void _tick() {
    _colors = _lerp(
      _from,
      _to,
      Curves.easeInOutCubic.transform(_animation.value),
    );
    notifyListeners();
  }

  void changePalette({bool animate = true}) {
    _animation.stop();
    _scrollDriven = false;
    _from = _colors;
    _to = _nextPalette(excludeVisible: true);
    if (animate) {
      _animation.forward(from: 0);
    } else {
      _colors = _to;
      notifyListeners();
    }
  }

  /// 累加实际移动的绝对距离；停止滚动后无需补间或定时器。
  void advanceScroll(double distance) {
    if (!distance.isFinite || distance <= 0) return;
    _animation.stop();
    if (!_scrollDriven) {
      _scrollDriven = true;
      _from = _colors;
      _to = _nextPalette(excludeVisible: true);
      _distance = 0;
    }
    _distance += distance;
    while (_distance >= _segmentLength) {
      _distance -= _segmentLength;
      _from = _to;
      _to = _nextPalette();
    }
    _colors = _lerp(_from, _to, _distance / _segmentLength);
    notifyListeners();
  }

  void finishTransition() {
    if (!_animation.isAnimating) return;
    _animation.stop();
    _colors = _to;
    notifyListeners();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}

/// 以渐变绘制扁平柔光，不增加额外模糊滤镜。
class NavReflectionPainter extends CustomPainter {
  NavReflectionPainter({
    required this.controller,
    required this.isDark,
    required this.isTablet,
  }) : super(repaint: controller);

  final NavReflectionController controller;
  final bool isDark;
  final bool isTablet;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = size.height / 2;
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final colors = controller.colors;
    final strength = isDark ? 0.36 : 0.18;
    final glowHeight = isTablet ? 17.0 : 14.0;
    canvas.save();
    canvas.clipRRect(shape);
    final spots = [
      (0.18, colors.left),
      (0.50, colors.middle),
      (0.82, colors.right),
    ];
    for (final (position, color) in spots) {
      canvas.save();
      canvas.translate(size.width * position, -1);
      canvas.scale(size.width * 0.43, glowHeight);
      canvas.drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            1,
            [
              color.withValues(alpha: strength),
              color.withValues(alpha: strength * 0.38),
              color.withValues(alpha: 0),
            ],
            [0, 0.4, 1],
          ),
      );
      canvas.restore();
    }

    // 首尾同色，闭合边框在渐变接缝处也保持连续。
    final edgeAlpha = isDark ? 0.50 : 0.32;
    canvas.drawRRect(
      shape.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = _navGradient(size.center(Offset.zero), colors, edgeAlpha),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(NavReflectionPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.isDark != isDark ||
      oldDelegate.isTablet != isTablet;
}

/// 绘制在胶囊裁剪之外的弥散背光；仅此局部图层跟随呼吸重绘。
class NavBacklightPainter extends CustomPainter {
  NavBacklightPainter({
    required this.controller,
    required this.breath,
    required this.isDark,
    required this.isTablet,
  }) : super(repaint: Listenable.merge([controller, breath]));

  static const padding = 40.0;

  final NavReflectionController controller;
  final Animation<double> breath;
  final bool isDark;
  final bool isTablet;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(padding);
    if (rect.isEmpty) return;
    final phase = Curves.easeInOut.transform(breath.value.clamp(0.0, 1.0));
    final spread = ui.lerpDouble(1, isTablet ? 5 : 4, phase)!;
    final sigma = ui.lerpDouble(6, isTablet ? 12 : 10, phase)!;
    final alpha = isDark
        ? ui.lerpDouble(0.22, 0.48, phase)!
        : ui.lerpDouble(0.10, 0.24, phase)!;
    final haloRect = rect.inflate(spread);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(haloRect, Radius.circular(haloRect.height / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ui.lerpDouble(3, 6, phase)!
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma)
        ..shader = _navGradient(
          size.center(Offset.zero),
          controller.colors,
          alpha,
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(NavBacklightPainter oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.breath != breath ||
      oldDelegate.isDark != isDark ||
      oldDelegate.isTablet != isTablet;
}
