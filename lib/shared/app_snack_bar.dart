import 'package:flutter/material.dart';

/// 全局统一的底部提示样式：2 秒自动消失（框架默认是 4 秒）。
/// 同步场景用这个；跨 async gap 已捕获 messenger 的场景用 [showAppSnackBarVia]。
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) =>
    showAppSnackBarVia(ScaffoldMessenger.of(context), message, action: action);

/// 已持有 [ScaffoldMessengerState] 的场景（如 async 回调里提前捕获的 messenger）。
void showAppSnackBarVia(
  ScaffoldMessengerState messenger,
  String message, {
  SnackBarAction? action,
}) => messenger.showSnackBar(
  SnackBar(
    content: Text(message),
    action: action,
    duration: const Duration(seconds: 2),
  ),
);
