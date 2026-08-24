import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_controller.dart';
import 'package:jive/data/cache/cache_index.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/features/cache/cache_management_page.dart';

class _FakeCacheController extends CacheController {
  _FakeCacheController(List<CacheEntry> initial) : _entries = initial;

  final List<CacheEntry> _entries;

  @override
  Future<CacheStats> build() async => _stats();

  CacheStats _stats() {
    var complete = 0;
    var partial = 0;
    for (final e in _entries) {
      complete += e.completeBytes;
      partial += e.partialBytes;
    }
    return CacheStats(
      completeBytes: complete,
      partialBytes: partial,
      reservedBytes: 0,
      quotaBytes: 1 << 30,
      entries: List.of(_entries),
    );
  }

  @override
  Future<ClearAllResult> clearAll() async {
    _entries.clear();
    state = AsyncData(_stats());
    return ClearAllResult(deleted: 1);
  }

  @override
  Future<DeleteResult> deleteEntry(String entryKey) async {
    _entries.removeWhere((e) => e.key == entryKey);
    state = AsyncData(_stats());
    return DeleteResult.deleted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Widget wrap(List<CacheEntry> entries) => ProviderScope(
    overrides: [
      cacheControllerProvider.overrideWith(() => _FakeCacheController(entries)),
    ],
    child: const MaterialApp(home: CacheManagementPage()),
  );

  CacheEntry entry({
    String title = '测试影片',
    String episode = '第1集',
    bool offlinePlayable = false,
    bool downloadOrigin = false,
    CacheEntryStatus status = CacheEntryStatus.partial,
  }) => CacheEntry(
    contentKeyVersion: 1,
    contentKeyHash: 'ck1',
    revisionKeyHash: 'rk$episode',
    manifestFingerprint: 'fp',
    sourceId: 's',
    sourceVideoId: 'v',
    title: title,
    playbackLineIdentity: 'line',
    playbackLineName: '',
    episodeIdentity: 'ep$episode',
    episodeId: '1',
    episodeName: episode,
    status: status,
    downloadOrigin: downloadOrigin,
    completeBytes: 1048576,
    committedResourceCount: offlinePlayable ? 2 : 1,
    expectedResourceCount: 2,
    offlinePlayable: offlinePlayable,
    lastAccessMs: DateTime.now().millisecondsSinceEpoch,
  );

  testWidgets('shows empty state when there is no cache', (tester) async {
    await tester.pumpWidget(wrap(const []));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有播放缓存'), findsOneWidget);
    expect(find.textContaining('主动下载的任务在「下载」里'), findsOneWidget);
    expect(find.text('清理全部'), findsNothing);
  });

  testWidgets('shows summary and grouped entries when cache exists', (
    tester,
  ) async {
    await tester.pumpWidget(wrap([entry()]));
    await tester.pumpAndSettle();
    expect(find.text('测试影片'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('清理全部'), findsOneWidget);
    expect(find.textContaining('已用'), findsOneWidget);
    expect(find.textContaining('离线下载请到「下载」'), findsOneWidget);
    expect(find.text('自动'), findsNothing);
  });

  testWidgets('groups multiple episodes under one title', (tester) async {
    await tester.pumpWidget(
      wrap([entry(episode: '第1集'), entry(episode: '第2集')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试影片'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('delete entry confirms and removes it', (tester) async {
    await tester.pumpWidget(wrap([entry()]));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除该缓存？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('测试影片'), findsNothing);
    expect(find.textContaining('还没有播放缓存'), findsOneWidget);
  });

  testWidgets('clear all asks for confirmation', (tester) async {
    await tester.pumpWidget(wrap([entry()]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理全部'));
    await tester.pumpAndSettle();
    expect(find.text('清空全部缓存？'), findsOneWidget);
    expect(find.textContaining('下载列表里的任务不会被取消'), findsOneWidget);
  });

  testWidgets('status labels distinguish playback cache from downloads', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap([
        entry(episode: '第1集', offlinePlayable: true),
        entry(episode: '第2集', offlinePlayable: true, downloadOrigin: true),
        entry(episode: '第3集', status: CacheEntryStatus.failed),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('已缓存'), findsOneWidget);
    expect(find.text('离线下载'), findsOneWidget);
    expect(find.text('缓存失败'), findsOneWidget);
    expect(find.text('可离线'), findsNothing);
    expect(find.text('下载失败'), findsNothing);
  });
}
