import 'package:flutter/material.dart';

import '../../../domain/playback_status.dart';

/// 播放链路状态指示：视觉上只有一个彩色小圆点，不打断观看；
/// 长按弹出「当前播放模式」详情底栏（含降级原因），语义标签保留完整状态文案。
class PlaybackStatusIndicator extends StatelessWidget {
  const PlaybackStatusIndicator({
    super.key,
    required this.status,
    required this.onLongPress,
  });

  final PlaybackStatus status;
  final VoidCallback onLongPress;

  /// 圆点颜色与播放状态的对应关系：
  /// - 灰  preparing：会话建立中；
  /// - 绿  streamingAndCaching：走本地代理且分片正在写穿缓存（边下边播）；
  /// - 蓝  cachePlayback：命中完整缓存离线播放，零流量；
  /// - 橙  proxyWithoutCaching：走代理但缓存不可用（如配额已满）；
  /// - 白灰 direct：回退直连（直播、加密流或 manifest 解析失败）。
  static Color colorFor(PlaybackMode mode) {
    switch (mode) {
      case PlaybackMode.preparing:
        return Colors.white54;
      case PlaybackMode.streamingAndCaching:
        return Colors.greenAccent;
      case PlaybackMode.cachePlayback:
        return Colors.lightBlueAccent;
      case PlaybackMode.proxyWithoutCaching:
        return Colors.orangeAccent;
      case PlaybackMode.direct:
        return Colors.white60;
    }
  }

  static Icon iconFor(PlaybackMode mode, {Color? color}) {
    final icon = switch (mode) {
      PlaybackMode.preparing => Icons.sync,
      PlaybackMode.streamingAndCaching => Icons.download,
      PlaybackMode.cachePlayback => Icons.offline_pin,
      PlaybackMode.proxyWithoutCaching => Icons.cloud_off,
      PlaybackMode.direct => Icons.link,
    };
    return Icon(icon, size: 16, color: color ?? colorFor(mode));
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(status.mode);
    return Semantics(
      button: true,
      // 语义层保留完整状态文案（如「边下边播」），供无障碍与长按详情使用。
      label: '${status.label}，长按查看详情',
      onLongPress: onLongPress,
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const ValueKey('playback-status-gesture'),
          onLongPress: onLongPress,
          behavior: HitTestBehavior.opaque,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              // 视觉元素保持为 8px 圆点，交互热区扩大到 48px。
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 长按状态圆点后的详情底栏内容。
class PlaybackStatusDetails extends StatelessWidget {
  const PlaybackStatusDetails({
    super.key,
    required this.status,
    this.adFilterStatus,
    this.adFilterDebug = const [],
  });

  final PlaybackStatus status;
  final String? adFilterStatus;
  final List<String> adFilterDebug;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前播放模式',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                PlaybackStatusIndicator.iconFor(
                  status.mode,
                  color: PlaybackStatusIndicator.colorFor(status.mode),
                ),
                const SizedBox(width: 10),
                Text(
                  status.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              status.description,
              style: const TextStyle(color: Colors.white70, height: 1.45),
            ),
            if (status.reasonText != null) ...[
              const SizedBox(height: 8),
              Text(
                '原因：${status.reasonText}',
                style: const TextStyle(
                  color: Colors.orangeAccent,
                  height: 1.45,
                ),
              ),
            ],
            if (adFilterStatus != null) ...[
              const SizedBox(height: 12),
              Text(
                adFilterStatus!,
                key: const ValueKey('ad-filter-status'),
                style: const TextStyle(color: Colors.white70, height: 1.45),
              ),
              for (final line in adFilterDebug)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
