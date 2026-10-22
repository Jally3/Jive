import 'package:flutter/material.dart';

/// 首页各 Feed 的空/加载/错误状态容器：与正常网格共享同一组
/// header slivers 和滚动控制器，保证分类栏与滚动位置行为一致。
CustomScrollView homeStateScrollView({
  required List<Widget> headerSlivers,
  required ScrollController controller,
  required Widget state,
}) => CustomScrollView(
  controller: controller,
  physics: AlwaysScrollableScrollPhysics(),
  slivers: [
    ...headerSlivers,
    SliverFillRemaining(hasScrollBody: false, child: state),
  ],
);
