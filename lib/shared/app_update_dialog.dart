import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../data/update/app_update_service.dart';
import '../domain/app_update_info.dart';
import 'app_toast.dart';

Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateInfo update,
  required AppUpdateGateway gateway,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${update.versionName}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 320),
        child: SingleChildScrollView(
          child: Text(
            update.releaseNotes.isEmpty
                ? '新版本已经发布，是否前往下载？'
                : update.releaseNotes.map((note) => '• $note').join('\n'),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _laterButtonStyle(dialogContext),
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('稍后'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  autofocus: true,
                  onPressed: () async {
                    final overlay = Overlay.of(dialogContext);
                    Navigator.pop(dialogContext);
                    final opened = await gateway.openDownload(update);
                    if (!opened) {
                      showAppToastVia(overlay, '无法打开下载链接，请稍后重试');
                    }
                  },
                  child: const Text('立即下载'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

ButtonStyle _laterButtonStyle(BuildContext context) =>
    OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      foregroundColor: context.appColors.text,
      backgroundColor: context.appColors.elevated,
      side: BorderSide(color: context.appColors.tertiary),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    ).copyWith(
      side: WidgetStateBorderSide.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: context.appColors.text, width: 2)
            : BorderSide(color: context.appColors.tertiary),
      ),
    );
