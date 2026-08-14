import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/detail_source_controller.dart';

VodSource _src(String id, String name) => VodSource(
  id: id,
  name: name,
  baseUri: Uri.parse('https://$id.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
  search: true,
);

Video _video(
  String sourceId,
  String id,
  String title, {
  List<Episode> episodes = const [],
}) => Video(id: id, title: title, sourceId: sourceId, episodes: episodes);

void main() {
  final registry = VodSourceRegistry([
    _src('s1', '源1'),
    _src('s2', '源2'),
    _src('s3', '源3'),
    _src('s4', '源4'),
    _src('s5', '源5'),
  ], const {});

  test('initial state has only the active source, no auto detection', () {
    final controller = DetailSourceController(
      repository: _DetailRepository(),
      registry: registry,
      initialVideo: _video('s1', '1', '测试影片'),
    );
    expect(controller.activeSourceId, 's1');
    expect(controller.sourceStates, hasLength(1));
    expect(
      controller.sourceStates.first.status,
      DetailSourceStatus.notDetected,
    );
  });

  test('detectOtherSources probes at most three backups', () async {
    final repository = _RecordingDetailRepository();
    final controller = DetailSourceController(
      repository: repository,
      registry: registry,
      initialVideo: _video('s1', '1', '测试影片'),
    );
    await controller.detectOtherSources();
    final searched = repository.searchedSources;
    expect(searched, isNot(contains('s1')));
    expect(searched.length, 3);
    expect(searched, isNot(contains('s5')));
  });

  test(
    'detecting all sources explicitly probes every searchable backup',
    () async {
      final repository = _RecordingDetailRepository();
      final controller = DetailSourceController(
        repository: repository,
        registry: registry,
        initialVideo: _video('s1', '1', '测试影片'),
      );
      await controller.detectOtherSources(all: true);
      expect(repository.searchedSources, containsAll(['s2', 's3', 's4', 's5']));
    },
  );

  test('marking the initial detail sets the active source as loaded', () {
    final controller = DetailSourceController(
      repository: _DetailRepository(),
      registry: registry,
      initialVideo: _video('s1', '1', '测试影片'),
    );
    final detail = _video(
      's1',
      '1',
      '测试影片',
      episodes: [Episode(id: '1', name: '第1集', url: 'https://a/1')],
    );
    controller.markActiveLoaded(detail);
    expect(controller.stateFor('s1')!.status, DetailSourceStatus.loaded);
    expect(controller.stateFor('s1')!.episodeCount, 1);
  });

  test(
    'sources with matches report hasResource without changing active',
    () async {
      final repository = _RecordingDetailRepository();
      final controller = DetailSourceController(
        repository: repository,
        registry: registry,
        initialVideo: _video('s1', '1', '测试影片'),
      );
      await controller.detectOtherSources();
      expect(controller.activeSourceId, 's1');
      final s2 = controller.stateFor('s2');
      expect(s2!.status, DetailSourceStatus.hasResource);
      expect(s2.candidates, isNotEmpty);
    },
  );

  test(
    'loading candidate detail switches the active video atomically',
    () async {
      final controller = DetailSourceController(
        repository: _DetailRepository(),
        registry: registry,
        initialVideo: _video('s1', '1', '测试影片'),
      );
      await controller.detectOtherSources();
      final s2 = controller.stateFor('s2');
      await controller.loadCandidateDetail('s2', s2!.candidates.first);
      expect(controller.activeVideo.sourceId, 's2');
      expect(controller.activeVideo.title, '源2影片');
    },
  );

  test('failed candidate load keeps the current detail intact', () async {
    final controller = DetailSourceController(
      repository: _FailingDetailRepository(),
      registry: registry,
      initialVideo: _video('s1', '1', '测试影片'),
    );
    await controller.detectOtherSources();
    final s2 = controller.stateFor('s2');
    await controller.loadCandidateDetail('s2', s2!.candidates.first);
    expect(controller.activeVideo.sourceId, 's1');
    expect(controller.activeVideo.title, '测试影片');
    expect(controller.stateFor('s2')!.status, DetailSourceStatus.failed);
  });

  test(
    'candidate without playable episodes keeps the current detail',
    () async {
      final controller = DetailSourceController(
        repository: _UnplayableDetailRepository(),
        registry: registry,
        initialVideo: _video('s1', '1', '测试影片'),
      );
      await controller.detectOtherSources();
      final s2 = controller.stateFor('s2');
      await controller.loadCandidateDetail('s2', s2!.candidates.first);
      expect(controller.activeVideo.sourceId, 's1');
      expect(controller.activeVideo.title, '测试影片');
      expect(controller.stateFor('s2')!.status, DetailSourceStatus.failed);
    },
  );

  test('an interrupted detection resets the detecting state', () async {
    final repository = _BlockingSearchRepository();
    final controller = DetailSourceController(
      repository: repository,
      registry: registry,
      initialVideo: _video('s1', '1', '测试影片'),
    );
    final pending = controller.retryDetection('s2');
    expect(controller.stateFor('s2')!.status, DetailSourceStatus.detecting);
    await controller.retryDetection('s3');
    expect(controller.stateFor('s2')!.status, DetailSourceStatus.notDetected);
    repository.firstCall.complete(
      const VideoPage(items: [], page: 1, pageCount: 1),
    );
    await pending;
    expect(controller.stateFor('s2')!.status, DetailSourceStatus.notDetected);
  });

  test('findEpisodeByName matches by name then by episode number', () {
    final controller = DetailSourceController(
      repository: _DetailRepository(),
      registry: registry,
      initialVideo: _video(
        's1',
        '1',
        '连续剧',
        episodes: [
          Episode(id: '1', name: '第1集', url: 'https://a/1'),
          Episode(id: '2', name: '第2集', url: 'https://a/2'),
          Episode(id: '3', name: '第3集', url: 'https://a/3'),
        ],
      ),
    );
    expect(controller.findEpisodeByName('第2集'), 1);
    expect(controller.findEpisodeByName('第二集'), isNull);
    expect(controller.findEpisodeByName('第4集'), isNull);
  });

  test(
    'stale retryDetection result does not overwrite a newer round',
    () async {
      final repository = _BlockingSearchRepository();
      final controller = DetailSourceController(
        repository: repository,
        registry: registry,
        initialVideo: _video('s1', '1', '测试影片'),
      );
      final first = controller.retryDetection('s2');
      final second = controller.retryDetection('s2');
      await second;
      expect(controller.stateFor('s2')!.status, DetailSourceStatus.hasResource);
      repository.firstCall.complete(
        const VideoPage(items: [], page: 1, pageCount: 1),
      );
      await first;
      expect(controller.stateFor('s2')!.status, DetailSourceStatus.hasResource);
    },
  );

  test('a second loadCandidateDetail is ignored while switching', () async {
    final repository = _SlowDetailRepository();
    final controller = DetailSourceController(
      repository: repository,
      registry: registry,
      initialVideo: _video('s1', '1', '测试影片'),
    );
    await controller.detectOtherSources();
    final candidate = controller.stateFor('s2')!.candidates.first;
    final first = controller.loadCandidateDetail('s2', candidate);
    await controller.loadCandidateDetail('s2', candidate);
    repository.release.complete();
    await first;
    expect(repository.detailRequests, 1);
    expect(controller.activeVideo.sourceId, 's2');
  });

  test(
    'match scoring prefers candidates sharing actors and director',
    () async {
      final controller = DetailSourceController(
        repository: _MetadataSearchRepository(),
        registry: registry,
        initialVideo: const Video(
          id: '1',
          title: '测试影片',
          sourceId: 's1',
          year: '2020',
          actors: '张三,王五',
          director: '李四',
        ),
      );
      await controller.detectOtherSources();
      final candidates = controller.stateFor('s2')!.candidates;
      expect(candidates, hasLength(2));
      expect(candidates.first.id, 'meta');
    },
  );

  test('a large episode count difference lowers the match score', () async {
    final episodes36 = List.generate(
      36,
      (i) => Episode(id: '${i + 1}', name: '第${i + 1}集', url: 'https://a/$i'),
    );
    final controller = DetailSourceController(
      repository: _EpisodeCountSearchRepository(),
      registry: registry,
      initialVideo: _video('s1', '1', '连续剧', episodes: episodes36),
    );
    await controller.detectOtherSources();
    final candidates = controller.stateFor('s2')!.candidates;
    expect(candidates, hasLength(2));
    expect(candidates.first.id, 'same');
  });
}

class _DetailRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [_video(source.id, '1', '$keyword ${source.name}版')],
    page: 1,
    pageCount: 1,
  );

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async {
    return _video(
      source.id,
      ref.sourceVideoId,
      '${source.name}影片',
      episodes: [
        Episode(id: '1', name: '第1集', url: 'https://a/1'),
        Episode(id: '2', name: '第2集', url: 'https://a/2'),
      ],
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _RecordingDetailRepository implements VideoRepository {
  final List<String> searchedSources = [];

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    searchedSources.add(source.id);
    if (source.id == 's1') {
      return const VideoPage(items: [], page: 1, pageCount: 1);
    }
    return VideoPage(
      items: [_video(source.id, '1', '$keyword ${source.name}版')],
      page: 1,
      pageCount: 1,
    );
  }

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => _video(source.id, ref.sourceVideoId, '${source.name}影片');

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _FailingDetailRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [_video(source.id, '1', '$keyword ${source.name}版')],
    page: 1,
    pageCount: 1,
  );

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => throw const VideoDataException('详情加载失败');

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

/// fetchDetail 能返回详情，但 resolvePlayback 校验播放地址时失败，
/// 模拟“只有集名、没有可用播放地址”的来源。
class _UnplayableDetailRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [_video(source.id, '1', '$keyword ${source.name}版')],
    page: 1,
    pageCount: 1,
  );

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => _video(source.id, ref.sourceVideoId, '${source.name}影片');

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async =>
      throw const VideoDataException('该视频暂时没有可用播放地址');
}

class _BlockingSearchRepository implements VideoRepository {
  final Completer<VideoPage> firstCall = Completer<VideoPage>();
  var _s2Calls = 0;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    if (source.id == 's2') {
      _s2Calls++;
      if (_s2Calls == 1) return firstCall.future;
      return Future.value(
        VideoPage(
          items: [_video('s2', '2', '测试影片 源2版')],
          page: 1,
          pageCount: 1,
        ),
      );
    }
    return Future.value(const VideoPage(items: [], page: 1, pageCount: 1));
  }

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => _video(source.id, ref.sourceVideoId, '${source.name}影片');

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _SlowDetailRepository implements VideoRepository {
  final Completer<void> release = Completer<void>();
  var detailRequests = 0;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async =>
      VideoPage(items: [_video(source.id, '9', '测试影片')], page: 1, pageCount: 1);

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async {
    detailRequests++;
    await release.future;
    return _video(source.id, ref.sourceVideoId, '${source.name}影片');
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _MetadataSearchRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [
      Video(id: 'plain', title: '测试影片', sourceId: source.id),
      Video(
        id: 'meta',
        title: '测试影片',
        sourceId: source.id,
        year: '2020',
        actors: '张三',
        director: '李四',
      ),
    ],
    page: 1,
    pageCount: 1,
  );

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => _video(source.id, ref.sourceVideoId, '${source.name}影片');

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

class _EpisodeCountSearchRepository implements VideoRepository {
  List<Episode> _episodes(int count) => List.generate(
    count,
    (i) => Episode(id: '${i + 1}', name: '第${i + 1}集', url: 'https://b/$i'),
  );

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [
      Video(
        id: 'few',
        title: '连续剧',
        sourceId: source.id,
        episodes: _episodes(2),
      ),
      Video(
        id: 'same',
        title: '连续剧',
        sourceId: source.id,
        episodes: _episodes(36),
      ),
    ],
    page: 1,
    pageCount: 1,
  );

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => _video(source.id, ref.sourceVideoId, '${source.name}影片');

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}
