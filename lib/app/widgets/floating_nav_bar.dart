import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'nav_reflection.dart';

class FloatingNavBar extends StatefulWidget {
  const FloatingNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.showUpdateDot,
    required this.scrollDistance,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool showUpdateDot;
  final ValueListenable<double> scrollDistance;

  @override
  State<FloatingNavBar> createState() => _FloatingNavBarState();
}

class _FloatingNavBarState extends State<FloatingNavBar>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _items = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.search, Icons.search, '搜索'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  late final NavReflectionController _reflection;
  late final AnimationController _breath;
  late double _lastDistance;
  bool _motionEnabled = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _reflection = NavReflectionController(vsync: this);
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _lastDistance = widget.scrollDistance.value;
    widget.scrollDistance.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(FloatingNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollDistance != widget.scrollDistance) {
      oldWidget.scrollDistance.removeListener(_handleScroll);
      _lastDistance = widget.scrollDistance.value;
      widget.scrollDistance.addListener(_handleScroll);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _reflection.changePalette(
        animate: !MediaQuery.disableAnimationsOf(context),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    _motionEnabled =
        !reducedMotion &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _syncBreathing();
    if (reducedMotion) {
      _reflection.finishTransition();
      _breath.value = 0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncBreathing();
  }

  void _syncBreathing() {
    if (_motionEnabled && _foreground) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath.stop();
    }
  }

  void _handleScroll() {
    final distance = widget.scrollDistance.value;
    final delta = distance - _lastDistance;
    _lastDistance = distance;
    if (widget.selectedIndex == 0 && !MediaQuery.disableAnimationsOf(context)) {
      _reflection.advanceScroll(delta);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.scrollDistance.removeListener(_handleScroll);
    _reflection.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final height = isTablet ? 72.0 : 60.0;
    final radius = height / 2;
    final surfaceAlpha = widget.selectedIndex == 0
        ? context.appColors.navigationHomeAlpha
        : context.appColors.navigationPageAlpha;
    return Container(
      key: const ValueKey('floating-nav-bar'),
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: context.appColors.scrim,
            blurRadius: isTablet ? 24 : 16,
            offset: Offset(0, isTablet ? 6 : 4),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -NavBacklightPainter.padding,
            right: -NavBacklightPainter.padding,
            top: -NavBacklightPainter.padding,
            bottom: -NavBacklightPainter.padding,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('nav-backlight'),
                  painter: NavBacklightPainter(
                    controller: _reflection,
                    breath: _breath,
                    isDark: isDark,
                    isTablet: isTablet,
                  ),
                ),
              ),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: isTablet ? 20 : 16,
                sigmaY: isTablet ? 20 : 16,
              ),
              child: Material(
                key: const ValueKey('floating-nav-surface'),
                color: context.appColors.surface.withValues(
                  alpha: surfaceAlpha,
                ),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('nav-reflection'),
                            painter: NavReflectionPainter(
                              controller: _reflection,
                              isDark: isDark,
                              isTablet: isTablet,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < _items.length; i++)
                          Expanded(
                            child: _NavItem(
                              icon: _items[i].$1,
                              selectedIcon: _items[i].$2,
                              label: _items[i].$3,
                              selected: widget.selectedIndex == i,
                              isTablet: isTablet,
                              showUpdateDot: i == 2 && widget.showUpdateDot,
                              onTap: () => widget.onSelect(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.isTablet,
    required this.showUpdateDot,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool isTablet;
  final bool showUpdateDot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = context.appColors;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      button: true,
      selected: selected,
      label: showUpdateDot ? '$label，有追更更新' : label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: AnimatedContainer(
          key: ValueKey('bottom-nav-item-$label'),
          duration: duration,
          curve: Curves.easeOutCubic,
          margin: isTablet
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
              : const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? colors.text.withValues(alpha: isDark ? 0.08 : 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: selected ? colors.text : colors.secondary),
            duration: duration,
            curve: Curves.easeOutCubic,
            builder: (context, color, _) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      selected ? selectedIcon : icon,
                      color: color,
                      size: isTablet ? 26 : 24,
                    ),
                    if (showUpdateDot)
                      Positioned(
                        right: -5,
                        top: -3,
                        child: Container(
                          key: const ValueKey('bottom-nav-update-dot'),
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: isTablet ? 13 : 12,
                    color: color,
                    fontWeight: selected
                        ? FontWeight.w600
                        : isTablet
                        ? FontWeight.w500
                        : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
