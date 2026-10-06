abstract final class PlaybackTraceStage {
  const PlaybackTraceStage._();

  static const downloadSelectionLookup = 'downloadSelectionLookup';
  static const detailResolvePlayback = 'detailResolvePlayback';
  static const favoriteSnapshotRefresh = 'favoriteSnapshotRefresh';
  static const playerRoutePush = 'playerRoutePush';
  static const skipPolicyLoad = 'skipPolicyLoad';
  static const unknownCachePrecheck = 'unknownCachePrecheck';
  static const playbackSourceResolve = 'playbackSourceResolve';
  static const contentTypeSniff = 'contentTypeSniff';
  static const hlsSessionPrepare = 'hlsSessionPrepare';
  static const proxyServerStart = 'proxyServerStart';
  static const cacheManagerLoad = 'cacheManagerLoad';
  static const sessionCacheLookup = 'sessionCacheLookup';
  static const hlsManifestFetch = 'hlsManifestFetch';
  static const hlsManifestParse = 'hlsManifestParse';
  static const hlsAdFilter = 'hlsAdFilter';
  static const hlsProxyPlan = 'hlsProxyPlan';
  static const sessionCacheEntry = 'sessionCacheEntry';
  static const sessionCachePersist = 'sessionCachePersist';
  static const sessionCacheAcquire = 'sessionCacheAcquire';
  static const proxyFallbackCleanup = 'proxyFallbackCleanup';
  static const controllerInitializeProxy = 'controllerInitializeProxy';
  static const controllerInitializeDirect = 'controllerInitializeDirect';
  static const controllerConfigure = 'controllerConfigure';
  static const resumeSeek = 'resumeSeek';
  static const controllerSetSpeed = 'controllerSetSpeed';
  static const controllerSetVolume = 'controllerSetVolume';
  static const controllerPlay = 'controllerPlay';
}
