import 'package:flutter/material.dart';

/// 首页 Feed 滚动状态：按 key 记忆各 Feed/榜单的滚动位置，
/// 切换 Feed 时发起"滚动过渡"，未被打断则帧后恢复到记忆位置；
/// 同时维护「返回顶部」悬浮按钮的可见性。
///
/// key 由调用方（首页）按 来源+Feed+分类 组合生成，本类只负责存取。
class FeedScrollMemory {
  final scrollController = ScrollController(keepScrollOffset: false);
  final showBackToTop = ValueNotifier<bool>(false);
  final Map<String, double> _offsets = {};
  int _epoch = 0;
  int? _active;
  bool _userScrolled = false;
  bool _disposed = false;

  void reset() {
    showBackToTop.value = false;
    if (scrollController.hasClients) scrollController.jumpTo(0);
  }

  void resetAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) reset();
    });
  }

  void savePosition(String key) {
    if (_disposed || !scrollController.hasClients) return;
    _offsets[key] = scrollController.offset;
  }

  /// 切换 VOD 分类/来源时丢弃全部记忆（此时应回到顶部）。
  void clear() => _offsets.clear();

  /// 开始一次滚动过渡，返回过渡 id；配合 [finishTransition] 使用。
  int beginTransition() {
    final epoch = ++_epoch;
    _active = epoch;
    _userScrolled = false;
    return epoch;
  }

  /// 过渡收尾：用户已手动滚动则放弃恢复；否则等下一帧把
  /// [currentKey] 对应的记忆位置恢复回来（帧内 key 可能已再变）。
  void finishTransition(int epoch, {required String Function() currentKey}) {
    if (_active != epoch) return;
    if (_userScrolled) {
      _active = null;
      return;
    }
    final expectedKey = currentKey();
    final offset = _offsets[expectedKey] ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _active != epoch) {
        return;
      }
      if (_userScrolled ||
          expectedKey != currentKey() ||
          !scrollController.hasClients) {
        _active = null;
        return;
      }
      final position = scrollController.position;
      final restoredOffset = offset
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      scrollController.jumpTo(restoredOffset);
      showBackToTop.value = restoredOffset > 600;
      _active = null;
    });
  }

  /// 挂在首页滚动通知上：过渡期间检测到用户手动拖动则标记放弃恢复。
  bool trackLoadingInteraction(ScrollNotification notification) {
    if (_active != null &&
        notification.metrics.axis == Axis.vertical &&
        notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolled = true;
    }
    return false;
  }

  void scrollToTop() {
    if (!scrollController.hasClients) return;
    scrollController.animateTo(
      0,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void dispose() {
    _disposed = true;
    scrollController.dispose();
    showBackToTop.dispose();
  }
}
