import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/device/device_status_provider.dart';
import '../../../domain/device_status.dart';

const _networkIconSize = 16.0;
const _batteryBorderWidth = 1.0;
const _batteryVerticalPadding = 0.5;
const _batteryMinHeight = 14.0;
const _batteryNumberStyle = TextStyle(
  fontSize: 10,
  height: 1,
  fontWeight: FontWeight.w600,
);

/// 状态区高度取网络图标与电池数字外框的较大值，供倍速提示避让。
double playerDeviceStatusIconHeight(TextScaler textScaler) {
  final painter = TextPainter(
    text: const TextSpan(text: '100', style: _batteryNumberStyle),
    textScaler: textScaler,
    textDirection: TextDirection.ltr,
  )..layout();
  final height =
      painter.height + 2 * (_batteryBorderWidth + _batteryVerticalPadding);
  painter.dispose();
  return height < _networkIconSize ? _networkIconSize : height;
}

/// 每个状态各自消费 Riverpod；数据变化不重建顶栏或播放器。
class PlayerDeviceStatus extends ConsumerWidget {
  const PlayerDeviceStatus({
    super.key,
    required this.visible,
    this.isTv = false,
  });

  final bool visible;
  final bool isTv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foreground = ref.watch(deviceForegroundProvider);
    final active = visible && foreground;
    return DefaultTextStyle(
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
      child: Row(
        key: const ValueKey('player-device-status'),
        mainAxisSize: MainAxisSize.min,
        children: [
          _ClockStatus(active: active),
          const SizedBox(width: 8),
          _NetworkStatus(active: active),
          if (!isTv) ...[
            const SizedBox(width: 8),
            _BatteryStatus(active: active),
          ],
        ],
      ),
    );
  }
}

class _ClockStatus extends ConsumerWidget {
  const _ClockStatus({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref.watch(
      deviceClockProvider(active).select(
        (value) => value.value == null ? null : deviceClockLabel(value.value!),
      ),
    );
    final time = label ?? deviceClockLabel(ref.read(deviceNowProvider)());
    return Semantics(
      label: '当前时间 $time',
      excludeSemantics: true,
      child: Text(time, key: const ValueKey('player-device-clock')),
    );
  }
}

class _NetworkStatus extends ConsumerWidget {
  const _NetworkStatus({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = active
        ? ref.watch(deviceNetworkTypeProvider)
        : ref.read(deviceNetworkTypeProvider);
    final (icon, label) = switch (type) {
      DeviceNetworkType.wifi => (Icons.wifi, 'Wi-Fi'),
      DeviceNetworkType.cellular => (Icons.cell_tower, '蜂窝'),
      DeviceNetworkType.ethernet => (Icons.lan_outlined, '有线'),
      DeviceNetworkType.offline => (Icons.wifi_off, '无连接'),
      DeviceNetworkType.other => (Icons.public, '网络'),
      DeviceNetworkType.unknown => (Icons.device_unknown, '未知'),
    };
    return Semantics(
      label: '网络 $label',
      excludeSemantics: true,
      child: Row(
        key: const ValueKey('player-device-network'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: _networkIconSize, color: Colors.white),
          if (type != DeviceNetworkType.wifi) ...[
            const SizedBox(width: 4),
            Text(label),
          ],
        ],
      ),
    );
  }
}

class _BatteryStatus extends ConsumerWidget {
  const _BatteryStatus({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(deviceBatteryProvider(active));
    final battery = value.isLoading
        ? ref.read(deviceBatterySourceProvider).cached
        : value.value;
    final color = battery?.low == true ? Colors.redAccent : Colors.white;
    final label = battery == null ? '--' : '${battery.level}';
    return Semantics(
      label: battery == null
          ? '电量未知'
          : '电量 ${battery.level}%${battery.charging ? '，充电中' : ''}',
      excludeSemantics: true,
      child: Row(
        key: const ValueKey('player-device-battery'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: const ValueKey('player-device-battery-body'),
            constraints: const BoxConstraints(
              minWidth: 22,
              minHeight: _batteryMinHeight,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 2,
              vertical: _batteryVerticalPadding,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              border: Border.all(color: color, width: _batteryBorderWidth),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (battery?.charging == true) ...[
                    Icon(Icons.bolt, size: 8, color: color),
                    const SizedBox(width: 1),
                  ],
                  Text(
                    label,
                    key: const ValueKey('player-device-battery-level'),
                    style: _batteryNumberStyle.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 1),
          Container(
            width: 1.5,
            height: 5,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
