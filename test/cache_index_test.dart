import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_index.dart';

CacheEntry entry({String title = '影片'}) => CacheEntry(
  contentKeyVersion: 1,
  contentKeyHash: 'ck',
  revisionKeyHash: 'rk',
  manifestFingerprint: 'fp',
  sourceId: 's',
  sourceVideoId: 'v',
  title: title,
  playbackLineIdentity: 'line',
  playbackLineName: '线路1',
  episodeIdentity: 'ep',
  episodeId: 'e',
  episodeName: '第1集',
  completeBytes: 100,
  partialBytes: 20,
  committedResourceCount: 1,
  expectedResourceCount: 2,
  lastAccessMs: 123,
);

void main() {
  late Directory tempDir;
  late CacheIndexStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jive_cache_index_test');
    store = CacheIndexStore(tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('cache entry json round trip preserves fields', () {
    final json = entry().toJson();
    final restored = CacheEntry.fromJson(json);
    expect(restored.key, entry().key);
    expect(restored.title, '影片');
    expect(restored.completeBytes, 100);
    expect(restored.partialBytes, 20);
    expect(restored.committedResourceCount, 1);
    expect(restored.expectedResourceCount, 2);
    expect(restored.progress, .5);
    expect(restored.status, CacheEntryStatus.partial);
  });

  test('revision state round trip preserves resources', () {
    final state = RevisionState.fromEntry(
      entry(),
      resources: {
        'sha256:${'0' * 64}': const CacheResourceRecord(
          resourceType: CacheResourceType.segment,
          status: CacheResourceStatus.complete,
          size: 100,
          ext: 'ts',
          totalLength: 100,
          lastAccessMs: 9,
        ),
      },
    );
    final restored = RevisionState.fromJson(state.toJson());
    expect(restored.resources['sha256:${'0' * 64}']?.size, 100);
    expect(restored.resources['sha256:${'0' * 64}']?.ext, 'ts');
    expect(
      restored.resources['sha256:${'0' * 64}']?.status,
      CacheResourceStatus.complete,
    );
    expect(restored.resources['sha256:${'0' * 64}']?.lastAccessMs, 9);
  });

  test('index save and load round trip', () async {
    await store.saveIndex([entry(), entry(title: '另一部')]);
    final loaded = await store.loadIndex();
    expect(loaded, hasLength(2));
    expect(loaded.map((e) => e.title), containsAll(['影片', '另一部']));
  });

  test('corrupt or missing index loads as empty', () async {
    expect(await store.loadIndex(), isEmpty);
    store.indexFile.writeAsStringSync('not json');
    expect(await store.loadIndex(), isEmpty);
  });

  test('unknown index schema version is rejected and loads as empty', () async {
    store.indexFile.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 2,
        'entries': [entry().toJson()],
      }),
    );
    expect(await store.loadIndex(), isEmpty);
  });

  test('unknown state schema version is isolated during rebuild', () async {
    await store.saveState(
      RevisionState.fromEntry(entry(), resources: const {}),
    );
    store.entryDir('ck', 'bad').createSync(recursive: true);
    File(
      '${store.entryDir('ck', 'bad').path}/$cacheStateFileName',
    ).writeAsStringSync(jsonEncode({...entry().toJson(), 'schemaVersion': 9}));
    final states = await store.rebuildFromStates();
    expect(states, hasLength(1));
    expect(states.single.contentKeyHash, 'ck');
  });

  test('resource file and partial file reject unsafe ids', () async {
    expect(
      () => store.resourceFile('ck', 'rk', '../evil', 'ts'),
      throwsArgumentError,
    );
    expect(
      () => store.partialFile('ck', 'rk', 'not-a-hash'),
      throwsArgumentError,
    );
    expect(
      () => store.resourceFile('ck', 'rk', 'sha256:${'a' * 64}', 'exe'),
      throwsArgumentError,
    );
    expect(
      () => store.resourceFile('ck', 'rk', 'sha256:${'a' * 64}', 'ts'),
      returnsNormally,
    );
  });

  test('empty display fields still deserialize (restart safe)', () {
    final json = entry().toJson()
      ..['title'] = ''
      ..['episodeName'] = ''
      ..['playbackLineName'] = ''
      ..['episodeId'] = '';
    final restored = CacheEntry.fromJson(json);
    expect(restored.title, '');
    expect(restored.episodeName, '');
    expect(restored.playbackLineName, '');
    expect(restored.contentKeyHash, 'ck');
  });

  test('missing identity fields are rejected', () {
    final json = entry().toJson()..['contentKeyHash'] = '';
    expect(() => CacheEntry.fromJson(json), throwsA(isA<FormatException>()));
  });

  test('proxy manifest save and load round trip', () async {
    await store.saveProxyManifest('ck', 'rk', '#EXTM3U\n#EXT-X-ENDLIST\n');
    final loaded = await store.loadProxyManifest('ck', 'rk');
    expect(loaded, contains('#EXT-X-ENDLIST'));
    expect(await store.loadProxyManifest('ck', 'missing'), isNull);
  });

  test('state save and rebuild from states', () async {
    final state = RevisionState.fromEntry(entry(), resources: const {});
    await store.saveState(state);
    final states = await store.rebuildFromStates();
    expect(states, hasLength(1));
    expect(states.single.title, '影片');
    expect(states.single.contentKeyHash, 'ck');
  });

  test('rebuild skips corrupt state files', () async {
    store.entryDir('ck', 'rk').createSync(recursive: true);
    File(
      '${store.entryDir('ck', 'rk').path}/$cacheStateFileName',
    ).writeAsStringSync('garbage');
    final states = await store.rebuildFromStates();
    expect(states, isEmpty);
  });

  test('atomic write leaves no temp file and overwrites', () async {
    final target = File('${tempDir.path}/x.json');
    await writeJsonAtomic(target, {'a': 1});
    await writeJsonAtomic(target, {'a': 2});
    expect(target.existsSync(), isTrue);
    expect(File('${target.path}$cacheTempSuffix').existsSync(), isFalse);
    expect(jsonDecode(target.readAsStringSync())['a'], 2);
  });

  test('cleanup temp files removes leftovers', () async {
    final dir = store.entryDir('ck', 'rk')..createSync(recursive: true);
    File('${dir.path}/leftover.tmp').writeAsStringSync('x');
    await store.cleanupTempFiles();
    expect(File('${dir.path}/leftover.tmp').existsSync(), isFalse);
  });

  test('delete entry dir removes the revision directory', () async {
    await store.saveState(
      RevisionState.fromEntry(entry(), resources: const {}),
    );
    expect(store.entryDir('ck', 'rk').existsSync(), isTrue);
    await store.deleteEntryDir('ck', 'rk');
    expect(store.entryDir('ck', 'rk').existsSync(), isFalse);
  });
}
