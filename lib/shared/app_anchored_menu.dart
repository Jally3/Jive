import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Shows a reusable, rounded menu anchored to the center of [anchorContext].
///
/// The menu prefers the space below the control, slides down as it appears,
/// and is clamped to the screen safe area when perfect centering would
/// overflow an edge.
Future<T?> showAppAnchoredMenu<T>({
  required BuildContext anchorContext,
  required WidgetBuilder builder,
  double width = 280,
  double gap = 8,
}) {
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  final navigator = Navigator.of(anchorContext);
  final overlayBox =
      navigator.overlay?.context.findRenderObject() as RenderBox?;
  if (anchorBox == null || overlayBox == null) return Future<T?>.value();

  final anchorTopLeft = overlayBox.globalToLocal(
    anchorBox.localToGlobal(Offset.zero),
  );
  final anchorRect = anchorTopLeft & anchorBox.size;
  final overlaySize = overlayBox.size;
  final media = MediaQuery.of(anchorContext);
  const edgeGap = 12.0;
  final safeLeft = media.padding.left + edgeGap;
  final safeRight = overlaySize.width - media.padding.right - edgeGap;
  final menuWidth = math.min(width, safeRight - safeLeft);
  final idealLeft = anchorRect.center.dx - menuWidth / 2;
  final left = idealLeft.clamp(safeLeft, safeRight - menuWidth).toDouble();
  final below =
      overlaySize.height -
      media.padding.bottom -
      media.viewInsets.bottom -
      edgeGap -
      anchorRect.bottom -
      gap;
  final above = anchorRect.top - media.padding.top - edgeGap - gap;
  final placeBelow = below >= 180 || below >= above;
  final maxHeight = math.max(120.0, placeBelow ? below : above);

  return showGeneralDialog<T>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(
      anchorContext,
    ).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (menuContext, _, _) => Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(menuContext),
            ),
          ),
          Positioned(
            left: left,
            top: placeBelow ? anchorRect.bottom + gap : null,
            bottom: placeBelow
                ? null
                : overlaySize.height - anchorRect.top + gap,
            width: menuWidth,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Material(
                key: const ValueKey('app-anchored-menu-surface'),
                color: menuContext.appColors.elevated,
                elevation: 10,
                shadowColor: Colors.black.withValues(alpha: 0.22),
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(18),
                child: SingleChildScrollView(child: builder(menuContext)),
              ),
            ),
          ),
        ],
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          child: child,
          builder: (_, child) => Transform.translate(
            offset: Offset(0, -10 * (1 - curved.value)),
            child: child,
          ),
        ),
      );
    },
  );
}

class AppAnchoredMenuItem extends StatelessWidget {
  const AppAnchoredMenuItem({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    onTap: onTap,
  );
}
