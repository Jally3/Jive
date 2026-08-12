import 'package:flutter/material.dart';
import '../app/theme.dart';

class AppLoadingView extends StatelessWidget {
  const AppLoadingView({super.key, this.label = '正在加载…'});
  final String label;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(label, style: const TextStyle(color: AppColors.secondary)),
      ],
    ),
  );
}

class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.message,
    this.icon = Icons.video_library_outlined,
  });
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) =>
      _StateContent(icon: icon, message: message);
}

class AppErrorView extends StatelessWidget {
  const AppErrorView({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => _StateContent(
    icon: Icons.wifi_off_rounded,
    message: message,
    action: '重试',
    onTap: onRetry,
  );
}

class _StateContent extends StatelessWidget {
  const _StateContent({
    required this.icon,
    required this.message,
    this.action,
    this.onTap,
  });
  final IconData icon;
  final String message;
  final String? action;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.tertiary),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.secondary, height: 1.5),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: onTap, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}
