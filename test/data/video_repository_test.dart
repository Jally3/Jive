import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/vod_source/adapters/mac_cms_v10_adapter.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/video_detail_cache.dart';
import 'package:jive/data/vod_source/vod_source_adapter.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

final _testSource = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

VideoRef _ref(String id) => VideoRef(sourceId: 'storm', sourceVideoId: id);

void main() {
  test('parses paged videos and sends category parameters', () async {
    late Uri requestUri;
    final adapter = MacCmsV10Adapter(
      MockClient((request) async {
        requestUri = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 1,
              'page': 2,
              'pagecount': 4,
              'total': 30,
              'list': [
                {
                  'vod_id': 7,
                  'vod_name': '测试片',
                  'vod_pic': 'https://example.com/a.jpg',
                  'type_id': 20,
                  'type_name': '电影片',
                  'vod_remarks': 'HD',
                  'vod_content': '<p>简介</p>',
                  'vod_time': '2026-08-12',
                  'vod_year': '2026',
                  'vod_area': '中国',
                  'vod_actor': '演员',
                  'vod_director': '导演',
                },
              ],
            }),
          ),
          200,
        );
      }),
    );
    final page = await adapter.fetchPage(_testSource, page: 2, categoryId: 20);
    expect(requestUri.queryParameters, containsPair('t', '20'));
    expect(page.page, 2);
    expect(page.hasMore, isTrue);
    expect(page.total, 30);
    expect(page.items.single.title, '测试片');
    expect(page.items.single.description, '简介');
    expect(page.items.single.year, '2026');
    expect(page.items.single.sourceId, 'storm');
    expect(page.items.single.episodes, isEmpty);
  });

  test(
    'parses categories and valid https episodes while ignoring malformed values',
    () async {
      final adapter = MacCmsV10Adapter(
        MockClient((request) async {
          final detail = request.url.queryParameters['ids'] != null;
          final payload = detail
              ? {
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 9,
                      'vod_name': '连续剧',
                      'vod_play_url':
                          r'第1集$https://cdn.example.com/1.m3u8#坏数据#第2集$http://unsafe.example.com/2.m3u8#第1集重复$https://cdn.example.com/1.m3u8',
                    },
                  ],
                }
              : {
                  'code': 1,
                  'class': [
                    {'type_id': 20, 'type_pid': 0, 'type_name': '电影片'},
                  ],
                  'list': [],
                };
          return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200);
        }),
      );
      final categories = await adapter.fetchCategories(_testSource);
      expect(categories.single.name, '电影片');
      final metadata = await adapter.fetchDetail(_testSource, _ref('9'));
      expect(metadata.episodes, hasLength(3));
      expect(metadata.episodes.first.url, isEmpty);
      expect(metadata.playbackLines.single.episodes, hasLength(1));
      final detail = await adapter.resolvePlayback(_testSource, _ref('9'));
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.name, '第1集');
    },
  );

  test('turns invalid server payload into a stable data exception', () async {
    final adapter = MacCmsV10Adapter(
      MockClient((_) async => http.Response('not-json', 200)),
    );
    expect(
      () => adapter.fetchCategories(_testSource),
      throwsA(isA<VideoDataException>()),
    );
  });

  test('rejects API errors, empty details and missing playback URLs', () async {
    Future<void> expectFailure(
      Map<String, dynamic> payload,
      Future<void> Function(MacCmsV10Adapter) action,
    ) async {
      final adapter = MacCmsV10Adapter(
        MockClient(
          (_) async =>
              http.Response.bytes(utf8.encode(jsonEncode(payload)), 200),
        ),
      );
      await expectLater(
        () => action(adapter),
        throwsA(isA<VideoDataException>()),
      );
    }

    await expectFailure({
      'code': 0,
      'msg': '限流',
    }, (a) => a.fetchCategories(_testSource));
    await expectFailure({
      'code': 1,
      'list': [],
    }, (a) => a.fetchDetail(_testSource, _ref('1')));
    await expectFailure({
      'code': 1,
      'list': [
        {'vod_id': 1, 'vod_name': '无地址'},
      ],
    }, (a) => a.resolvePlayback(_testSource, _ref('1')));
  });

  test('parses multiple playback lines', () async {
    final adapter = MacCmsV10Adapter(
      MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 1,
              'list': [
                {
                  'vod_id': 42,
                  'vod_name': '多线路影片',
                  'vod_play_from': '线路1\$\$\$线路2',
                  'vod_play_url':
                      r'第1集$https://cdn.example.com/1.m3u8#第2集$https://cdn.example.com/2.m3u8$$$第1集$https://cdn2.example.com/1.m3u8',
                },
              ],
            }),
          ),
          200,
        ),
      ),
    );
    final detail = await adapter.resolvePlayback(_testSource, _ref('42'));
    expect(detail.playbackLines, hasLength(2));
    expect(detail.playbackLines[0].name, '线路1');
    expect(detail.playbackLines[0].episodes, hasLength(2));
    expect(detail.playbackLines[1].name, '线路2');
    expect(detail.playbackLines[1].episodes, hasLength(1));
  });

  test('repository delegates to the injected adapter resolver', () async {
    var requests = 0;
    final adapter = MacCmsV10Adapter(
      MockClient((request) async {
        requests++;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 1,
              'page': 1,
              'pagecount': 1,
              'list': [
                {'vod_id': 3, 'vod_name': '注入的片'},
              ],
            }),
          ),
          200,
        );
      }),
    );
    final repository = VideoRepositoryImpl(
      adapterResolver: (source) =>
          source.adapterType == 'mac_cms_v10' ? adapter : null,
    );
    final page = await repository.fetchPage(_testSource);
    expect(page.items.single.title, '注入的片');
    expect(requests, 1);
  });

  test(
    'repository caches details per globalId and honors forceRefresh',
    () async {
      var requests = 0;
      final adapter = MacCmsV10Adapter(
        MockClient((request) async {
          requests++;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': 1,
                'list': [
                  {'vod_id': 5, 'vod_name': '详情$requests'},
                ],
              }),
            ),
            200,
          );
        }),
      );
      final repository = VideoRepositoryImpl(adapterResolver: (_) => adapter);
      addTearDown(repository.dispose);
      final first = await repository.fetchDetail(_testSource, _ref('5'));
      final cached = await repository.fetchDetail(_testSource, _ref('5'));
      expect(identical(first, cached), isTrue);
      expect(requests, 1);
      await repository.fetchDetail(_testSource, _ref('5'), forceRefresh: true);
      expect(requests, 2);
    },
  );

  group('MacCMS detail playback reuse', () {
    http.Response response(String version, {String id = '9'}) =>
        http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 1,
              'list': [
                {
                  'vod_id': id,
                  'vod_name': version,
                  'vod_play_from': 'm3u8',
                  'vod_play_url':
                      '第1集\$https://cdn.example.com/$version/1.m3u8#'
                      '第2集\$https://cdn.example.com/$version/2.m3u8',
                },
              ],
            }),
          ),
          200,
        );

    for (final playbackFirst in [false, true]) {
      test(
        'detail and playback share one request, playbackFirst=$playbackFirst',
        () async {
          var requests = 0;
          final adapter = MacCmsV10Adapter(
            MockClient((_) async {
              requests++;
              return response('v1');
            }),
          );
          final repository = VideoRepositoryImpl(
            adapterResolver: (_) => adapter,
          );
          addTearDown(repository.dispose);
          if (playbackFirst) {
            await repository.resolvePlayback(_testSource, _ref('9'));
          }
          final detail = await repository.fetchDetail(_testSource, _ref('9'));
          final playable = await repository.resolvePlayback(
            _testSource,
            _ref('9'),
          );
          expect(requests, 1);
          expect(detail.episodes.first.url, isEmpty);
          expect(detail.playbackLines, same(playable.playbackLines));
          expect(playable.episodes, same(detail.playbackLines.first.episodes));
          expect(playable.episodes.last.url, contains('/v1/2.m3u8'));
          expect(
            await repository.fetchDetail(_testSource, _ref('9')),
            same(detail),
          );
        },
      );
    }

    test('concurrent detail and playback share an in-flight request', () async {
      final result = Completer<http.Response>();
      var requests = 0;
      final adapter = MacCmsV10Adapter(
        MockClient((_) {
          requests++;
          return result.future;
        }),
      );
      final repository = VideoRepositoryImpl(adapterResolver: (_) => adapter);
      addTearDown(repository.dispose);
      final detail = repository.fetchDetail(_testSource, _ref('9'));
      final playback = repository.resolvePlayback(_testSource, _ref('9'));
      result.complete(response('v1'));
      await Future.wait([detail, playback]);
      expect(requests, 1);
    });

    test(
      'forced refresh coalesces and late old results cannot replace fresh data',
      () async {
        final results = [
          Completer<http.Response>(),
          Completer<http.Response>(),
        ];
        var requests = 0;
        final adapter = MacCmsV10Adapter(
          MockClient((_) => results[requests++].future),
        );
        final repository = VideoRepositoryImpl(adapterResolver: (_) => adapter);
        addTearDown(repository.dispose);
        final old = repository.fetchDetail(_testSource, _ref('9'));
        final fresh = repository.resolvePlayback(
          _testSource,
          _ref('9'),
          forceRefresh: true,
        );
        final duplicate = repository.resolvePlayback(
          _testSource,
          _ref('9'),
          forceRefresh: true,
        );
        results[1].complete(response('fresh'));
        await Future.wait([fresh, duplicate]);
        results[0].complete(response('old'));
        await old;
        expect(requests, 2);
        expect(
          (await repository.fetchDetail(_testSource, _ref('9'))).title,
          'fresh',
        );
      },
    );

    test(
      'failed forced refresh discards stale data and allows a new request',
      () async {
        var requests = 0;
        final adapter = MacCmsV10Adapter(
          MockClient((_) async {
            requests++;
            return requests == 2
                ? http.Response('denied', 403)
                : response('v$requests');
          }),
        );
        final repository = VideoRepositoryImpl(adapterResolver: (_) => adapter);
        addTearDown(repository.dispose);
        await repository.fetchDetail(_testSource, _ref('9'));
        await expectLater(
          repository.resolvePlayback(
            _testSource,
            _ref('9'),
            forceRefresh: true,
          ),
          throwsA(isA<VideoDataException>()),
        );
        final fresh = await repository.resolvePlayback(_testSource, _ref('9'));
        expect(fresh.title, 'v3');
        expect(requests, 3);
      },
    );

    test(
      'expiry and same-id source config changes require another request',
      () async {
        var now = DateTime(2026);
        var requests = 0;
        final adapter = MacCmsV10Adapter(
          MockClient((_) async => response('v${++requests}')),
        );
        final repository = VideoRepositoryImpl(
          adapterResolver: (_) => adapter,
          detailCache: VideoDetailCache(now: () => now),
        );
        addTearDown(repository.dispose);
        await repository.fetchDetail(_testSource, _ref('9'));
        now = now.add(const Duration(minutes: 2));
        expect(
          (await repository.resolvePlayback(_testSource, _ref('9'))).title,
          'v2',
        );
        final moved = VodSource(
          id: _testSource.id,
          name: 'Moved',
          baseUri: Uri.parse('https://new.example.com/api'),
          adapterType: 'mac_cms_v10',
        );
        expect(
          (await repository.resolvePlayback(moved, _ref('9'))).title,
          'v3',
        );
        final configured = VodSource(
          id: moved.id,
          name: moved.name,
          baseUri: moved.baseUri,
          adapterType: moved.adapterType,
          pluginConfigUri: Uri.parse('https://example.com/plugin'),
        );
        expect(
          (await repository.resolvePlayback(configured, _ref('9'))).title,
          'v4',
        );
        expect(requests, 4);
      },
    );

    test(
      'other adapters still resolve playback independently of detail cache',
      () async {
        final adapter = _SeparatePlaybackAdapter();
        final repository = VideoRepositoryImpl(adapterResolver: (_) => adapter);
        addTearDown(repository.dispose);
        await repository.fetchDetail(_testSource, _ref('9'));
        await repository.resolvePlayback(_testSource, _ref('9'));
        await repository.resolvePlayback(
          _testSource,
          _ref('9'),
          forceRefresh: true,
        );
        expect(adapter.detailCalls, 1);
        expect(adapter.playbackCalls, 2);
      },
    );
  });

  test('repository throws ArgumentError for unknown adapter type', () {
    final repository = VideoRepositoryImpl(adapterResolver: (_) => null);
    final weird = VodSource(
      id: 'w',
      name: '未知协议源',
      baseUri: Uri.parse('https://w.example.com/api.php/provide/vod'),
      adapterType: 'unknown_proto',
    );
    expect(() => repository.fetchPage(weird), throwsArgumentError);
    expect(() => repository.fetchCategories(weird), throwsArgumentError);
    expect(
      () => repository.resolvePlayback(weird, _ref('1')),
      throwsArgumentError,
    );
  });
}

class _SeparatePlaybackAdapter implements VodSourceAdapter {
  int detailCalls = 0;
  int playbackCalls = 0;
  @override
  String get adapterType => 'separate';
  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) async {
    detailCalls++;
    return const Video(id: '9', title: 'Metadata');
  }

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async {
    playbackCalls++;
    return const Video(id: '9', title: 'Playback');
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => const VideoPage(items: [], page: 1, pageCount: 1);
}
