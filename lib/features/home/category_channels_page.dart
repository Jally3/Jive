import 'package:flutter/material.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

import '../../app/theme.dart';
import '../../domain/video.dart';

/// 分类 chip 的通用样式：主分类行与子分类行（copyWith 调整）共用。
ChipThemeData get categoryChipTheme => ChipThemeData(
  backgroundColor: AppColors.elevated.withValues(alpha: 0.6),
  selectedColor: AppColors.accent,
  disabledColor: AppColors.surface,
  side: const BorderSide(color: AppColors.divider),
  shape: const StadiumBorder(),
  labelStyle: const TextStyle(color: AppColors.text, fontSize: 14),
  secondaryLabelStyle: const TextStyle(
    color: AppColors.onAccent,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  ),
  checkmarkColor: AppColors.onAccent,
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  // 选中态是 accent 实心底，focusColor 洗上去不可见，聚焦时加深区分。
  // 触摸点击不会持有焦点（仅方向键/键盘），手机端无变化。
  color: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.selected)) {
      return states.contains(WidgetState.focused)
          ? AppColors.accentPressed
          : AppColors.accent;
    }
    return AppColors.elevated.withValues(alpha: 0.6);
  }),
);

/// 「全部频道」全屏页面：我的频道 4 列网格 + 全部分类分组。
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
    key: const ValueKey('category-channels-page'),
    backgroundColor: AppColors.background,
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: _titleBar(),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _myChannelsSection(),
                  for (final root in widget.roots) ...[
                    const SizedBox(height: 20),
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

  Widget _titleBar() => Row(
    children: [
      const Text(
        '全部频道',
        style: TextStyle(
          color: AppColors.text,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
      const Spacer(),
      IconButton(
        key: const ValueKey('category-channels-close'),
        tooltip: '关闭',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close_rounded, color: AppColors.secondary),
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
  );

  Widget _sectionHeader(String title, {List<Widget> actions = const []}) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(
          color: AppColors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      const Spacer(),
      ...actions,
    ],
  );

  Widget _headerAction(String label, {VoidCallback? onTap, Color? color}) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
          child: Text(
            label,
            style: TextStyle(color: color ?? AppColors.secondary, fontSize: 13),
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
                    color: AppColors.accent,
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
        const SizedBox(height: 8),
        if (_editing)
          // 「最新」放在 header 占首格：不参与拖拽也不可移除。
          ReorderableGridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.4,
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

  /// 有子分类：根分类名作小标题，子分类排 4 列网格；
  /// 无子分类：根分类自身占一格。编辑态区头带「+ 添加 / 已添加」。
  Widget _rootSection(VideoCategory root) {
    final kids = widget.children[root.id] ?? const <VideoCategory>[];
    final inMine = _myIds.contains(root.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          root.name,
          actions: !_editing
              ? const []
              : [
                  if (inMine)
                    _headerAction('已添加', color: AppColors.tertiary)
                  else
                    _headerAction(
                      '+ 添加',
                      color: AppColors.accent,
                      onTap: () => _add(root.id),
                    ),
                ],
        ),
        const SizedBox(height: 8),
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
    crossAxisCount: 4,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 8,
    crossAxisSpacing: 8,
    childAspectRatio: 2.4,
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
              ? AppColors.accent
              : AppColors.elevated.withValues(alpha: dimmed ? 0.35 : 0.6),
          shape: StadiumBorder(
            side: selected
                ? BorderSide.none
                : const BorderSide(color: AppColors.divider),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected
                ? AppColors.onAccent
                : (dimmed ? AppColors.tertiary : AppColors.text),
            fontSize: 13,
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
        const Positioned(top: -5, right: -3, child: _RemoveBadge()),
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
      decoration: const BoxDecoration(
        color: AppColors.tertiary,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.remove_rounded, size: 12, color: AppColors.text),
    ),
  );
}
