import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/video_repository.dart';

void main() {
  test('parses paged videos and sends category parameters', () async {
    late Uri requestUri;
    final repository = StormVideoRepository(
      MockClient((request) async {
        requestUri = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 1,
              'page': 2,
              'pagecount': 4,
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
                },
              ],
            }),
          ),
          200,
        );
      }),
    );
    final page = await repository.fetchPage(page: 2, categoryId: 20);
    expect(requestUri.queryParameters, containsPair('t', '20'));
    expect(page.page, 2);
    expect(page.hasMore, isTrue);
    expect(page.items.single.title, '测试片');
    expect(page.items.single.description, '简介');
    expect(page.items.single.episodes, isEmpty);
  });

  test(
    'parses categories and valid https episodes while ignoring malformed values',
    () async {
      final repository = StormVideoRepository(
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
      final categories = await repository.fetchCategories();
      expect(categories.single.name, '电影片');
      final metadata = await repository.fetchDetail('9');
      expect(metadata.episodes, hasLength(3));
      expect(metadata.episodes.first.url, isEmpty);
      final detail = await repository.resolvePlayback('9');
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.name, '第1集');
    },
  );

  test('turns invalid server payload into a stable data exception', () async {
    final repository = StormVideoRepository(
      MockClient((_) async => http.Response('not-json', 200)),
    );
    expect(
      () => repository.fetchCategories(),
      throwsA(isA<VideoDataException>()),
    );
  });

  test('home falls back to the playable demo during network failure', () async {
    final repository = StormVideoRepository(
      MockClient((_) async => throw http.ClientException('offline')),
    );
    final page = await repository.fetchPage();
    expect(page.items, []);
    expect(page.hasMore, isFalse);
    expect(
      () => repository.fetchPage(categoryId: 20),
      throwsA(isA<VideoDataException>()),
    );
  });

  test(
    'detail metadata is cached but playback is resolved on demand',
    () async {
      var calls = 0;
      final repository = StormVideoRepository(
        MockClient((_) async {
          calls++;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': 1,
                'list': [
                  {
                    'vod_id': 42,
                    'vod_name': '缓存影片',
                    'vod_play_url': r'第一集$https://example.com/live.m3u8',
                  },
                ],
              }),
            ),
            200,
          );
        }),
      );
      final first = await repository.fetchDetail('42');
      final cached = await repository.fetchDetail('42');
      expect(calls, 1);
      expect(identical(first, cached), isTrue);
      expect(first.episodes.single.url, isEmpty);
      final playback = await repository.resolvePlayback('42');
      expect(calls, 2);
      expect(playback.episodes.single.url, 'https://example.com/live.m3u8');
      await repository.resolvePlayback('42');
      expect(calls, 3);
      await repository.fetchDetail('42', forceRefresh: true);
      expect(calls, 4);
    },
  );

  test('rejects API errors, empty details and missing playback URLs', () async {
    Future<void> expectFailure(
      Map<String, dynamic> payload,
      Future<void> Function(StormVideoRepository) action,
    ) async {
      final repository = StormVideoRepository(
        MockClient(
          (_) async =>
              http.Response.bytes(utf8.encode(jsonEncode(payload)), 200),
        ),
      );
      await expectLater(
        () => action(repository),
        throwsA(isA<VideoDataException>()),
      );
    }

    await expectFailure({'code': 0, 'msg': '限流'}, (r) => r.fetchCategories());
    await expectFailure({'code': 1, 'list': []}, (r) => r.fetchDetail('1'));
    await expectFailure({
      'code': 1,
      'list': [
        {'vod_id': 1, 'vod_name': '无地址'},
      ],
    }, (r) => r.resolvePlayback('1'));
  });
}
