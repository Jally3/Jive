import 'dart:convert';
import 'dart:io';

import 'cache_models.dart';

// 条目/资源记录模型独立成 cache_models.dart；此处 re-export 保持
// cache_manager / cache_io / download_task_manager 等引用方不变。
export 'cache_models.dart';

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

bool isValidResourceExt(String ext) => allowedResourceExts.contains(ext);

/// 启动清扫时对条目目录 state.json 的探测结论：
/// - missing / corrupt：目录为孤儿残留，可整体删除；
/// - unknownVersion：未来版本写入的目录，隔离保留，不删除；
/// - valid：当前版本可读的有效状态。
enum CacheStateProbe { missing, corrupt, unknownVersion, valid }

/// 缓存目录的磁盘布局与持久化 IO：index/state/manifest 文件的读写、
/// 启动重建与临时文件清理。
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

  /// 探测条目目录的 state.json 状态，供启动反向清扫区分
  /// "可删除的孤儿目录"与"需隔离保留的未知版本目录"。
  Future<CacheStateProbe> probeState(
    String contentKeyHash,
    String revisionKeyHash,
  ) async {
    final file = stateFile(contentKeyHash, revisionKeyHash);
    if (!await file.exists()) return CacheStateProbe.missing;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return CacheStateProbe.corrupt;
      if (decoded['schemaVersion'] != cacheSchemaVersion) {
        return CacheStateProbe.unknownVersion;
      }
      // 与 rebuildFromStates 同一载入口径：结构不完整同样视为损坏。
      RevisionState.fromJson(Map<String, dynamic>.from(decoded));
      return CacheStateProbe.valid;
    } catch (_) {
      return CacheStateProbe.corrupt;
    }
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
