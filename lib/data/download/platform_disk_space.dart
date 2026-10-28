import 'package:flutter/services.dart';
import '../cache/cache_manager.dart';

const MethodChannel _channel = MethodChannel('jive/cache');

class PlatformDiskSpaceProvider implements DiskSpaceProvider {
  @override
  Future<int?> totalCapacityBytes() async {
    try {
      return await _channel.invokeMethod<int>('totalCapacityBytes');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> availableBytes() async {
    try {
      final value = await _channel.invokeMethod<int>('availableBytes');
      if (value != null && value >= 0) return value;
    } catch (_) {
      throw const DiskSpaceQueryException();
    }
    throw const DiskSpaceQueryException();
  }

  @override
  Future<int?> platformCacheLimitBytes() async {
    try {
      return await _channel.invokeMethod<int>('platformCacheLimitBytes');
    } catch (_) {
      return null;
    }
  }
}
