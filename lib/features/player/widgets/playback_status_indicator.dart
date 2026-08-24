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
