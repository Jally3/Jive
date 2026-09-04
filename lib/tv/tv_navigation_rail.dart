import 'package:flutter/material.dart';

import '../app/theme.dart';
import 'tv_theme.dart';

class TvNavigationRail extends StatelessWidget {
  const TvNavigationRail({
    super.key,
    required this.index,
    required this.focusNodes,
    required this.onSelect,
  });

  final int index;
  final List<FocusNode> focusNodes;
  final ValueChanged<int> onSelect;

  static const _items = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.search, Icons.search, '搜索'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Container(
        key: const ValueKey('tv-navigation-rail'),
        width: TvLayout.navigationWidth,
        margin: const EdgeInsets.only(right: 24),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 18),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 24),
              child: Text(
                'Jive',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
            ),
            for (var value = 0; value < _items.length; value++) ...[
              _TvNavigationItem(
                icon: _items[value].$1,
                selectedIcon: _items[value].$2,
                label: _items[value].$3,
                selected: index == value,
                focusNode: focusNodes[value],
                onTap: () => onSelect(value),
              ),
              if (value != _items.length - 1) const SizedBox(height: 12),
            ],
            const Spacer(),
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '方向键移动 · OK 确认',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: AppColors.tertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvNavigationItem extends StatefulWidget {
  const _TvNavigationItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  State<_TvNavigationItem> createState() => _TvNavigationItemState();
}

class _TvNavigationItemState extends State<_TvNavigationItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final foreground = widget.selected || _focused
        ? AppColors.text
        : AppColors.secondary;
    return AnimatedScale(
      scale: _focused ? TvLayout.focusScale : 1,
      duration: const Duration(milliseconds: 120),
      child: SizedBox(
        height: TvLayout.navigationItemHeight,
        child: Material(
          color: widget.selected
              ? AppColors.accent.withValues(alpha: 0.22)
              : AppColors.elevated.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey('tv-nav-${widget.label}'),
            focusNode: widget.focusNode,
            onFocusChange: (value) => setState(() => _focused = value),
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: _focused
                    ? Border.all(
                        color: AppColors.accent,
                        width: TvLayout.focusBorderWidth,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Icon(
                    widget.selected ? widget.selectedIcon : widget.icon,
                    color: foreground,
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 17,
                        fontWeight: widget.selected || _focused
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
