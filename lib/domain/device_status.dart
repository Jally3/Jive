/// 设备网络连接类型，不代表互联网可达性或信号强度。
enum DeviceNetworkType { wifi, cellular, ethernet, offline, other, unknown }

/// 顶栏需要的电池快照。
class DeviceBatteryStatus {
  const DeviceBatteryStatus({required this.level, required this.charging});

  final int level;
  final bool charging;

  bool get low => level <= 20 && !charging;

  @override
  bool operator ==(Object other) =>
      other is DeviceBatteryStatus &&
      other.level == level &&
      other.charging == charging;

  @override
  int get hashCode => Object.hash(level, charging);
}
