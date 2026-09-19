import 'package:flutter/material.dart';

/// 不可用条目的处理动作：回到当前来源搜索，或继续找备用源。
enum HomeUnavailableAction { reviewCurrentSource, searchBackups }

/// 策展/推荐条目在当前来源不可用时的统一确认对话框，
/// 「取消 / 继续查找 3 个备用源 / 前往搜索页（或查看搜索结果）」。
Future<HomeUnavailableAction?> showHomeUnavailableDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) => showDialog<HomeUnavailableAction>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(title),
    content: Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () =>
            Navigator.pop(dialogContext, HomeUnavailableAction.searchBackups),
        child: const Text('继续查找 3 个备用源'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          dialogContext,
          HomeUnavailableAction.reviewCurrentSource,
        ),
        child: Text(confirmLabel),
      ),
    ],
  ),
);
