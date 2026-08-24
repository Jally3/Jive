import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 是否运行在 Android TV（uiMode = TELEVISION）。
/// iOS / 查询失败一律视为非电视。
final isTvProvider = FutureProvider<bool>((ref) async {
  const channel = MethodChannel('jive/device');
  try {
    return await channel.invokeMethod<bool>('isTelevision') ?? false;
  } catch (_) {
    return false;
  }
});
