enum PlaybackMode {
  preparing,
  streamingAndCaching,
  cachePlayback,
  proxyWithoutCaching,
  direct,
}

enum PlaybackFallbackReason {
  stableIdentityMissing,
  unsupportedFormat,
  liveStream,
  encryptedStream,
  unsupportedHls,
  manifestRequestFailed,
  manifestHttpError,
  proxyStartFailed,
  proxyPreparationFailed,
  proxyControllerInitializationFailed,
  cacheUnavailable,
  cacheQuotaExceeded,
  cacheWriteFailed,
  playbackAddressRefreshFailed,
}

class PlaybackStatus {
  const PlaybackStatus({required this.mode, this.reason});

  const PlaybackStatus.preparing()
    : mode = PlaybackMode.preparing,
      reason = null;

  final PlaybackMode mode;
  final PlaybackFallbackReason? reason;

  bool get isEdgeCaching => mode == PlaybackMode.streamingAndCaching;

  String get label {
    switch (mode) {
      case PlaybackMode.preparing:
        return '判断中…';
      case PlaybackMode.streamingAndCaching:
        return '边下边播';
      case PlaybackMode.cachePlayback:
        return '缓存播放';
      case PlaybackMode.proxyWithoutCaching:
        return '在线播放';
      case PlaybackMode.direct:
        return '直连播放';
    }
  }

  String get description {
    switch (mode) {
      case PlaybackMode.preparing:
        return '正在检查播放地址和本地缓存能力。';
      case PlaybackMode.streamingAndCaching:
        return '当前片段会在播放的同时写入本地缓存。';
      case PlaybackMode.cachePlayback:
        return '当前资源已完整缓存，不需要继续下载。';
      case PlaybackMode.proxyWithoutCaching:
        return '当前通过代理播放，但新片段不会写入本地缓存。';
      case PlaybackMode.direct:
        return '当前未使用本地缓存代理，播放器直接访问远端地址。';
    }
  }

  String? get reasonText {
    switch (reason) {
      case PlaybackFallbackReason.stableIdentityMissing:
        return '播放源缺少稳定的线路或剧集标识。';
      case PlaybackFallbackReason.unsupportedFormat:
        return '当前格式不在缓存范围内，仅支持普通 VOD HLS。';
      case PlaybackFallbackReason.liveStream:
        return '检测到直播或事件流，直播内容不进入缓存。';
      case PlaybackFallbackReason.encryptedStream:
        return '检测到加密、SAMPLE-AES 或 DRM 内容，已回退直连。';
      case PlaybackFallbackReason.unsupportedHls:
        return 'HLS 含有当前能力矩阵之外的标签，已回退直连。';
      case PlaybackFallbackReason.manifestRequestFailed:
        return '播放清单请求失败，已回退直连。';
      case PlaybackFallbackReason.manifestHttpError:
        return '播放清单响应异常，已回退直连。';
      case PlaybackFallbackReason.proxyStartFailed:
        return '本地播放代理启动失败，已回退直连。';
      case PlaybackFallbackReason.proxyPreparationFailed:
        return '本地播放代理准备失败，已回退直连。';
      case PlaybackFallbackReason.proxyControllerInitializationFailed:
        return '播放器无法初始化本地代理地址，已回退直连。';
      case PlaybackFallbackReason.cacheUnavailable:
        return '缓存服务不可用，当前仅通过代理播放。';
      case PlaybackFallbackReason.cacheQuotaExceeded:
        return '缓存配额或系统安全余量不足，当前片段仅回源播放。';
      case PlaybackFallbackReason.cacheWriteFailed:
        return '缓存文件写入或提交失败，当前片段仅回源播放。';
      case PlaybackFallbackReason.playbackAddressRefreshFailed:
        return '播放地址刷新失败，当前未建立缓存代理。';
      case null:
        return null;
    }
  }
}
