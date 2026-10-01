import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../app/theme.dart';

/// 返回顶部悬浮按钮：与底栏同款毛玻璃质感，由 [showBackToTop] 控制淡入。
class HomeBackToTopButton extends StatelessWidget {
  const HomeBackToTopButton({
    super.key,
    required this.showBackToTop,
    required this.onTap,
  });

  final ValueListenable<bool> showBackToTop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: showBackToTop,
      builder: (context, show, _) => AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !show,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Material(
                color: context.appColors.surface.withValues(alpha: 0.75),
                shape: CircleBorder(
                  side: BorderSide(color: context.appColors.divider),
                ),
                child: InkWell(
                  customBorder: CircleBorder(),
                  onTap: onTap,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.arrow_upward_rounded,
                      color: context.appColors.accentForeground,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
