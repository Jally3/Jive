import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

import '../../app/theme.dart';
import '../../domain/video.dart';

/// 分类 chip 的通用样式：主分类行与子分类行（copyWith 调整）共用。
ChipThemeData categoryChipTheme(BuildContext context) => ChipThemeData(
  backgroundColor: context.appColors.elevated.withValues(alpha: 0.6),
  selectedColor: context.appColors.accent,
  disabledColor: context.appColors.surface,
  side: BorderSide(color: context.appColors.divider),
  shape: StadiumBorder(),
  labelStyle: TextStyle(color: context.appColors.text, fontSize: 14),
  secondaryLabelStyle: TextStyle(
    color: context.appColors.onAccent,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  ),
  checkmarkColor: context.appColors.onAccent,
  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  // 选中态是 accent 实心底，focusColor 洗上去不可见，聚焦时加深区分。
  // 触摸点击不会持有焦点（仅方向键/键盘），手机端无变化。
  color: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.selected)) {
      return states.contains(WidgetState.focused)
          ? context.appColors.accentPressed
          : context.appColors.accent;
    }
    return context.appColors.elevated.withValues(alpha: 0.6);
  }),
);

/// 「全部频道」网格布局：手机保持 4 列、比例 2.4；平板按宽度加列并限制胶囊高度，
/// 避免 iPad 上 4 列被拉成又宽又高的按钮。内容宽度封顶，横屏两侧留白。
@visibleForTesting
class CategoryChannelsLayout {
  const CategoryChannelsLayout({
    required this.columns,
    required this.padding,
    required this.spacing,
    required this.childAspectRatio,
    required this.contentWidth,
    required this.isTablet,
  });

  static const double tabletBreakpoint = 600;
  static const double tabletMaxContentWidth = 1100;
  static const double tabletPillHeight = 48;
  static const double phoneAspectRatio = 2.4;
  static const double minCellWidth = 110;

  final int columns;
  final double padding;
  final double spacing;
  final double childAspectRatio;
  final double contentWidth;
  final bool isTablet;

  double get titleSize => isTablet ? 22 : 17;
  double get sectionSize => isTablet ? 16 : 14;
  double get pillSize => isTablet ? 15 : 13;
  double get actionSize => isTablet ? 15 : 13;
  double get sectionGap => isTablet ? 24 : 20;

  factory CategoryChannelsLayout.resolve({
    required double viewportWidth,
    required double shortestSide,
  }) {
    final isTablet = shortestSide >= tabletBreakpoint;
    final contentWidth = isTablet
        ? math.min(viewportWidth, tabletMaxContentWidth)
        : viewportWidth;
    final padding = isTablet ? 24.0 : 16.0;
    final spacing = isTablet ? 12.0 : 8.0;
    final columns = columnCount(
      contentWidth,
      padding: padding,
      spacing: spacing,
    );
    final available = math.max(0.0, contentWidth - padding * 2);
    final cellWidth = columns == 0
        ? available
        : (available - spacing * (columns - 1)) / columns;
    final naturalHeight = cellWidth / phoneAspectRatio;
    final cellHeight = math.min(naturalHeight, tabletPillHeight);
    return CategoryChannelsLayout(
      columns: columns,
      padding: padding,
      spacing: spacing,
      childAspectRatio: cellWidth <= 0
          ? phoneAspectRatio
          : cellWidth / cellHeight,
      contentWidth: contentWidth,
      isTablet: isTablet,
    );
  }

  /// 目标单元格约 110pt：手机竖屏仍是 4 列，iPad 随宽度 5–8 列。
  @visibleForTesting
  static int columnCount(
    double width, {
    required double padding,
    required double spacing,
  }) {
    final available = width - padding * 2;
    final count = ((available + spacing) / (minCellWidth + spacing)).floor();
    return count.clamp(4, 8);
  }
}

/// 「全部频道」全屏页面：我的频道自适应网格 + 全部分类分组。
/// 编辑模式支持增删与长按拖拽排序；增删排序与持久化由首页回调处理，
/// 页面本地维护 _myIds 副本保证即时刷新。
class CategoryChannelsPage extends StatefulWidget {
  const CategoryChannelsPage({
    super.key,
    required this.roots,
    required this.children,
    required this.myChannelIds,
    required this.selectedRootId,
    required this.selectedCategoryId,
    required this.onSelectRoot,
    required this.onSelectLeaf,
    required this.onAddRoot,
    required this.onRemoveRoot,
    required this.onReorder,
    required this.onReset,
  });

  final List<VideoCategory> roots;
  final Map<int, List<VideoCategory>> children;

  /// 我的频道 id 及顺序；null 表示未定制（全部根分类）。
  final List<int>? myChannelIds;
  final int? selectedRootId;
  final int? selectedCategoryId;

  /// 选中无子分类的主分类；id 为 null 表示「最新」。
  final ValueChanged<int?> onSelectRoot;

  /// 选中子分类，附带其所属主分类 id。
  final void Function(int rootId, int leafId) onSelectLeaf;

  /// 编辑模式：把根分类加入/移出我的频道，以及恢复默认。
  final ValueChanged<int> onAddRoot;
  final ValueChanged<int> onRemoveRoot;

  /// 编辑模式拖拽后我的频道的完整有序 id 列表。
  final ValueChanged<List<int>> onReorder;
  final VoidCallback onReset;

  @override
  State<CategoryChannelsPage> createState() => _CategoryChannelsPageState();
}

class _CategoryChannelsPageState extends State<CategoryChannelsPage> {
  late List<int> _myIds;
  bool _editing = false;
  late CategoryChannelsLayout _layout;

  @override
  void initState() {
    super.initState();
    // 清洗掉已失效的 id；全部失效（或未定制）时回退为全部根分类。
    final valid = {for (final root in widget.roots) root.id};
    _myIds = (widget.myChannelIds ?? [for (final root in widget.roots) root.id])
        .where(valid.contains)
        .toList();
    if (_myIds.isEmpty) {
      _myIds = [for (final root in widget.roots) root.id];
    }
  }

  List<VideoCategory> get _myRoots {
    final byId = {for (final root in widget.roots) root.id: root};
    return [for (final id in _myIds) byId[id]!];
  }

  void _selectRoot(int? id) {
    widget.onSelectRoot(id);
    Navigator.of(context).pop();
  }

  void _selectLeaf(int rootId, int leafId) {
    widget.onSelectLeaf(rootId, leafId);
    Navigator.of(context).pop();
  }

  void _add(int rootId) {
    if (_myIds.contains(rootId)) return;
    setState(() => _myIds = [..._myIds, rootId]);
    widget.onAddRoot(rootId);
  }

  void _remove(int rootId) {
    setState(() => _myIds = _myIds.where((id) => id != rootId).toList());
    widget.onRemoveRoot(rootId);
  }

  void _reset() {
    setState(() => _myIds = [for (final root in widget.roots) root.id]);
    widget.onReset();
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final id = _myIds.removeAt(oldIndex);
      _myIds.insert(newIndex, id);
    });
    widget.onReorder(List.of(_myIds));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: ValueKey('category-channels-page'),
    backgroundColor: context.appColors.background,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _layout = CategoryChannelsLayout.resolve(
            viewportWidth: constraints.maxWidth,
            shortestSide: MediaQuery.sizeOf(context).shortestSide,
          );
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: _layout.contentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      _layout.padding,
                      _layout.isTablet ? 12 : 8,
                      8,
                      0,
                    ),
                    child: _titleBar(),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        _layout.padding,
                        _layout.isTablet ? 12 : 8,
                        _layout.padding,
                        _layout.isTablet ? 32 : 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _myChannelsSection(),
                          for (final root in widget.roots) ...[
                            SizedBox(height: _layout.sectionGap),
                            _rootSection(root),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _titleBar() => Row(
    children: [
      Text(
        '全部频道',
        style: TextStyle(
          color: context.appColors.text,
          fontSize: _layout.titleSize,
          fontWeight: FontWeight.w700,
        ),
      ),
      Spacer(),
      IconButton(
        key: ValueKey('category-channels-close'),
        tooltip: '关闭',
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.close_rounded,
          color: context.appColors.secondary,
          size: _layout.isTablet ? 26 : 24,
        ),
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );

  Widget _sectionHeader(String title, {List<Widget> actions = const []}) => Row(
    children: [
      Text(
        title,
        style: TextStyle(
          color: context.appColors.text,
          fontSize: _layout.sectionSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      Spacer(),
      ...actions,
    ],
  );

  Widget _headerAction(String label, {VoidCallback? onTap, Color? color}) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            top: _layout.isTablet ? 8 : 4,
            bottom: _layout.isTablet ? 8 : 4,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color ?? context.appColors.secondary,
              fontSize: _layout.actionSize,
            ),
          ),
        ),
      );

  Widget _myChannelsSection() {
    final myRoots = _myRoots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          '我的频道',
          actions: _editing
              ? [
                  _headerAction(
                    '完成',
                    color: context.appColors.accentForeground,
                    onTap: () => setState(() => _editing = false),
                  ),
                ]
              : [
                  _headerAction('恢复默认', onTap: _reset),
                  _headerAction(
                    '编辑',
                    onTap: () => setState(() => _editing = true),
                  ),
                ],
        ),
        SizedBox(height: _layout.isTablet ? 12 : 8),
        if (_editing)
          // 「最新」放在 header 占首格：不参与拖拽也不可移除。
          ReorderableGridView.count(
            crossAxisCount: _layout.columns,
            shrinkWrap: true,
            physics: NeverScrollableScrollPhysics(),
            mainAxisSpacing: _layout.spacing,
            crossAxisSpacing: _layout.spacing,
            childAspectRatio: _layout.childAspectRatio,
            onReorder: _reorder,
            header: [
              _pill(
                label: '最新',
                selected: widget.selectedRootId == null,
                dimmed: true,
              ),
            ],
            children: [
              for (final root in myRoots)
                _pill(
                  key: ValueKey('my-channel-${root.id}'),
                  label: root.name,
                  selected: widget.selectedRootId == root.id,
                  onTap: () => _remove(root.id),
                  removable: true,
                ),
            ],
          )
        else
          _grid([
            _pill(
              label: '最新',
              selected: widget.selectedRootId == null,
              onTap: () => _selectRoot(null),
            ),
            for (final root in myRoots)
              _pill(
                label: root.name,
                selected: widget.selectedRootId == root.id,
                onTap: () => _selectRoot(root.id),
              ),
          ]),
      ],
    );
  }

  /// 有子分类：根分类名作小标题，子分类排自适应网格；
  /// 无子分类：根分类自身占一格。编辑态区头带「+ 添加 / 已添加」。
  Widget _rootSection(VideoCategory root) {
    final kids = widget.children[root.id] ?? <VideoCategory>[];
    final inMine = _myIds.contains(root.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          root.name,
          actions: !_editing
              ? []
              : [
                  if (inMine)
                    _headerAction('已添加', color: context.appColors.tertiary)
                  else
                    _headerAction(
                      '+ 添加',
                      color: context.appColors.accentForeground,
                      onTap: () => _add(root.id),
                    ),
                ],
        ),
        SizedBox(height: _layout.isTablet ? 12 : 8),
        IgnorePointer(
          ignoring: _editing,
          child: Opacity(
            opacity: _editing ? 0.5 : 1,
            child: kids.isEmpty
                ? _grid([
                    _pill(
                      label: root.name,
                      selected: widget.selectedRootId == root.id,
                      onTap: () => _selectRoot(root.id),
                    ),
                  ])
                : _grid([
                    for (final kid in kids)
                      _pill(
                        label: kid.name,
                        selected: widget.selectedCategoryId == kid.id,
                        onTap: () => _selectLeaf(root.id, kid.id),
                      ),
                  ]),
          ),
        ),
      ],
    );
  }

  Widget _grid(List<Widget> items) => GridView.count(
    crossAxisCount: _layout.columns,
    shrinkWrap: true,
    physics: NeverScrollableScrollPhysics(),
    mainAxisSpacing: _layout.spacing,
    crossAxisSpacing: _layout.spacing,
    childAspectRatio: _layout.childAspectRatio,
    children: items,
  );

  Widget _pill({
    Key? key,
    required String label,
    required bool selected,
    VoidCallback? onTap,
    bool dimmed = false,
    bool removable = false,
  }) {
    final pill = GestureDetector(
      key: removable ? null : key,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: selected
              ? context.appColors.accent
              : context.appColors.elevated.withValues(
                  alpha: dimmed ? 0.35 : 0.6,
                ),
          shape: StadiumBorder(
            side: selected
                ? BorderSide.none
                : BorderSide(color: context.appColors.divider),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected
                ? context.appColors.onAccent
                : (dimmed
                      ? context.appColors.tertiary
                      : context.appColors.text),
            fontSize: _layout.pillSize,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
    if (!removable) return pill;
    // ReorderableGridView 要求 key 挂在直接 child（外层 Stack）上。
    return Stack(
      key: key,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: pill),
        Positioned(top: -5, right: -3, child: _RemoveBadge()),
      ],
    );
  }
}

class _RemoveBadge extends StatelessWidget {
  const _RemoveBadge();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: context.appColors.tertiary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.remove_rounded,
        size: 12,
        color: context.appColors.text,
      ),
    ),
  );
}
