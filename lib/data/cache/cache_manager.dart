import 'dart:async';
import 'dart:io';
import 'cache_index.dart';
import 'single_flight.dart';

abstract interface class DiskSpaceProvider {
  Future<int?> totalCapacityBytes();

  Future<int> availableBytes();

  Future<int?> platformCacheLimitBytes();
}

int _clampInt(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);

int computeEffectiveQuota({
  required int availableBytes,
  required int jiveCacheBytes,
  int? totalCapacity,
  int? platformCacheLimit,
}) {
  // Cache files live in the app's persistent support directory, not the
  // platform temporary-cache directory. Therefore Android's
  // getCacheQuotaBytes() is not a storage limit for these files. Keep the
  // parameter for platform compatibility, but do not cap user downloads by it.
  final managed = _clampInt(availableBytes + jiveCacheBytes, 0, 1 << 62);
  var effective = managed;
  if (totalCapacity != null) {
    const oneGb = 1 << 30;
    final safety = _clampInt((totalCapacity * 5) ~/ 100, 2 * oneGb, 10 * oneGb);
    final headroom = managed - safety;
    if (headroom < effective) effective = headroom < 0 ? 0 : headroom;
  }
  return effective < 0 ? 0 : effective;
}

enum DeleteResult { deleted, blocked, notFound, failed }

class ClearAllResult {
  ClearAllResult({this.deleted = 0, this.skippedActive = 0, this.failed = 0});

  int deleted;
  int skippedActive;
  int failed;
}

class CacheRef {
  CacheRef._(this._manager, this.entryKey);

  final CacheManager _manager;
  final String entryKey;

  Future<void> dispose() => _manager.release(entryKey);
}

class WriteLease {
  WriteLease._(this._manager, this.id, this.entryKey, this.bytes);

  final CacheManager _manager;
  final int id;
  final String entryKey;
  int bytes;

  Future<bool> ensureCapacity(int totalBytes) =>
      _manager._resizeLease(this, totalBytes);

  Future<void> commitResource({
    required String resourceId,
    required int size,
    required String ext,
  }) => _manager._commitResource(
    this,
    resourceId: resourceId,
    size: size,
    ext: ext,
  );

  Future<void> cancel() => _manager._cancelLease(this);
}

class CacheManager {
  CacheManager({
    required this.store,
    required this.diskSpace,
    this.saveThrottle = const Duration(milliseconds: 800),
  });

  final CacheIndexStore store;
  final DiskSpaceProvider diskSpace;
  final Duration saveThrottle;

  final AsyncMutex _lock = AsyncMutex();
  final Map<String, CacheEntry> _entries = {};
  final Map<String, Map<String, CacheResourceRecord>> _resources = {};
  final Map<String, int> _refs = {};
  final Map<int, int> _pending = {};
  int _nextLeaseId = 1;
  int _quotaBytes = 0;
  int _usedByDisk = 0;
  Timer? _saveTimer;
  bool _saving = false;

  int get quotaBytes => _quotaBytes;

  Future<void> initialize() async {
    final loaded = await store.loadIndex();
    final states = await store.rebuildFromStates();
    await _lock.synchronize(() async {
      _entries.clear();
      _resources.clear();
      for (final entry in loaded) {
        _entries[entry.key] = entry;
      }
      for (final state in states) {
        _entries[state.key] = state;
        _resources[state.key] = Map.of(state.resources);
      }
    });
    await store.cleanupTempFiles();
    await reconcile();
    await refreshQuota();
    await _flushIndex();
  }

  /// 以实际磁盘资源为准重算每个条目的字节/计数/可离线状态；
  /// 文件缺失或大小不匹配时回退，deleting 残留重试删除。
  Future<void> reconcile() async {
    await _lock.synchronize(() async {
      for (final entryKey in _entries.keys.toList()) {
        await _reconcileEntry(entryKey);
      }
      _recomputeUsed();
    });
  }

  Future<void> _reconcileEntry(String entryKey) async {
    final entry = _entries[entryKey];
    if (entry == null) return;
    if (entry.status == CacheEntryStatus.deleting) {
      final dir = store.entryDir(entry.contentKeyHash, entry.revisionKeyHash);
      if (await dir.exists()) {
        try {
          await store.deleteEntryDir(
            entry.contentKeyHash,
            entry.revisionKeyHash,
          );
        } catch (_) {
          return;
        }
      }
      _entries.remove(entryKey);
      _resources.remove(entryKey);
      return;
    }
    final records = _resources[entryKey] ??= {};
    var completeBytes = 0;
    var partialBytes = 0;
    var committed = 0;
    for (final id in records.keys.toList()) {
      final record = records[id];
      if (record == null) {
        records.remove(id);
        continue;
      }
      final file = record.complete
          ? store.resourceFile(
              entry.contentKeyHash,
              entry.revisionKeyHash,
              id,
              record.ext,
            )
          : store.partialFile(entry.contentKeyHash, entry.revisionKeyHash, id);
      if (!await file.exists()) {
        records.remove(id);
        continue;
      }
      final length = await file.length();
      if (record.complete) {
        if (length == record.size) {
          completeBytes += length;
          committed++;
        } else {
          records[id] = CacheResourceRecord(
            resourceType: record.resourceType,
            status: CacheResourceStatus.partial,
            size: length,
            ext: record.ext,
          );
          partialBytes += length;
        }
      } else {
        partialBytes += length;
      }
    }
    final expected = entry.expectedResourceCount;
    final manifestsReady =
        await store
            .sourceManifestFile(entry.contentKeyHash, entry.revisionKeyHash)
            .exists() &&
        await store
            .proxyManifestFile(entry.contentKeyHash, entry.revisionKeyHash)
            .exists();
    final timelineReady =
        entry.filterVersion <= 0 ||
        await File(
          '${store.entryDir(entry.contentKeyHash, entry.revisionKeyHash).path}/$cacheTimelineFileName',
        ).exists();
    final offline =
        !entry.finalizationRequired &&
        expected > 0 &&
        committed >= expected &&
        manifestsReady &&
        timelineReady;
    _entries[entryKey] = entry.copyWith(
      completeBytes: completeBytes,
      partialBytes: partialBytes,
      committedResourceCount: committed,
      offlinePlayable: offline,
      status: offline
          ? CacheEntryStatus.complete
          : (committed > 0 ? CacheEntryStatus.partial : entry.status),
      updatedAtMs: _now(),
    );
    await _persistState(entryKey);
  }

  void _recomputeUsed() {
    var used = 0;
    for (final entry in _entries.values) {
      used += entry.completeBytes + entry.partialBytes;
    }
    _usedByDisk = used;
  }

  Future<int> refreshQuota() async {
    final total = await diskSpace.totalCapacityBytes();
    final available = await diskSpace.availableBytes();
    final platform = await diskSpace.platformCacheLimitBytes();
    final jive = await _lock.synchronize(() async => _usedByDisk);
    _quotaBytes = computeEffectiveQuota(
      availableBytes: available,
      jiveCacheBytes: jive,
      totalCapacity: total,
      platformCacheLimit: platform,
    );
    return _quotaBytes;
  }

  Future<CacheEntry> upsertEntry(CacheEntry entry) =>
      _lock.synchronize(() async {
        final existing = _entries[entry.key];
        if (existing != null) return existing;
        final nowMs = _now();
        final created = entry.copyWith(createdAtMs: nowMs, updatedAtMs: nowMs);
        _entries[entry.key] = created;
        await _persistState(entry.key);
        _scheduleIndexSave();
        return created;
      });

  Future<void> setExpectations(
    String entryKey,
    int expectedCount, {
    bool requireFinalization = false,
  }) => _lock.synchronize(() async {
    final entry = _entries[entryKey];
    if (entry == null) return;
    final ready =
        !requireFinalization && entry.committedResourceCount >= expectedCount;
    final updated = entry.copyWith(
      expectedResourceCount: expectedCount,
      finalizationRequired: requireFinalization,
      offlinePlayable: ready,
      status: ready ? CacheEntryStatus.complete : CacheEntryStatus.partial,
      updatedAtMs: _now(),
    );
    _entries[entryKey] = updated;
    await _persistState(entry.key);
    _scheduleIndexSave();
  });

  Future<bool> finalizeEntry(String entryKey) => _lock.synchronize(() async {
    final entry = _entries[entryKey];
    if (entry == null ||
        entry.expectedResourceCount <= 0 ||
        entry.committedResourceCount < entry.expectedResourceCount) {
      return false;
    }
    final sourceReady = await store
        .sourceManifestFile(entry.contentKeyHash, entry.revisionKeyHash)
        .exists();
    final proxyReady = await store
        .proxyManifestFile(entry.contentKeyHash, entry.revisionKeyHash)
        .exists();
    final timelineReady =
        entry.filterVersion <= 0 ||
        await File(
          '${store.entryDir(entry.contentKeyHash, entry.revisionKeyHash).path}/$cacheTimelineFileName',
        ).exists();
    if (!sourceReady || !proxyReady || !timelineReady) return false;
    _entries[entryKey] = entry.copyWith(
      finalizationRequired: false,
      offlinePlayable: true,
      status: CacheEntryStatus.complete,
      updatedAtMs: _now(),
    );
    await _persistState(entryKey);
    _scheduleIndexSave();
    return true;
  });

  /// Updates the manifest metadata after a downloaded raw playlist has been
  /// filtered locally. Resource records remain unchanged because the filtered
  /// playlist reuses the already downloaded resource IDs.
  Future<void> updateManifestMetadata(
    String entryKey, {
    required int filterVersion,
    required int timelineVersion,
  }) => _lock.synchronize(() async {
    final entry = _entries[entryKey];
    if (entry == null) return;
    _entries[entryKey] = entry.copyWith(
      filterVersion: filterVersion,
      timelineVersion: timelineVersion,
      updatedAtMs: _now(),
    );
    await _persistState(entryKey);
    _scheduleIndexSave();
  });

  Future<WriteLease?> reserve(String entryKey, int bytes) => _lock.synchronize(
    () async {
      final entry = _entries[entryKey];
      if (entry == null || entry.status == CacheEntryStatus.deleting) {
        return null;
      }
      if (bytes <= 0 || _quotaBytes <= 0) return null;
      final used = _usedByDisk + _pendingBytes();
      if (used + bytes > _quotaBytes) {
        await _evictToFree(bytes - (_quotaBytes - used), excludeKey: entryKey);
      }
      final afterEvict = _usedByDisk + _pendingBytes();
      if (afterEvict + bytes > _quotaBytes) return null;
      final id = _nextLeaseId++;
      _pending[id] = bytes;
      return WriteLease._(this, id, entryKey, bytes);
    },
  );

  Future<void> markPartial(String entryKey, String resourceId, int size) =>
      _lock.synchronize(() async {
        final entry = _entries[entryKey];
        if (entry == null || entry.status == CacheEntryStatus.deleting) return;
        final records = _resources[entryKey] ??= {};
        final existing = records[resourceId];
        final delta = size - (existing?.size ?? 0);
        _entries[entryKey] = entry.copyWith(
          partialBytes: entry.partialBytes + delta,
          updatedAtMs: _now(),
        );
        _usedByDisk += delta;
        records[resourceId] = CacheResourceRecord(
          resourceType: CacheResourceType.segment,
          status: CacheResourceStatus.partial,
          size: size,
          ext: 'part',
        );
        await _persistState(entryKey);
        _scheduleIndexSave();
      });

  Future<void> _commitResource(
    WriteLease lease, {
    required String resourceId,
    required int size,
    required String ext,
  }) => _lock.synchronize(() async {
    _pending.remove(lease.id);
    final entry = _entries[lease.entryKey];
    if (entry == null || entry.status == CacheEntryStatus.deleting) return;
    final records = _resources[lease.entryKey] ??= {};
    final existing = records[resourceId];
    if (existing != null && existing.complete) return;
    final partSize = existing != null && !existing.complete ? existing.size : 0;
    final committed = entry.committedResourceCount + 1;
    final offline =
        !entry.finalizationRequired &&
        entry.expectedResourceCount > 0 &&
        committed >= entry.expectedResourceCount;
    _entries[lease.entryKey] = entry.copyWith(
      committedResourceCount: committed,
      completeBytes: entry.completeBytes + size,
      partialBytes: entry.partialBytes - partSize,
      offlinePlayable: offline,
      status: offline ? CacheEntryStatus.complete : CacheEntryStatus.partial,
      updatedAtMs: _now(),
    );
    _usedByDisk += size - partSize;
    records[resourceId] = CacheResourceRecord(
      resourceType: CacheResourceType.segment,
      status: CacheResourceStatus.complete,
      size: size,
      ext: ext,
    );
    await _persistState(lease.entryKey);
    _scheduleIndexSave();
  });

  Future<void> _cancelLease(WriteLease lease) => _lock.synchronize(() async {
    _pending.remove(lease.id);
  });

  Future<bool> _resizeLease(WriteLease lease, int totalBytes) =>
      _lock.synchronize(() async {
        if (!_pending.containsKey(lease.id)) return false;
        if (totalBytes <= lease.bytes) return true;
        final additional = totalBytes - lease.bytes;
        final used = _usedByDisk + _pendingBytes();
        if (used + additional > _quotaBytes) {
          await _evictToFree(
            additional - (_quotaBytes - used),
            excludeKey: lease.entryKey,
          );
        }
        if (_usedByDisk + _pendingBytes() + additional > _quotaBytes) {
          return false;
        }
        lease.bytes = totalBytes;
        _pending[lease.id] = totalBytes;
        return true;
      });

  Future<void> touch(String entryKey) => _lock.synchronize(() async {
    final entry = _entries[entryKey];
    if (entry == null || entry.status == CacheEntryStatus.deleting) return;
    _entries[entryKey] = entry.copyWith(lastAccessMs: _now());
    await _persistState(entryKey);
    _scheduleIndexSave();
  });

  Future<CacheResourceRecord?> resourceRecord(
    String entryKey,
    String resourceId,
  ) => _lock.synchronize(() async => _resources[entryKey]?[resourceId]);

  Future<String?> cachedResourceExt(String entryKey, String resourceId) =>
      _lock.synchronize(() async {
        final record = _resources[entryKey]?[resourceId];
        return record != null && record.complete ? record.ext : null;
      });

  Future<Map<String, CacheResourceRecord>> resourceCatalog(String entryKey) =>
      _lock.synchronize(() async {
        return Map.of(_resources[entryKey] ?? const {});
      });

  Future<CacheEntry?> getEntry(String entryKey) =>
      _lock.synchronize(() async => _entries[entryKey]);

  Future<CacheEntry?> findOffline(
    String contentKeyHash,
    String manifestBaseUrl,
  ) => _lock.synchronize(() async {
    CacheEntry? best;
    for (final entry in _entries.values) {
      if (entry.contentKeyHash != contentKeyHash) continue;
      if (!entry.offlinePlayable) continue;
      if (manifestBaseUrl.isNotEmpty &&
          entry.manifestBaseUrl != manifestBaseUrl) {
        continue;
      }
      if (best == null || entry.updatedAtMs > best.updatedAtMs) {
        best = entry;
      }
    }
    return best;
  });

  Future<CacheRef> acquire(String entryKey) => _lock.synchronize(() async {
    _refs[entryKey] = (_refs[entryKey] ?? 0) + 1;
    return CacheRef._(this, entryKey);
  });

  Future<void> release(String entryKey) => _lock.synchronize(() async {
    final count = _refs[entryKey] ?? 0;
    if (count <= 1) {
      _refs.remove(entryKey);
    } else {
      _refs[entryKey] = count - 1;
    }
  });

  Future<DeleteResult> deleteEntry(String entryKey) =>
      _lock.synchronize(() async {
        final entry = _entries[entryKey];
        if (entry == null) return DeleteResult.notFound;
        if ((_refs[entryKey] ?? 0) > 0) return DeleteResult.blocked;
        return _removeEntry(entry);
      });

  Future<ClearAllResult> clearAll() => _lock.synchronize(() async {
    final result = ClearAllResult();
    for (final entry in _entries.values.toList()) {
      if ((_refs[entry.key] ?? 0) > 0) {
        result.skippedActive++;
        continue;
      }
      final deleting = entry.copyWith(
        status: CacheEntryStatus.deleting,
        updatedAtMs: _now(),
      );
      _entries[entry.key] = deleting;
      await _persistState(entry.key);
      try {
        await store.deleteEntryDir(entry.contentKeyHash, entry.revisionKeyHash);
        _entries.remove(entry.key);
        _resources.remove(entry.key);
        _usedByDisk -= entry.completeBytes + entry.partialBytes;
        result.deleted++;
      } catch (_) {
        result.failed++;
      }
    }
    await _flushIndex();
    return result;
  });

  Future<void> markFailed(String entryKey, String reason) =>
      _lock.synchronize(() async {
        final entry = _entries[entryKey];
        if (entry == null) return;
        _entries[entryKey] = entry.copyWith(
          status: CacheEntryStatus.failed,
          errorSummary: reason,
          updatedAtMs: _now(),
        );
        await _persistState(entryKey);
        _scheduleIndexSave();
      });

  Future<CacheStats> stats() => _lock.synchronize(() async {
    var complete = 0;
    var partial = 0;
    for (final entry in _entries.values) {
      complete += entry.completeBytes;
      partial += entry.partialBytes;
    }
    final entries = _entries.values.toList()
      ..sort((a, b) => b.lastAccessMs.compareTo(a.lastAccessMs));
    return CacheStats(
      completeBytes: complete,
      partialBytes: partial,
      reservedBytes: _pendingBytes(),
      quotaBytes: _quotaBytes,
      entries: entries,
    );
  });

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _flushIndex();
  }

  Future<void> _evictToFree(int neededBytes, {String? excludeKey}) async {
    var freed = 0;
    for (final candidate in _evictionCandidates(excludeKey)) {
      if (freed >= neededBytes) break;
      final key = candidate.key;
      final size = candidate.completeBytes + candidate.partialBytes;
      if (size <= 0) continue;
      try {
        await store.deleteEntryDir(
          candidate.contentKeyHash,
          candidate.revisionKeyHash,
        );
        _entries.remove(key);
        _resources.remove(key);
        _usedByDisk -= size;
        freed += size;
      } catch (_) {}
    }
    if (freed > 0) _scheduleIndexSave();
  }

  List<CacheEntry> _evictionCandidates(String? excludeKey) {
    final partial = <CacheEntry>[];
    final complete = <CacheEntry>[];
    for (final entry in _entries.values) {
      if (entry.key == excludeKey) continue;
      if ((_refs[entry.key] ?? 0) > 0) continue;
      if (entry.status == CacheEntryStatus.deleting) continue;
      if (entry.status == CacheEntryStatus.complete) {
        complete.add(entry);
      } else {
        partial.add(entry);
      }
    }
    partial.sort((a, b) => a.lastAccessMs.compareTo(b.lastAccessMs));
    complete.sort((a, b) => a.lastAccessMs.compareTo(b.lastAccessMs));
    return [...partial, ...complete];
  }

  Future<DeleteResult> _removeEntry(CacheEntry entry) async {
    // 先持久化 deleting 状态，失败后启动 reconcile 会重试删除。
    final deleting = entry.copyWith(
      status: CacheEntryStatus.deleting,
      updatedAtMs: _now(),
    );
    _entries[entry.key] = deleting;
    await _persistState(entry.key);
    try {
      await store.deleteEntryDir(entry.contentKeyHash, entry.revisionKeyHash);
    } catch (_) {
      return DeleteResult.failed;
    }
    final size = entry.completeBytes + entry.partialBytes;
    _entries.remove(entry.key);
    _resources.remove(entry.key);
    _usedByDisk -= size;
    await _flushIndex();
    return DeleteResult.deleted;
  }

  int _pendingBytes() => _pending.values.fold(0, (sum, bytes) => sum + bytes);

  Future<void> _persistState(String entryKey) async {
    final entry = _entries[entryKey];
    if (entry == null) return;
    await store.saveState(
      RevisionState.fromEntry(
        entry,
        resources: _resources[entryKey] ?? const {},
      ),
    );
  }

  void _scheduleIndexSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveThrottle, () => unawaited(_flushIndex()));
  }

  Future<void> _flushIndex() async {
    if (_saving) return;
    _saving = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      await store.saveIndex(_entries.values.toList());
    } finally {
      _saving = false;
    }
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch;
