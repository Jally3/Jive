import 'dart:convert';
import 'dart:io';

const int cacheSchemaVersion = 1;

const String cacheIndexFileName = 'index.json';
const String cacheEntriesDirName = 'entries';
const String cacheStateFileName = 'state.json';
const String cacheResourcesDirName = 'resources';
const String cachePartialsDirName = 'partial';
const String cacheSourceManifestName = 'source_manifest.m3u8';
const String cacheProxyManifestName = 'proxy_manifest.m3u8';
const String cacheTimelineFileName = 'timeline.json';
const String cacheTempSuffix = '.tmp';

const Set<String> allowedResourceExts = {
  'ts',
  'm4s',
  'mp4',
  'mp3',
  'aac',
  'key',
  'm3u8',
  'bin',
};

final RegExp _resourceIdPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

bool isValidResourceId(String resourceId) =>
    _resourceIdPattern.hasMatch(resourceId);

bool isValidResourceExt(String ext) => allowedResourceExts.contains(ext);

enum CacheEntryStatus { partial, complete, deleting, failed }

enum CacheResourceType { segment, map, key, init, other }

enum CacheResourceStatus { partial, complete }

class CacheResourceRecord {
  const CacheResourceRecord({
    required this.resourceType,
    required this.status,
    required this.size,
    required this.ext,
    this.rangeStart,
    this.rangeEndExclusive,
    this.totalLength,
    this.etag,
    this.lastModified,
    this.lastAccessMs = 0,
  });

  final CacheResourceType resourceType;
  final CacheResourceStatus status;
  final int size;
  final String ext;
  final int? rangeStart;
  final int? rangeEndExclusive;
  final int? totalLength;
  final String? etag;
  final String? lastModified;
  final int lastAccessMs;

  bool get complete => status == CacheResourceStatus.complete;

  Map<String, dynamic> toJson() => {
    'resourceType': resourceType.name,
    'status': status.name,
    'size': size,
    'ext': ext,
    'rangeStart': rangeStart,
    'rangeEndExclusive': rangeEndExclusive,
    'totalLength': totalLength,
    'etag': etag,
    'lastModified': lastModified,
    'lastAccessMs': lastAccessMs,
  };

  factory CacheResourceRecord.fromJson(Map<String, dynamic> json) =>
      CacheResourceRecord(
        resourceType: _resourceType(json['resourceType']),
        status: _resourceStatus(json['status']),
        size: _nonNegative(json['size']),
        ext: '${json['ext'] ?? ''}',
        rangeStart: _optionalNonNegative(json['rangeStart']),
        rangeEndExclusive: _optionalNonNegative(json['rangeEndExclusive']),
        totalLength: _optionalNonNegative(json['totalLength']),
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        lastAccessMs: _nonNegative(json['lastAccessMs']),
      );
}

class CacheEntry {
  const CacheEntry({
    required this.contentKeyVersion,
    required this.contentKeyHash,
    required this.revisionKeyHash,
    required this.manifestFingerprint,
    this.manifestBaseUrl = '',
    this.filterVersion = 0,
    this.timelineVersion = 0,
    required this.sourceId,
    required this.sourceVideoId,
    required this.title,
    required this.playbackLineIdentity,
    required this.playbackLineName,
    required this.episodeIdentity,
    required this.episodeId,
    required this.episodeName,
    this.status = CacheEntryStatus.partial,
    this.expectedResourceCount = 0,
    this.committedResourceCount = 0,
    this.completeBytes = 0,
    this.partialBytes = 0,
    this.offlinePlayable = false,
    this.finalizationRequired = false,
    this.lastAccessMs = 0,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.errorSummary,
  });

  final int contentKeyVersion;
  final String contentKeyHash;
  final String revisionKeyHash;
  final String manifestFingerprint;
  final String manifestBaseUrl;
  final int filterVersion;
  final int timelineVersion;
  final String sourceId;
  final String sourceVideoId;
  final String title;
  final String playbackLineIdentity;
  final String playbackLineName;
  final String episodeIdentity;
  final String episodeId;
  final String episodeName;
  final CacheEntryStatus status;
  final int expectedResourceCount;
  final int committedResourceCount;
  final int completeBytes;
  final int partialBytes;
  final bool offlinePlayable;
  final bool finalizationRequired;
  final int lastAccessMs;
  final int createdAtMs;
  final int updatedAtMs;
  final String? errorSummary;

  String get key => '$contentKeyHash|$revisionKeyHash';

  double get progress => expectedResourceCount <= 0
      ? 0
      : (committedResourceCount / expectedResourceCount).clamp(0, 1);

  Map<String, dynamic> toJson() => {
    'schemaVersion': cacheSchemaVersion,
    'contentKeyVersion': contentKeyVersion,
    'contentKeyHash': contentKeyHash,
    'revisionKeyHash': revisionKeyHash,
    'manifestFingerprint': manifestFingerprint,
    'manifestBaseUrl': manifestBaseUrl,
    'filterVersion': filterVersion,
    'timelineVersion': timelineVersion,
    'sourceId': sourceId,
    'sourceVideoId': sourceVideoId,
    'title': title,
    'playbackLineIdentity': playbackLineIdentity,
    'playbackLineName': playbackLineName,
    'episodeIdentity': episodeIdentity,
    'episodeId': episodeId,
    'episodeName': episodeName,
    'status': status.name,
    'expectedResourceCount': expectedResourceCount,
    'committedResourceCount': committedResourceCount,
    'completeBytes': completeBytes,
    'partialBytes': partialBytes,
    'offlinePlayable': offlinePlayable,
    'finalizationRequired': finalizationRequired,
    'lastAccessMs': lastAccessMs,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'errorSummary': errorSummary,
  };

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != cacheSchemaVersion) {
      throw const FormatException('不支持的缓存 schema 版本');
    }
    final entry = CacheEntry(
      contentKeyVersion: _asInt(json['contentKeyVersion']),
      contentKeyHash: _requiredString(json['contentKeyHash']),
      revisionKeyHash: _requiredString(json['revisionKeyHash']),
      manifestFingerprint: _requiredString(json['manifestFingerprint']),
      manifestBaseUrl: _optionalString(json['manifestBaseUrl']),
      filterVersion: _asInt(json['filterVersion']),
      timelineVersion: _asInt(json['timelineVersion']),
      sourceId: _requiredString(json['sourceId']),
      sourceVideoId: _requiredString(json['sourceVideoId']),
      title: _optionalString(json['title']),
      playbackLineIdentity: _requiredString(json['playbackLineIdentity']),
      playbackLineName: _optionalString(json['playbackLineName']),
      episodeIdentity: _requiredString(json['episodeIdentity']),
      episodeId: _optionalString(json['episodeId']),
      episodeName: _optionalString(json['episodeName']),
      status: _entryStatus(json['status']),
      expectedResourceCount: _nonNegative(json['expectedResourceCount']),
      committedResourceCount: _nonNegative(json['committedResourceCount']),
      completeBytes: _nonNegative(json['completeBytes']),
      partialBytes: _nonNegative(json['partialBytes']),
      offlinePlayable: json['offlinePlayable'] == true,
      finalizationRequired: json['finalizationRequired'] == true,
      lastAccessMs: _nonNegative(json['lastAccessMs']),
      createdAtMs: _nonNegative(json['createdAtMs']),
      updatedAtMs: _nonNegative(json['updatedAtMs']),
      errorSummary: json['errorSummary'] as String?,
    );
    if (entry.committedResourceCount > entry.expectedResourceCount) {
      throw const FormatException('缓存计数不一致');
    }
    return entry;
  }

  CacheEntry copyWith({
    String? manifestBaseUrl,
    int? filterVersion,
    int? timelineVersion,
    CacheEntryStatus? status,
    int? expectedResourceCount,
    int? committedResourceCount,
    int? completeBytes,
    int? partialBytes,
    bool? offlinePlayable,
    bool? finalizationRequired,
    int? lastAccessMs,
    int? createdAtMs,
    int? updatedAtMs,
    String? errorSummary,
  }) => CacheEntry(
    contentKeyVersion: contentKeyVersion,
    contentKeyHash: contentKeyHash,
    revisionKeyHash: revisionKeyHash,
    manifestFingerprint: manifestFingerprint,
    manifestBaseUrl: manifestBaseUrl ?? this.manifestBaseUrl,
    filterVersion: filterVersion ?? this.filterVersion,
    timelineVersion: timelineVersion ?? this.timelineVersion,
    sourceId: sourceId,
    sourceVideoId: sourceVideoId,
    title: title,
    playbackLineIdentity: playbackLineIdentity,
    playbackLineName: playbackLineName,
    episodeIdentity: episodeIdentity,
    episodeId: episodeId,
    episodeName: episodeName,
    status: status ?? this.status,
    expectedResourceCount: expectedResourceCount ?? this.expectedResourceCount,
    committedResourceCount:
        committedResourceCount ?? this.committedResourceCount,
    completeBytes: completeBytes ?? this.completeBytes,
    partialBytes: partialBytes ?? this.partialBytes,
    offlinePlayable: offlinePlayable ?? this.offlinePlayable,
    finalizationRequired: finalizationRequired ?? this.finalizationRequired,
    lastAccessMs: lastAccessMs ?? this.lastAccessMs,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    errorSummary: errorSummary ?? this.errorSummary,
  );
}

class RevisionState extends CacheEntry {
  const RevisionState({
    required super.contentKeyVersion,
    required super.contentKeyHash,
    required super.revisionKeyHash,
    required super.manifestFingerprint,
    super.manifestBaseUrl,
    super.filterVersion,
    super.timelineVersion,
    required super.sourceId,
    required super.sourceVideoId,
    required super.title,
    required super.playbackLineIdentity,
    required super.playbackLineName,
    required super.episodeIdentity,
    required super.episodeId,
    required super.episodeName,
    super.status,
    super.expectedResourceCount,
    super.committedResourceCount,
    super.completeBytes,
    super.partialBytes,
    super.offlinePlayable,
    super.finalizationRequired,
    super.lastAccessMs,
    super.createdAtMs,
    super.updatedAtMs,
    super.errorSummary,
    this.resources = const {},
  });

  final Map<String, CacheResourceRecord> resources;

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'resources': resources.map((id, record) => MapEntry(id, record.toJson())),
  };

  factory RevisionState.fromEntry(
    CacheEntry entry, {
    Map<String, CacheResourceRecord> resources = const {},
  }) => RevisionState(
    contentKeyVersion: entry.contentKeyVersion,
    contentKeyHash: entry.contentKeyHash,
    revisionKeyHash: entry.revisionKeyHash,
    manifestFingerprint: entry.manifestFingerprint,
    manifestBaseUrl: entry.manifestBaseUrl,
    filterVersion: entry.filterVersion,
    timelineVersion: entry.timelineVersion,
    sourceId: entry.sourceId,
    sourceVideoId: entry.sourceVideoId,
    title: entry.title,
    playbackLineIdentity: entry.playbackLineIdentity,
    playbackLineName: entry.playbackLineName,
    episodeIdentity: entry.episodeIdentity,
    episodeId: entry.episodeId,
    episodeName: entry.episodeName,
    status: entry.status,
    expectedResourceCount: entry.expectedResourceCount,
    committedResourceCount: entry.committedResourceCount,
    completeBytes: entry.completeBytes,
    partialBytes: entry.partialBytes,
    offlinePlayable: entry.offlinePlayable,
    finalizationRequired: entry.finalizationRequired,
    lastAccessMs: entry.lastAccessMs,
    createdAtMs: entry.createdAtMs,
    updatedAtMs: entry.updatedAtMs,
    errorSummary: entry.errorSummary,
    resources: resources,
  );

  factory RevisionState.fromJson(Map<String, dynamic> json) {
    final entry = CacheEntry.fromJson(json);
    final rawResources = json['resources'];
    final resources = <String, CacheResourceRecord>{};
    if (rawResources is Map) {
      for (final resourceEntry in rawResources.entries) {
        final value = resourceEntry.value;
        if (value is Map) {
          final id = resourceEntry.key.toString();
          if (isValidResourceId(id)) {
            try {
              resources[id] = CacheResourceRecord.fromJson(
                Map<String, dynamic>.from(value),
              );
            } catch (_) {}
          }
        }
      }
    }
    return RevisionState(
      contentKeyVersion: entry.contentKeyVersion,
      contentKeyHash: entry.contentKeyHash,
      revisionKeyHash: entry.revisionKeyHash,
      manifestFingerprint: entry.manifestFingerprint,
      manifestBaseUrl: entry.manifestBaseUrl,
      filterVersion: entry.filterVersion,
      timelineVersion: entry.timelineVersion,
      sourceId: entry.sourceId,
      sourceVideoId: entry.sourceVideoId,
      title: entry.title,
      playbackLineIdentity: entry.playbackLineIdentity,
      playbackLineName: entry.playbackLineName,
      episodeIdentity: entry.episodeIdentity,
      episodeId: entry.episodeId,
      episodeName: entry.episodeName,
      status: entry.status,
      expectedResourceCount: entry.expectedResourceCount,
      committedResourceCount: entry.committedResourceCount,
      completeBytes: entry.completeBytes,
      partialBytes: entry.partialBytes,
      offlinePlayable: entry.offlinePlayable,
      finalizationRequired: entry.finalizationRequired,
      lastAccessMs: entry.lastAccessMs,
      createdAtMs: entry.createdAtMs,
      updatedAtMs: entry.updatedAtMs,
      errorSummary: entry.errorSummary,
      resources: resources,
    );
  }
}

class CacheStats {
  const CacheStats({
    required this.completeBytes,
    required this.partialBytes,
    required this.reservedBytes,
    required this.quotaBytes,
    required this.entries,
  });

  final int completeBytes;
  final int partialBytes;
  final int reservedBytes;
  final int quotaBytes;
  final List<CacheEntry> entries;

  int get entryCount => entries.length;
  int get usedBytes => completeBytes + partialBytes;
}

class CacheIndexStore {
  CacheIndexStore(this.root);

  final Directory root;

  File get indexFile => File('${root.path}/$cacheIndexFileName');

  Directory entriesDir() => Directory('${root.path}/$cacheEntriesDirName');

  Directory entryDir(String contentKeyHash, String revisionKeyHash) =>
      Directory(
        '${root.path}/$cacheEntriesDirName/$contentKeyHash/$revisionKeyHash',
      );

  File stateFile(String contentKeyHash, String revisionKeyHash) => File(
    '${entryDir(contentKeyHash, revisionKeyHash).path}/$cacheStateFileName',
  );

  Directory resourcesDir(
    String contentKeyHash,
    String revisionKeyHash,
  ) => Directory(
    '${entryDir(contentKeyHash, revisionKeyHash).path}/$cacheResourcesDirName',
  );

  Directory partialsDir(
    String contentKeyHash,
    String revisionKeyHash,
  ) => Directory(
    '${entryDir(contentKeyHash, revisionKeyHash).path}/$cachePartialsDirName',
  );

  File resourceFile(
    String contentKeyHash,
    String revisionKeyHash,
    String resourceId,
    String ext,
  ) {
    if (!isValidResourceId(resourceId)) {
      throw ArgumentError.value(resourceId, 'resourceId', '非法资源 ID');
    }
    if (!isValidResourceExt(ext)) {
      throw ArgumentError.value(ext, 'ext', '非法资源扩展名');
    }
    return File(
      '${resourcesDir(contentKeyHash, revisionKeyHash).path}/$resourceId.$ext',
    );
  }

  File partialFile(
    String contentKeyHash,
    String revisionKeyHash,
    String resourceId,
  ) {
    if (!isValidResourceId(resourceId)) {
      throw ArgumentError.value(resourceId, 'resourceId', '非法资源 ID');
    }
    return File(
      '${partialsDir(contentKeyHash, revisionKeyHash).path}/$resourceId.part',
    );
  }

  Future<List<CacheEntry>> loadIndex() async {
    try {
      final raw = await indexFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['entries'] is! List) return [];
      if (decoded['schemaVersion'] != cacheSchemaVersion) return [];
      final entries = <CacheEntry>[];
      for (final item in (decoded['entries'] as List)) {
        if (item is! Map) continue;
        try {
          entries.add(CacheEntry.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {}
      }
      return entries;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveIndex(List<CacheEntry> entries) =>
      writeJsonAtomic(indexFile, {
        'schemaVersion': cacheSchemaVersion,
        'generatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'entries': entries.map((e) => e.toJson()).toList(),
      });

  Future<void> saveState(RevisionState state) => writeJsonAtomic(
    stateFile(state.contentKeyHash, state.revisionKeyHash),
    state.toJson(),
  );

  File proxyManifestFile(String contentKeyHash, String revisionKeyHash) => File(
    '${entryDir(contentKeyHash, revisionKeyHash).path}/$cacheProxyManifestName',
  );

  File sourceManifestFile(
    String contentKeyHash,
    String revisionKeyHash,
  ) => File(
    '${entryDir(contentKeyHash, revisionKeyHash).path}/$cacheSourceManifestName',
  );

  Future<void> saveSourceManifest(
    String contentKeyHash,
    String revisionKeyHash,
    String raw,
  ) async {
    final file = sourceManifestFile(contentKeyHash, revisionKeyHash);
    await file.parent.create(recursive: true);
    await file.writeAsString(raw, flush: true);
  }

  Future<String?> loadSourceManifest(
    String contentKeyHash,
    String revisionKeyHash,
  ) async {
    final file = sourceManifestFile(contentKeyHash, revisionKeyHash);
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProxyManifest(
    String contentKeyHash,
    String revisionKeyHash,
    String raw,
  ) async {
    final file = proxyManifestFile(contentKeyHash, revisionKeyHash);
    await file.parent.create(recursive: true);
    await file.writeAsString(raw, flush: true);
  }

  Future<String?> loadProxyManifest(
    String contentKeyHash,
    String revisionKeyHash,
  ) async {
    final file = proxyManifestFile(contentKeyHash, revisionKeyHash);
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<List<RevisionState>> rebuildFromStates() async {
    final states = <RevisionState>[];
    final entriesRoot = entriesDir();
    if (!await entriesRoot.exists()) return states;
    await for (final entity in entriesRoot.list(recursive: true)) {
      if (entity is! File ||
          entity.path.split(Platform.pathSeparator).last !=
              cacheStateFileName) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          states.add(
            RevisionState.fromJson(Map<String, dynamic>.from(decoded)),
          );
        }
      } catch (_) {}
    }
    return states;
  }

  Future<void> deleteEntryDir(
    String contentKeyHash,
    String revisionKeyHash,
  ) async {
    final dir = entryDir(contentKeyHash, revisionKeyHash);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> cleanupTempFiles() async {
    final rootTemp = File('${root.path}/$cacheIndexFileName$cacheTempSuffix');
    if (await rootTemp.exists()) {
      try {
        await rootTemp.delete();
      } catch (_) {}
    }
    final entriesRoot = entriesDir();
    if (!await entriesRoot.exists()) return;
    await for (final entity in entriesRoot.list(recursive: true)) {
      if (entity is File && entity.path.endsWith(cacheTempSuffix)) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}

Future<void> writeJsonAtomic(File target, Map<String, dynamic> json) async {
  await target.parent.create(recursive: true);
  final temp = File('${target.path}$cacheTempSuffix');
  await temp.writeAsString(jsonEncode(json), flush: true);
  try {
    await temp.rename(target.path);
  } catch (_) {
    if (await temp.exists()) {
      try {
        await temp.delete();
      } catch (_) {}
    }
    rethrow;
  }
}

CacheEntryStatus _entryStatus(Object? value) {
  for (final status in CacheEntryStatus.values) {
    if (status.name == value) return status;
  }
  throw const FormatException('未知缓存条目状态');
}

CacheResourceType _resourceType(Object? value) {
  for (final type in CacheResourceType.values) {
    if (type.name == value) return type;
  }
  throw const FormatException('未知资源类型');
}

CacheResourceStatus _resourceStatus(Object? value) {
  for (final status in CacheResourceStatus.values) {
    if (status.name == value) return status;
  }
  throw const FormatException('未知资源状态');
}

int _asInt(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

int _nonNegative(Object? value) {
  final parsed = _asInt(value);
  if (parsed < 0) throw const FormatException('字段不能为负');
  return parsed;
}

int? _optionalNonNegative(Object? value) {
  if (value == null) return null;
  final parsed = _asInt(value);
  if (parsed < 0) throw const FormatException('字段不能为负');
  return parsed;
}

String _requiredString(Object? value) {
  final parsed = '${value ?? ''}';
  if (parsed.isEmpty) throw const FormatException('缺少必填字符串字段');
  return parsed;
}

String _optionalString(Object? value) => '${value ?? ''}';
