import 'package:flutter/material.dart';

import '../app/theme.dart';
import 'tv_navigation_rail.dart';
import 'tv_theme.dart';

class TvAppShell extends StatelessWidget {
  const TvAppShell({
    super.key,
    required this.index,
    required this.focusNodes,
    required this.contentFocusScopeNode,
    required this.onSelect,
    required this.body,
  });

  final int index;
  final List<FocusNode> focusNodes;
  final FocusScopeNode contentFocusScopeNode;
  final ValueChanged<int> onSelect;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        minimum: const EdgeInsets.all(TvLayout.safePadding),
        child: Row(
          children: [
            TvNavigationRail(
              index: index,
              focusNodes: focusNodes,
              onSelect: onSelect,
            ),
            Expanded(
              child: FocusScope(
                node: contentFocusScopeNode,
                child: FocusTraversalGroup(child: body),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
