import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/multi_source_search_controller.dart';

VodSource _src(String id, String name) => VodSource(
  id: id,
  name: name,
  baseUri: Uri.parse('https://$id.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
  search: true,
);

void main() {
  test(
    '1+3: searches active source and probes at most three backups',
    () async {
      final repository = _RecordingRepository();
      final controller = MultiSourceSearchController(
        repository: repository,
        globalSource: _src('s1', '源1'),
        allSources: [
          _src('s1', '源1'),
          _src('s2', '源2'),
          _src('s3', '源3'),
          _src('s4', '源4'),
          _src('s5', '源5'),
        ],
      );
      controller.search('测试');
      await Future<void>.delayed(const Duration(milliseconds: 620));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final queried = repository.queriedSources.toSet();
      expect(queried, contains('s1'));
      expect(queried.length, 4);
      expect(queried, isNot(contains('s5')));
    },
  );

  test('switching source keeps global source untouched', () async {
    final repository = _RecordingRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('影片');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.globalSource.id, 's1');
    await controller.switchSource('s2');
    expect(controller.state.activeSourceId, 's2');
    expect(controller.globalSource.id, 's1');
  });

  test('keyword less than two chars skips backup probing', () async {
    final repository = _RecordingRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('一');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(repository.queriedSources, ['s1']);
  });

  test('a newer keyword result is not overwritten by an older one', () async {
    final repository = _DelayedMultiRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1')],
    );
    controller.search('旧');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    final old = repository.completions['s1:旧'];
    controller.search('新');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    final latest = repository.completions['s1:新'];
    latest!.complete(_page([Video(id: 'new', title: '新结果')], 1, 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    old!.complete(_page([Video(id: 'old', title: '旧结果')], 1, 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final active = controller.state.sources['s1'];
    expect(active!.items.single.title, '新结果');
    expect(active.loading, isFalse);
  });

  test('loads next page for the active source only', () async {
    final repository = _RecordingRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('连续剧');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await controller.loadMore();
    expect(repository.pagesQueried['s1:连续剧'], contains(2));
  });

  test('search results are cached within the session', () async {
    final repository = _RecordingRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('缓存');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final callsBefore = repository.calls['s1:缓存:1'] ?? 0;
    await controller.switchSource('s2');
    await controller.switchSource('s1');
    expect(repository.calls['s1:缓存:1'], callsBefore);
  });

  test('single source failure does not block other sources', () async {
    final repository = _FailingRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('影片');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final s1 = controller.state.sources['s1'];
    final s2 = controller.state.sources['s2'];
    expect(s1!.error, isNotNull);
    expect(s2!.items, isNotEmpty);
  });

  test(
    'refresh only refetches the active source and keeps backup cache',
    () async {
      final repository = _RecordingRepository();
      final controller = MultiSourceSearchController(
        repository: repository,
        globalSource: _src('s1', '源1'),
        allSources: [_src('s1', '源1'), _src('s2', '源2'), _src('s3', '源3')],
      );
      controller.search('缓存');
      await Future<void>.delayed(const Duration(milliseconds: 620));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(repository.calls['s2:缓存:1'], 1);
      final backupItems = controller.state.sources['s2']!.items;
      expect(backupItems, isNotEmpty);

      await controller.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 当前源重新请求，备用源不重新请求且缓存结果保留。
      expect(repository.calls['s1:缓存:1'], 2);
      expect(repository.calls['s2:缓存:1'], 1);
      expect(repository.calls['s3:缓存:1'], 1);
      expect(controller.state.sources['s2']!.items, backupItems);
    },
  );

  test('switching to a source with an in-flight probe waits for it '
      'without duplicate requests', () async {
    final repository = _DelayedMultiRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('影片');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    repository.completions['s1:影片']!.complete(
      _page([Video(id: 'a', title: '甲')], 1, 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.state.sources['s2']!.loading, isTrue);

    await controller.switchSource('s2');
    expect(controller.state.activeSourceId, 's2');
    // 进行中的探测未被作废，也没有重复发请求。
    expect(repository.calls['s2:影片'], 1);

    repository.completions['s2:影片']!.complete(
      _page([Video(id: 'b', title: '乙')], 1, 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final s2 = controller.state.sources['s2']!;
    expect(s2.loading, isFalse);
    expect(s2.items.single.title, '乙');
  });

  test('an interrupted probe does not corrupt the new session '
      'and the source stays queryable', () async {
    final repository = _DelayedMultiRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('老电影');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    repository.completions['s1:老电影']!.complete(
      _page([Video(id: 'a', title: '旧')], 1, 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.state.sources['s2']!.loading, isTrue);

    // 新关键词重置会话，旧探测完成时不得写入新会话。
    controller.search('新电影');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    repository.completions['s2:老电影']!.complete(
      _page([Video(id: 'x', title: '过时')], 1, 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.state.sources['s2'], isNull);

    // 新会话的备用探测正常发起，源没有被卡死。
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(repository.calls['s2:新电影'], 1);
    repository.completions['s2:新电影']!.complete(
      _page([Video(id: 'y', title: '新')], 1, 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final s2 = controller.state.sources['s2']!;
    expect(s2.loading, isFalse);
    expect(s2.items.single.title, '新');
  });

  test('empty active result triggers backup probing immediately', () async {
    final repository = _RecordingRepository(items: const []);
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('测试');
    // 只等防抖的 600ms，不等 300ms 备用延迟：空结果应立即触发探测。
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(Duration.zero);
    expect(repository.queriedSources, containsAll(<String>['s1', 's2']));
  });

  test('non-empty active result delays backup probing by 300ms', () async {
    final repository = _RecordingRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1'), _src('s2', '源2')],
    );
    controller.search('测试');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    await Future<void>.delayed(Duration.zero);
    expect(repository.queriedSources, ['s1']);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(repository.queriedSources, contains('s2'));
  });

  test('active source request times out and records an error', () async {
    final repository = _DelayedMultiRepository();
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [_src('s1', '源1')],
      requestTimeout: const Duration(milliseconds: 100),
    );
    controller.search('测试');
    await Future<void>.delayed(const Duration(milliseconds: 620));
    expect(controller.state.sources['s1']!.loading, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final s1 = controller.state.sources['s1']!;
    expect(s1.loading, isFalse);
    expect(s1.error, isNotNull);
  });

  test('sources with consecutive failures are excluded from auto probing '
      'until a manual success', () async {
    final repository = _FlakyRepository(failuresBeforeSuccess: {'s2': 2});
    final controller = MultiSourceSearchController(
      repository: repository,
      globalSource: _src('s1', '源1'),
      allSources: [
        _src('s1', '源1'),
        _src('s2', '源2'),
        _src('s3', '源3'),
        _src('s4', '源4'),
      ],
    );
    Future<void> runSearch(String keyword) async {
      controller.search(keyword);
      await Future<void>.delayed(const Duration(milliseconds: 620));
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // 两次搜索后 s2 连续失败 2 次，临时退出自动探测。
    await runSearch('测试一');
    await runSearch('测试二');

    repository.queriedSources.clear();
    await runSearch('测试三');
    expect(repository.queriedSources, isNot(contains('s2')));
    expect(repository.queriedSources, containsAll(<String>['s1', 's3', 's4']));

    // 手动查询成功，清除失败计数后恢复自动探测。
    await controller.searchSingleSource('s2');
    expect(controller.state.sources['s2']!.error, isNull);
    repository.queriedSources.clear();
    await runSearch('测试四');
    expect(repository.queriedSources, contains('s2'));
  });

  test('formatSourceCount degrades through total, page inference, 有结果', () {
    const base = SourceSearchState(queried: true);
    expect(formatSourceCount(null), '');
    expect(formatSourceCount(const SourceSearchState()), '');
    expect(formatSourceCount(base.copyWith(error: 'x')), '!');
    expect(formatSourceCount(base.copyWith(total: 24)), '24');
    expect(formatSourceCount(base), '0');
    expect(
      formatSourceCount(
        base.copyWith(
          items: [Video(id: '1', title: '一')],
          hasMore: true,
        ),
      ),
      '1+',
    );
    expect(
      formatSourceCount(
        base.copyWith(
          items: [Video(id: '1', title: '一')],
          hasMore: false,
        ),
      ),
      '有结果',
    );
  });
}

VideoPage _page(List<Video> items, int page, int pageCount, {int? total}) =>
    VideoPage(items: items, page: page, pageCount: pageCount, total: total);

class _RecordingRepository implements VideoRepository {
  _RecordingRepository({List<Video>? items}) : _items = items;

  final List<Video>? _items;
  final List<String> queriedSources = [];
  final Map<String, List<int>> pagesQueried = {};
  final Map<String, int> calls = {};

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    queriedSources.add(source.id);
    pagesQueried
        .putIfAbsent('${source.id}:${keyword ?? ''}', () => [])
        .add(page);
    final key = '${source.id}:${keyword ?? ''}:$page';
    calls[key] = (calls[key] ?? 0) + 1;
    final items =
        _items ??
        [Video(id: '${source.id}-$page', title: '${source.name}-$page')];
    return _page(items, page, 3, total: _items == null ? 25 : null);
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => Video(id: ref.sourceVideoId, title: ref.sourceVideoId);
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async =>
      Video(id: ref.sourceVideoId, title: ref.sourceVideoId);
}

class _DelayedMultiRepository implements VideoRepository {
  final Map<String, Completer<VideoPage>> completions = {};
  final Map<String, int> calls = {};

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    final key = '${source.id}:${keyword ?? ''}';
    calls[key] = (calls[key] ?? 0) + 1;
    final completer = Completer<VideoPage>();
    completions[key] = completer;
    return completer.future;
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

class _FlakyRepository implements VideoRepository {
  _FlakyRepository({required Map<String, int> failuresBeforeSuccess})
    : _failuresLeft = Map.of(failuresBeforeSuccess);

  final Map<String, int> _failuresLeft;
  final List<String> queriedSources = [];

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    queriedSources.add(source.id);
    final left = _failuresLeft[source.id] ?? 0;
    if (left > 0) {
      _failuresLeft[source.id] = left - 1;
      throw VideoDataException('${source.name}失败');
    }
    return _page(
      [Video(id: '${source.id}-$page', title: '${source.name}-$page')],
      page,
      1,
      total: 1,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}

class _FailingRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    if (source.id == 's1') throw const VideoDataException('源1失败');
    return _page([Video(id: 's2', title: '源2结果')], 1, 1);
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      throw UnimplementedError();
}
