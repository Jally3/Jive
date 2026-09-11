import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/content/cross_source_search_service.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/video_search_target.dart';
import 'package:jive/domain/vod_source.dart';

void main() {
  final sources = [for (var index = 1; index <= 5; index++) _source('s$index')];
  final registry = VodSourceRegistry(sources, const {});

  test(
    'searches at most three sources and excludes the current source',
    () async {
      final repository = _CrossSourceRepository();
      final service = CrossSourceSearchService(
        repository: repository,
        registry: registry,
      );

      final results = await service.search(
        const VideoSearchTarget(title: '测试影片', year: '2024'),
        excludedSourceId: 's1',
      );

      expect(results, hasLength(3));
      expect(repository.searchedSources, containsAll(['s2', 's3', 's4']));
      expect(repository.searchedSources, isNot(contains('s1')));
    },
  );

  test('reports ambiguity separately from no result', () async {
    final service = CrossSourceSearchService(
      repository: _AmbiguousRepository(),
      registry: registry,
    );

    final result = await service.searchSource(
      sources.first,
      const VideoSearchTarget(title: '同名影片'),
    );

    expect(result.status, CrossSourceSearchStatus.ambiguous);
    expect(result.candidate, isNull);
  });

  test(
    'reports request failures without describing them as not found',
    () async {
      final service = CrossSourceSearchService(
        repository: _FailingSearchRepository(),
        registry: registry,
      );

      final result = await service.searchSource(
        sources.first,
        const VideoSearchTarget(title: '测试影片'),
      );

      expect(result.status, CrossSourceSearchStatus.requestFailed);
      expect(result.error, contains('网络超时'));
    },
  );

  test('resolves a matched candidate to a real source VideoRef', () async {
    final repository = _CrossSourceRepository();
    final service = CrossSourceSearchService(
      repository: repository,
      registry: registry,
    );
    final result = await service.searchSource(
      sources[1],
      const VideoSearchTarget(title: '测试影片', year: '2024'),
    );

    final resolved = await service.resolve(result);

    expect(resolved.sourceId, 's2');
    expect(resolved.sourceVideoId, 'real-s2');
    expect(repository.resolvedRefs.single.globalId, 's2:real-s2');
  });
}

VodSource _source(String id) => VodSource(
  id: id,
  name: id,
  baseUri: Uri.parse('https://$id.example.com'),
  adapterType: 'test',
  search: true,
);

class _CrossSourceRepository implements VideoRepository {
  final List<String> searchedSources = [];
  final List<VideoRef> resolvedRefs = [];

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    searchedSources.add(source.id);
    return VideoPage(
      items: [
        Video(
          id: 'real-${source.id}',
          title: keyword!,
          sourceId: source.id,
          year: '2024',
        ),
      ],
      page: 1,
      pageCount: 1,
    );
  }

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async {
    resolvedRefs.add(ref);
    return Video(
      id: ref.sourceVideoId,
      title: '测试影片',
      sourceId: source.id,
      episodes: const [
        Episode(id: '1', name: '正片', url: 'https://video.example.com/1.m3u8'),
      ],
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();
}

class _AmbiguousRepository extends _CrossSourceRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => VideoPage(
    items: [
      Video(id: 'a', title: keyword!, sourceId: source.id),
      Video(id: 'b', title: keyword, sourceId: source.id),
    ],
    page: 1,
    pageCount: 1,
  );
}

class _FailingSearchRepository extends _CrossSourceRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) => throw const VideoDataException('网络超时');
}
