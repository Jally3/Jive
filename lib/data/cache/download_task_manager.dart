import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../domain/playback_selection.dart';
import '../../domain/playback_source.dart';
import '../../domain/video.dart';
import 'ad_filter.dart';
import 'cache_index.dart';
import 'cache_io.dart';
import 'cache_manager.dart';
import 'content_key.dart';
import 'hls_parser.dart';
import 'playback_url_resolver.dart';
import 'url_normalizer.dart';

const String downloadTaskFileName = 'download_tasks.json';
const int downloadFilterVersion = 1;

enum DownloadTaskStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

enum DownloadFailureReason {
  invalidSelection,
  unsupportedFormat,
  manifestRequestFailed,
  unsupportedHls,
  liveStream,
  encryptedStream,
  quotaExceeded,
  network,
  cacheWriteFailed,
  filterFailed,
  cancelled,
}

class DownloadTask {
  const DownloadTask({
    required this.taskId,
    required this.sourceId,
    required this.sourceVideoId,
    required this.title,
    required this.playbackLineIdentity,
    required this.episodeIdentity,
    required this.episodeId,
    required this.episodeName,
    required this.status,
    this.playbackUrl = '',
    this.mediaPlaylistUrl = '',
    this.contentKeyHash,
    this.revisionKeyHash,
    this.expectedResourceCount = 0,
    this.completedResourceCount = 0,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.speedBytesPerSecond = 0,
    this.filterVersion = downloadFilterVersion,
    this.filterConfidence,
    this.error,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  final String taskId;
  final String sourceId;
  final String sourceVideoId;
  final String title;
  final String playbackLineIdentity;
  final String episodeIdentity;
  final String episodeId;
  final String episodeName;
  final DownloadTaskStatus status;
  final String playbackUrl;
  final String mediaPlaylistUrl;
  final String? contentKeyHash;
  final String? revisionKeyHash;
  final int expectedResourceCount;
  final int completedResourceCount;
  final int totalBytes;
  final int downloadedBytes;
  final int speedBytesPerSecond;
  final int filterVersion;
  final double? filterConfidence;
  final DownloadFailureReason? error;
  final int createdAtMs;
  final int updatedAtMs;

  double get progress => expectedResourceCount <= 0
      ? 0
      : (completedResourceCount / expectedResourceCount).clamp(0, 1);

  DownloadTask copyWith({
    DownloadTaskStatus? status,
    String? contentKeyHash,
    String? revisionKeyHash,
    int? expectedResourceCount,
    int? completedResourceCount,
    int? totalBytes,
    int? downloadedBytes,
    int? speedBytesPerSecond,
    int? filterVersion,
    double? filterConfidence,
    DownloadFailureReason? error,
    bool clearError = false,
    int? createdAtMs,
    int? updatedAtMs,
    String? playbackUrl,
    String? mediaPlaylistUrl,
  }) => DownloadTask(
    taskId: taskId,
    sourceId: sourceId,
    sourceVideoId: sourceVideoId,
    title: title,
    playbackLineIdentity: playbackLineIdentity,
    episodeIdentity: episodeIdentity,
    episodeId: episodeId,
    episodeName: episodeName,
    status: status ?? this.status,
    playbackUrl: playbackUrl ?? this.playbackUrl,
    mediaPlaylistUrl: mediaPlaylistUrl ?? this.mediaPlaylistUrl,
    contentKeyHash: contentKeyHash ?? this.contentKeyHash,
    revisionKeyHash: revisionKeyHash ?? this.revisionKeyHash,
    expectedResourceCount: expectedResourceCount ?? this.expectedResourceCount,
    completedResourceCount:
        completedResourceCount ?? this.completedResourceCount,
    totalBytes: totalBytes ?? this.totalBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    filterVersion: filterVersion ?? this.filterVersion,
    filterConfidence: filterConfidence ?? this.filterConfidence,
    error: clearError ? null : (error ?? this.error),
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'taskId': taskId,
    'sourceId': sourceId,
    'sourceVideoId': sourceVideoId,
    'title': title,
    'playbackLineIdentity': playbackLineIdentity,
    'episodeIdentity': episodeIdentity,
    'episodeId': episodeId,
    'episodeName': episodeName,
    'status': status.name,
    'playbackUrl': playbackUrl,
    'mediaPlaylistUrl': mediaPlaylistUrl,
    'contentKeyHash': contentKeyHash,
    'revisionKeyHash': revisionKeyHash,
    'expectedResourceCount': expectedResourceCount,
    'completedResourceCount': completedResourceCount,
    'totalBytes': totalBytes,
    'downloadedBytes': downloadedBytes,
    'speedBytesPerSecond': speedBytesPerSecond,
    'filterVersion': filterVersion,
    'filterConfidence': filterConfidence,
    'error': error?.name,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('不支持的下载任务 schema 版本');
    }
    return DownloadTask(
      taskId: _required(json['taskId']),
      sourceId: _required(json['sourceId']),
      sourceVideoId: _required(json['sourceVideoId']),
      title: '${json['title'] ?? ''}',
      playbackLineIdentity: _required(json['playbackLineIdentity']),
      episodeIdentity: _required(json['episodeIdentity']),
      episodeId: '${json['episodeId'] ?? ''}',
      episodeName: '${json['episodeName'] ?? ''}',
      status: _taskStatus(json['status']),
      playbackUrl: '${json['playbackUrl'] ?? ''}',
      mediaPlaylistUrl: '${json['mediaPlaylistUrl'] ?? ''}',
      contentKeyHash: json['contentKeyHash'] as String?,
      revisionKeyHash: json['revisionKeyHash'] as String?,
      expectedResourceCount: _nonNegative(json['expectedResourceCount']),
      completedResourceCount: _nonNegative(json['completedResourceCount']),
      totalBytes: _nonNegative(json['totalBytes']),
      downloadedBytes: _nonNegative(json['downloadedBytes']),
      speedBytesPerSecond: _nonNegative(json['speedBytesPerSecond']),
      filterVersion: _nonNegative(json['filterVersion']),
      filterConfidence: (json['filterConfidence'] as num?)?.toDouble(),
      error: _failure(json['error']),
      createdAtMs: _nonNegative(json['createdAtMs']),
      updatedAtMs: _nonNegative(json['updatedAtMs']),
    );
  }
}

typedef DownloadSelectionResolver =
    Future<PlaybackSelection?> Function(DownloadTask task);

class DownloadTaskManager {
  DownloadTaskManager({
    required this.store,
    required this.cacheManager,
    required this.client,
    required this.resolveSelection,
    this.concurrency = 5,
  }) : assert(concurrency > 0),
       _permits = _DownloadPermitPool(concurrency),
       _urlResolver = PlaybackUrlResolver(client: client);

  final CacheIndexStore store;
  final CacheManager cacheManager;
  final http.Client client;
  final DownloadSelectionResolver resolveSelection;
  final int concurrency;
  final _DownloadPermitPool _permits;
  final PlaybackUrlResolver _urlResolver;
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, Future<void>> _running = {};
  final Map<String, PlaybackSelection?> _pendingSelections = {};
  final Set<String> _pauseRequested = {};
  final Set<String> _cancelRequested = {};
  final Set<String> _lifecyclePaused = {};
  final Map<String, Map<String, int>> _resourceLengths = {};
  final Map<String, List<({int atMs, int bytes})>> _speedSamples = {};
  final Map<String, Timer> _speedTimers = {};
  Future<void> _persistTail = Future<void>.value();
  final StreamController<List<DownloadTask>> _changes =
      StreamController<List<DownloadTask>>.broadcast();

  Stream<List<DownloadTask>> get changes => _changes.stream;

  List<DownloadTask> get tasks => List.unmodifiable(
    _tasks.values.toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs)),
  );

  Future<void> initialize() async {
    var changed = false;
    try {
      final file = File('${store.root.path}/$downloadTaskFileName');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['tasks'] is List) {
          for (final item in decoded['tasks'] as List) {
            if (item is! Map) continue;
            try {
              final task = DownloadTask.fromJson(
                Map<String, dynamic>.from(item),
              );
              final restored = task.status == DownloadTaskStatus.downloading
                  ? task.copyWith(status: DownloadTaskStatus.queued)
                  : task;
              changed = changed || restored.status != task.status;
              _tasks[restored.taskId] = restored;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    for (final task in _tasks.values.toList()) {
      final contentHash = task.contentKeyHash;
      final revisionHash = task.revisionKeyHash;
      final entry = contentHash == null || revisionHash == null
          ? null
          : await cacheManager.getEntry('$contentHash|$revisionHash');
      if (entry?.offlinePlayable == true &&
          task.status == DownloadTaskStatus.completed) {
        final restored = task.copyWith(
          status: DownloadTaskStatus.completed,
          expectedResourceCount: entry!.expectedResourceCount,
          completedResourceCount: entry.committedResourceCount,
          downloadedBytes: entry.completeBytes,
          totalBytes: entry.completeBytes,
          filterVersion: entry.filterVersion,
          speedBytesPerSecond: 0,
          clearError: true,
        );
        changed =
            changed ||
            restored.status != task.status ||
            restored.completedResourceCount != task.completedResourceCount ||
            restored.downloadedBytes != task.downloadedBytes ||
            restored.filterVersion != task.filterVersion;
        _tasks[task.taskId] = restored;
      } else if (task.status == DownloadTaskStatus.completed) {
        _tasks[task.taskId] = task.copyWith(
          status: DownloadTaskStatus.paused,
          expectedResourceCount: entry?.expectedResourceCount ?? 0,
          completedResourceCount: entry?.committedResourceCount ?? 0,
          downloadedBytes:
              (entry?.completeBytes ?? 0) + (entry?.partialBytes ?? 0),
          totalBytes: 0,
          speedBytesPerSecond: 0,
          error: DownloadFailureReason.cacheWriteFailed,
        );
        changed = true;
      } else if (entry?.offlinePlayable == true) {
        await cacheManager.setExpectations(
          entry!.key,
          entry.expectedResourceCount,
          requireFinalization: true,
        );
      }
    }
    if (changed) await _persist();
    _emit();
    _pumpQueue();
  }

  Future<DownloadTask> enqueue(PlaybackSelection selection) async {
    if (!selection.hasStableIdentity) {
      throw const FormatException('缺少稳定的线路或剧集标识');
    }
    selection = await _urlResolver.resolveSelection(selection);
    if (selection.playbackSource.format != PlaybackFormat.hls) {
      throw FormatException(
        '仅支持 HLS VOD 下载，当前格式：${playbackFormatLabel(selection.playbackSource.format)}',
      );
    }
    final contentKey = _contentKey(selection);
    for (final task in _tasks.values) {
      if (task.contentKeyHash == contentKey.hash &&
          task.episodeIdentity == selection.episodeIdentity) {
        if (task.status == DownloadTaskStatus.paused ||
            task.status == DownloadTaskStatus.failed) {
          await resume(task.taskId);
          return _tasks[task.taskId]!;
        }
        if (task.status != DownloadTaskStatus.cancelled) return task;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = DownloadTask(
      taskId: '${contentKey.hash}:$now:${Random().nextInt(1 << 20)}',
      sourceId: selection.sourceId,
      sourceVideoId: selection.sourceVideoId,
      title: selection.title,
      playbackLineIdentity: selection.playbackLineIdentity,
      episodeIdentity: selection.episodeIdentity,
      episodeId: selection.episode.id,
      episodeName: selection.episode.name,
      status: DownloadTaskStatus.queued,
      playbackUrl: selection.playbackSource.url.toString(),
      contentKeyHash: contentKey.hash,
      createdAtMs: now,
      updatedAtMs: now,
    );
    _tasks[task.taskId] = task;
    await _persist();
    _emit();
    _pendingSelections[task.taskId] = selection;
    _pumpQueue();
    return task;
  }

  Future<void> pause(String taskId) async {
    _pauseRequested.add(taskId);
    final task = _tasks[taskId];
    if (task != null && task.status == DownloadTaskStatus.queued) {
      await _set(task.copyWith(status: DownloadTaskStatus.paused));
    }
  }

  Future<void> resume(String taskId) async {
    _pauseRequested.remove(taskId);
    _cancelRequested.remove(taskId);
    final task = _tasks[taskId];
    if (task == null || task.status == DownloadTaskStatus.completed) return;
    if (_running.containsKey(taskId)) return;
    await _set(
      task.copyWith(status: DownloadTaskStatus.queued, clearError: true),
    );
    _pendingSelections[taskId] = null;
    _pumpQueue();
  }

  Future<void> cancel(String taskId) async {
    _cancelRequested.add(taskId);
    _pauseRequested.remove(taskId);
    final task = _tasks[taskId];
    if (task != null) {
      await _set(
        task.copyWith(
          status: DownloadTaskStatus.cancelled,
          error: DownloadFailureReason.cancelled,
        ),
      );
    }
  }

  /// Removes the task record while keeping its cache entry by default.
  /// Set [deleteCache] when the user explicitly wants to remove both.
  Future<void> removeTask(String taskId, {bool deleteCache = false}) async {
    final task = _tasks[taskId];
    if (task == null) return;
    if (task.status == DownloadTaskStatus.queued ||
        task.status == DownloadTaskStatus.downloading) {
      await cancel(taskId);
      final running = _running[taskId];
      if (running != null) await running;
    }
    final latest = _tasks[taskId] ?? task;
    if (deleteCache &&
        latest.contentKeyHash != null &&
        latest.revisionKeyHash != null) {
      await cacheManager.deleteEntry(
        '${latest.contentKeyHash}|${latest.revisionKeyHash}',
      );
    }
    _tasks.remove(taskId);
    _pendingSelections.remove(taskId);
    _pauseRequested.remove(taskId);
    _cancelRequested.remove(taskId);
    await _persist();
    _emit();
  }

  Future<void> clearFinishedTasks() async {
    final ids = tasks
        .where(
          (task) =>
              task.status == DownloadTaskStatus.completed ||
              task.status == DownloadTaskStatus.cancelled,
        )
        .map((task) => task.taskId)
        .toList();
    for (final id in ids) {
      await removeTask(id);
    }
  }

  /// Restores a task's selection without a network request when the manifest
  /// URL was persisted. Older tasks fall back to the repository resolver.
  Future<PlaybackSelection?> selectionForTask(DownloadTask task) async {
    final url = Uri.tryParse(task.playbackUrl);
    if (url != null && url.isAbsolute && task.playbackUrl.isNotEmpty) {
      return _selectionFromUrl(task, url);
    }
    // Tasks created before playbackUrl was persisted can still be played
    // offline by using the manifest URL stored in the completed cache entry.
    final contentKeyHash = task.contentKeyHash;
    if (contentKeyHash != null && contentKeyHash.isNotEmpty) {
      final entry = await cacheManager.findOffline(contentKeyHash, '');
      final cachedUrl = Uri.tryParse(entry?.manifestBaseUrl ?? '');
      if (cachedUrl != null && cachedUrl.isAbsolute) {
        return _selectionFromUrl(task, cachedUrl);
      }
    }
    return resolveSelection(task);
  }

  PlaybackSelection _selectionFromUrl(DownloadTask task, Uri url) {
    final urlText = url.toString();
    final episode = Episode(
      id: task.episodeId,
      name: task.episodeName,
      url: urlText,
      identity: task.episodeIdentity,
    );
    return PlaybackSelection(
      sourceId: task.sourceId,
      sourceVideoId: task.sourceVideoId,
      title: task.title,
      playbackLineIdentity: task.playbackLineIdentity,
      episodeIdentity: task.episodeIdentity,
      episode: episode,
      playbackSource: PlaybackSource(
        url: url,
        format: inferPlaybackFormat(url.toString()),
      ),
    );
  }

  Future<void> retry(String taskId) => resume(taskId);

  Future<void> pauseAll() async {
    for (final task in tasks) {
      if (task.status == DownloadTaskStatus.queued ||
          task.status == DownloadTaskStatus.downloading) {
        await pause(task.taskId);
      }
    }
  }

  Future<void> pauseForBackground() async {
    for (final task in tasks) {
      if (task.status == DownloadTaskStatus.queued ||
          task.status == DownloadTaskStatus.downloading) {
        _lifecyclePaused.add(task.taskId);
        await pause(task.taskId);
      }
    }
  }

  Future<void> resumeFromForeground() async {
    final taskIds = _lifecyclePaused.toList();
    _lifecyclePaused.clear();
    for (final taskId in taskIds) {
      await resume(taskId);
    }
  }

  Future<void> dispose() async {
    await pauseAll();
    if (_running.isNotEmpty) {
      await Future.wait(_running.values.toList());
    }
    await _persist();
    await _changes.close();
  }

  void _pumpQueue() {
    if (_changes.isClosed) return;
    final queued = tasks.where(
      (task) =>
          task.status == DownloadTaskStatus.queued &&
          !_running.containsKey(task.taskId),
    );
    for (final task in queued) {
      if (_running.length >= concurrency) break;
      final initial = _pendingSelections.remove(task.taskId);
      _running[task.taskId] = _run(task.taskId, initial).whenComplete(() {
        _running.remove(task.taskId);
        _pumpQueue();
      });
    }
  }

  Future<void> _run(String taskId, PlaybackSelection? initial) async {
    var task = _tasks[taskId];
    if (task == null) return;
    CacheRef? ref;
    try {
      if (_cancelRequested.contains(taskId)) return;
      task = await _set(task.copyWith(status: DownloadTaskStatus.downloading));
      _resourceLengths[taskId] = {};
      var selection = initial ?? await selectionForTask(task);
      if (selection == null || !selection.hasStableIdentity) {
        throw const _DownloadException(DownloadFailureReason.invalidSelection);
      }
      if (selection.playbackSource.format == PlaybackFormat.unknown) {
        selection = await _urlResolver.resolveSelection(selection);
      }
      // 统一下载策略：解析时即过滤广告（与在线播放共用同一过滤逻辑和
      // revision），只下载正片分片；广告分片不下载、不占缓存。
      final parser = HlsParser(
        client: client,
        adFilter: const AdFilter(enabled: true),
      );
      HlsDecision decision;
      final savedManifest =
          task.contentKeyHash == null || task.revisionKeyHash == null
          ? null
          : await store.loadSourceManifest(
              task.contentKeyHash!,
              task.revisionKeyHash!,
            );
      final savedBase = Uri.tryParse(task.mediaPlaylistUrl);
      if (savedManifest != null &&
          savedManifest.isNotEmpty &&
          savedBase != null &&
          savedBase.isAbsolute) {
        decision = parser.decideMedia(savedManifest, savedBase);
      } else {
        decision = await parser.resolve(selection.playbackSource);
      }
      if (!decision.isCacheable || decision.mediaPlaylist == null) {
        throw _DownloadException(_reasonForManifest(decision.reason));
      }
      final playlist = decision.mediaPlaylist!;
      final sourcePlaylist = decision.sourcePlaylist ?? playlist;
      final plan = parser.buildProxyPlan(playlist, _proxyToken());
      if (plan.resources.isEmpty) {
        throw const _DownloadException(DownloadFailureReason.unsupportedHls);
      }
      final contentKey = _contentKey(selection);
      final fingerprint = sha256.convert(utf8.encode(playlist.raw)).toString();
      final revisionKeyHash = hlsRevisionKeyHash(playlist.baseUri, fingerprint);
      final mapping = playlist.timelineMapping;
      final filterVersion = mapping == null ? 0 : downloadFilterVersion;
      final timelineVersion = mapping == null ? 0 : adTimelineVersion;
      final entry = await cacheManager.upsertEntry(
        CacheEntry(
          contentKeyVersion: contentKey.version,
          contentKeyHash: contentKey.hash,
          revisionKeyHash: revisionKeyHash,
          manifestFingerprint: fingerprint,
          manifestBaseUrl: urlNormalizer.normalizeToString(
            selection.playbackSource.url,
          ),
          filterVersion: filterVersion,
          timelineVersion: timelineVersion,
          sourceId: selection.sourceId,
          sourceVideoId: selection.sourceVideoId,
          title: selection.title,
          playbackLineIdentity: selection.playbackLineIdentity,
          playbackLineName: '',
          episodeIdentity: selection.episodeIdentity,
          episodeId: selection.episode.id,
          episodeName: selection.episode.name,
        ),
      );
      await store.saveSourceManifest(
        contentKey.hash,
        revisionKeyHash,
        sourcePlaylist.raw,
      );
      await store.saveProxyManifest(
        contentKey.hash,
        revisionKeyHash,
        plan.proxyManifest,
      );
      if (mapping != null) {
        await _saveTimeline(
          contentKey.hash,
          revisionKeyHash,
          fingerprint,
          mapping,
          decision.filterConfidence,
        );
      }
      await cacheManager.setExpectations(
        entry.key,
        plan.expectedResourceCount,
        requireFinalization: true,
      );
      await cacheManager.markDownloadOrigin(entry.key);
      ref = await cacheManager.acquire(entry.key);
      task = await _set(
        task.copyWith(
          contentKeyHash: contentKey.hash,
          revisionKeyHash: revisionKeyHash,
          expectedResourceCount: plan.expectedResourceCount,
          filterVersion: filterVersion,
          mediaPlaylistUrl: playlist.baseUri.toString(),
        ),
      );
      final fetcher = ResourceFetcher(
        client: client,
        sessionHeaders: selection.playbackSource.headers,
        manager: cacheManager,
        store: store,
        entryKey: entry.key,
        contentKeyHash: contentKey.hash,
        revisionKeyHash: revisionKeyHash,
        onResourceLength: (resourceId, length) {
          _resourceLengths[taskId]?[resourceId] = length;
          _emit();
        },
        onBytesReceived: (bytes) => _recordBytes(taskId, bytes),
        failOnCacheUnavailable: true,
        encryptedSegments: playlist.hasEncryption,
      );
      final resources = plan.resources.entries.toList();
      var cursor = 0;
      Future<void> worker() async {
        while (true) {
          if (_shouldStop(taskId)) return;
          final index = cursor++;
          if (index >= resources.length) return;
          final resource = resources[index];
          final id = resource.key;
          final ext = plan.extByResourceId[id] ?? 'bin';
          final existing = await cacheManager.resourceRecord(entry.key, id);
          if (existing?.complete == true) {
            _resourceLengths[taskId]?[id] = existing!.size;
            await _updateProgress(taskId, entry.key, resources.length);
            continue;
          }
          final release = await _permits.acquire();
          try {
            if (_shouldStop(taskId)) return;
            final result = await fetcher.fetch(
              origin: resource.value,
              resourceId: id,
              ext: ext,
            );
            if (result.statusCode >= 400) {
              await result.body.drain<void>();
              throw const _DownloadException(DownloadFailureReason.network);
            }
            await result.body.drain<void>();
          } finally {
            release();
          }
          final saved = await cacheManager.resourceRecord(entry.key, id);
          if (saved?.complete != true) {
            throw const _DownloadException(
              DownloadFailureReason.cacheWriteFailed,
            );
          }
          await _updateProgress(taskId, entry.key, resources.length);
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      if (_cancelRequested.contains(taskId)) return;
      if (_pauseRequested.contains(taskId)) {
        await _set(_tasks[taskId]!.copyWith(status: DownloadTaskStatus.paused));
        return;
      }

      // 过滤已在解析阶段完成，分片集合与在线播放一致，无需后置过滤步骤。
      final finalized = await cacheManager.finalizeEntry(entry.key);
      if (!finalized) {
        throw const _DownloadException(DownloadFailureReason.cacheWriteFailed);
      }
      final current = await cacheManager.getEntry(entry.key);
      if (current == null || !current.offlinePlayable) {
        throw const _DownloadException(DownloadFailureReason.cacheWriteFailed);
      }
      await _set(
        _tasks[taskId]!.copyWith(
          status: DownloadTaskStatus.completed,
          completedResourceCount: resources.length,
          expectedResourceCount: resources.length,
          downloadedBytes: current.completeBytes,
          totalBytes: current.completeBytes,
          filterVersion: filterVersion,
          filterConfidence: decision.filterConfidence,
          clearError: true,
          speedBytesPerSecond: 0,
        ),
      );
    } on CacheQuotaException {
      final current = _tasks[taskId];
      if (current != null && !_cancelRequested.contains(taskId)) {
        await _set(
          current.copyWith(
            status: DownloadTaskStatus.failed,
            error: DownloadFailureReason.quotaExceeded,
          ),
        );
      }
    } on CacheResourceValidationException {
      final current = _tasks[taskId];
      if (current != null && !_cancelRequested.contains(taskId)) {
        await _set(
          current.copyWith(
            status: DownloadTaskStatus.failed,
            error: DownloadFailureReason.encryptedStream,
          ),
        );
      }
    } on _DownloadException catch (error) {
      if (_pauseRequested.contains(taskId)) {
        await _set(_tasks[taskId]!.copyWith(status: DownloadTaskStatus.paused));
      } else if (!_cancelRequested.contains(taskId)) {
        final current = _tasks[taskId];
        if (current != null) {
          await _set(
            current.copyWith(
              status: DownloadTaskStatus.failed,
              error: error.reason,
            ),
          );
        }
      }
    } catch (_) {
      final current = _tasks[taskId];
      // 与 _DownloadException 分支一致：暂停请求优先于失败落账，
      // 避免暂停瞬间的在途分片报错把任务卡在 downloading。
      if (current != null && _pauseRequested.contains(taskId)) {
        await _set(current.copyWith(status: DownloadTaskStatus.paused));
      } else if (current != null && !_cancelRequested.contains(taskId)) {
        await _set(
          current.copyWith(
            status: DownloadTaskStatus.failed,
            error: DownloadFailureReason.network,
          ),
        );
      }
    } finally {
      _stopSpeedTimer(taskId);
      await ref?.dispose();
    }
  }

  bool _shouldStop(String taskId) =>
      _pauseRequested.contains(taskId) || _cancelRequested.contains(taskId);

  Future<void> _updateProgress(
    String taskId,
    String entryKey,
    int expected,
  ) async {
    final entry = await cacheManager.getEntry(entryKey);
    final task = _tasks[taskId];
    if (entry == null || task == null) return;
    final lengths = _resourceLengths[taskId] ?? const <String, int>{};
    final allLengthsKnown =
        lengths.length >= expected &&
        lengths.values.every((length) => length > 0);
    final knownTotal = allLengthsKnown
        ? lengths.values.fold<int>(0, (sum, value) => sum + value)
        : 0;
    await _set(
      task.copyWith(
        completedResourceCount: entry.committedResourceCount,
        expectedResourceCount: expected,
        downloadedBytes: entry.completeBytes + entry.partialBytes,
        totalBytes: knownTotal > 0 ? knownTotal : 0,
      ),
    );
  }

  void _recordBytes(String taskId, int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final samples = _speedSamples.putIfAbsent(taskId, () => []);
    samples.add((atMs: now, bytes: bytes));
    samples.removeWhere((sample) => now - sample.atMs > 3000);
    final task = _tasks[taskId];
    if (task != null) {
      _tasks[taskId] = task.copyWith(
        downloadedBytes: task.downloadedBytes + bytes,
      );
      _emit();
    }
    if (_speedTimers.containsKey(taskId)) return;
    _speedTimers[taskId] = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _flushSpeed(taskId),
    );
  }

  void _flushSpeed(String taskId) {
    final task = _tasks[taskId];
    final samples = _speedSamples[taskId];
    if (task == null || samples == null || samples.isEmpty) {
      _stopSpeedTimer(taskId);
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    samples.removeWhere((sample) => now - sample.atMs > 3000);
    if (samples.isEmpty) {
      _stopSpeedTimer(taskId);
      return;
    }
    final bytes = samples.fold<int>(0, (sum, sample) => sum + sample.bytes);
    final elapsedMs = max(1000, now - samples.first.atMs);
    _tasks[taskId] = task.copyWith(
      speedBytesPerSecond: (bytes * 1000 / elapsedMs).round(),
    );
    _emit();
  }

  void _stopSpeedTimer(String taskId) {
    _speedTimers.remove(taskId)?.cancel();
    _speedSamples.remove(taskId);
    final task = _tasks[taskId];
    if (task != null && task.speedBytesPerSecond != 0) {
      _tasks[taskId] = task.copyWith(speedBytesPerSecond: 0);
      _emit();
    }
  }

  Future<DownloadTask> _set(DownloadTask task) async {
    final updated = task.copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _tasks[task.taskId] = updated;
    await _persist();
    _emit();
    return updated;
  }

  Future<void> _persist() async {
    final next = _persistTail.then<void>((_) async {
      await writeJsonAtomic(File('${store.root.path}/$downloadTaskFileName'), {
        'schemaVersion': 1,
        'tasks': _tasks.values.map((task) => task.toJson()).toList(),
      });
    });
    _persistTail = next.catchError((_) {});
    await next;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(tasks);
  }

  Future<void> _saveTimeline(
    String contentKeyHash,
    String revisionKeyHash,
    String fingerprint,
    TimelineMapping? mapping,
    double? confidence,
  ) async {
    final file = File(
      '${store.entryDir(contentKeyHash, revisionKeyHash).path}/$cacheTimelineFileName',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'manifestFingerprint': fingerprint,
        'filterVersion': downloadFilterVersion,
        'timelineVersion': mapping == null ? 0 : adTimelineVersion,
        'confidence': confidence,
        'removedRanges': [
          for (final range in mapping?.ranges ?? const <RemovedRange>[])
            {'startMs': range.startMs, 'endMs': range.endMs},
        ],
      }),
      flush: true,
    );
  }

  static ContentKey _contentKey(PlaybackSelection selection) =>
      ContentKeyBuilder().build(
        ContentKeyParts(
          sourceId: selection.sourceId,
          sourceVideoId: selection.sourceVideoId,
          playbackLineIdentity: selection.playbackLineIdentity,
          episodeIdentity: selection.episodeIdentity,
        ),
      );

  static DownloadFailureReason _reasonForManifest(String? reason) {
    final text = reason ?? '';
    if (text.contains('直播')) return DownloadFailureReason.liveStream;
    if (text.contains('加密')) return DownloadFailureReason.encryptedStream;
    if (text.contains('标签') || text.contains('变体')) {
      return DownloadFailureReason.unsupportedHls;
    }
    if (text.contains('请求') || text.contains('HTTP')) {
      return DownloadFailureReason.manifestRequestFailed;
    }
    return DownloadFailureReason.unsupportedHls;
  }

  static String _proxyToken() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class _DownloadException implements Exception {
  const _DownloadException(this.reason);
  final DownloadFailureReason reason;
}

class _DownloadPermitPool {
  _DownloadPermitPool(int capacity) : _available = max(1, capacity);

  int _available;
  final List<Completer<void>> _waiters = [];

  Future<void Function()> acquire() async {
    if (_available > 0) {
      _available--;
    } else {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _available++;
      }
    };
  }
}

String _required(Object? value) {
  final parsed = '${value ?? ''}';
  if (parsed.isEmpty) throw const FormatException('下载任务缺少身份字段');
  return parsed;
}

int _nonNegative(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value') ?? 0;
  if (parsed < 0) throw const FormatException('下载任务字段不能为负');
  return parsed;
}

DownloadTaskStatus _taskStatus(Object? value) =>
    DownloadTaskStatus.values.firstWhere(
      (item) => item.name == value,
      orElse: () => throw const FormatException('未知下载任务状态'),
    );

DownloadFailureReason? _failure(Object? value) {
  if (value == null) return null;
  return DownloadFailureReason.values.firstWhere(
    (item) => item.name == value,
    orElse: () => throw const FormatException('未知下载失败原因'),
  );
}

String downloadFailureText(DownloadFailureReason? reason) => switch (reason) {
  DownloadFailureReason.invalidSelection => '播放信息不完整，无法下载',
  DownloadFailureReason.unsupportedFormat => '当前格式不支持下载',
  DownloadFailureReason.manifestRequestFailed => '视频清单获取失败，请重试',
  DownloadFailureReason.unsupportedHls => '视频清单包含不支持的内容',
  DownloadFailureReason.liveStream => '直播内容暂不支持下载',
  DownloadFailureReason.encryptedStream => '加密视频暂不支持下载',
  DownloadFailureReason.quotaExceeded => '存储空间不足',
  DownloadFailureReason.network => '网络请求失败，请重试',
  DownloadFailureReason.cacheWriteFailed => '缓存写入失败，请检查存储空间',
  DownloadFailureReason.filterFailed => '视频处理失败，请重试',
  DownloadFailureReason.cancelled => '任务已取消',
  null => '下载失败，请重试',
};
