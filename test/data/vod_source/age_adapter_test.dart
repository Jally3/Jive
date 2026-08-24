import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/vod_source/adapters/age_adapter.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

final _source = VodSource(
  id: 'age',
  name: '新 AGE',
  baseUri: Uri.parse('https://ageapi.omwjhz.com:18888'),
  adapterType: AgeAdapter.adapterTypeName,
  notification: 'AGE 动漫',
);

void main() {
  test('fetchCategories is local and does not hit the network', () async {
    var requests = 0;
    final adapter = AgeAdapter(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 500);
      }),
    );
    final categories = await adapter.fetchCategories(_source);
    expect(requests, 0);
    expect(categories.map((item) => item.name), ['热门', '连载', '剧场版', 'WEB']);
  });

  test('fetchPage maps catalog query, totals and cards', () async {
    late Uri requestUri;
    final adapter = AgeAdapter(
      MockClient((request) async {
        requestUri = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'total': 64,
              'videos': [
                {
                  'id': 2026,
                  'name': '测试番',
                  'cover': 'https://cdn.example.com/a.jpg',
                  'uptodate': '第09集',
                  'type': 'TV',
                  'intro': '简介',
                },
              ],
            }),
          ),
          200,
        );
      }),
    );
    final page = await adapter.fetchPage(_source, page: 2, categoryId: 2);
    expect(requestUri.path, '/v2/catalog');
    expect(requestUri.queryParameters['page'], '2');
    expect(requestUri.queryParameters['status'], '连载');
    expect(page.total, 64);
    expect(page.pageCount, 2);
    expect(page.items.single.title, '测试番');
    expect(page.items.single.sourceId, 'age');
    expect(page.items.single.remarks, '第09集');
  });

  test('search uses totalPage and encodes the keyword', () async {
    late Uri requestUri;
    final adapter = AgeAdapter(
      MockClient((request) async {
        requestUri = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 200,
              'data': {
                'videos': [
                  {'id': 1, 'name': '转生骑士'},
                ],
                'total': 53,
                'totalPage': 3,
              },
            }),
          ),
          200,
        );
      }),
    );
    final page = await adapter.fetchPage(_source, keyword: '转生');
    expect(requestUri.path, '/v2/search');
    expect(requestUri.queryParameters['query'], '转生');
    expect(page.pageCount, 3);
    expect(page.total, 53);
    expect(page.items.single.title, '转生骑士');
  });

  test('resolvePlayback drops VIP lines and prefers ffm3u8', () async {
    final adapter = AgeAdapter(
      MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'player_jx': {'zj': 'https://jx.example.com/m3u8/?url='},
              'player_vip': 'xigua,qq',
              'player_label_arr': {
                'xigua': '西瓜',
                'wjm3u8': '无尽',
                'ffm3u8': '非凡',
              },
              'video': {
                'id': 9,
                'name': '连载番',
                'cover': 'https://cdn.example.com/a.jpg',
                'intro': '简介',
                'year': '2026',
                'area': '日本',
                'writer': '作者',
                'uptodate': '第02集',
                'playlists': {
                  'xigua': [
                    ['第01集', 'age_vip'],
                  ],
                  'wjm3u8': [
                    ['第01集', 'age_wj'],
                    ['第02集', 'age_wj2'],
                  ],
                  'ffm3u8': [
                    ['第01集', 'age_ff'],
                    ['第02集', 'age_ff2'],
                  ],
                },
              },
            }),
          ),
          200,
        ),
      ),
    );
    final detail = await adapter.fetchDetail(
      _source,
      const VideoRef(sourceId: 'age', sourceVideoId: '9'),
    );
    expect(detail.episodes, hasLength(2));
    expect(detail.episodes.first.url, isEmpty);
    expect(detail.year, '2026');

    final playable = await adapter.resolvePlayback(
      _source,
      const VideoRef(sourceId: 'age', sourceVideoId: '9'),
    );
    expect(playable.playbackLines.map((line) => line.name), ['非凡', '无尽']);
    expect(
      playable.episodes.first.url,
      'https://jx.example.com/m3u8/?url=age_ff',
    );
    expect(playable.episodes.first.identity, 'age:episode:num:1');
  });

  test('rejects missing details and empty non-VIP playlists', () async {
    Future<void> expectFailure(Object payload) async {
      final adapter = AgeAdapter(
        MockClient(
          (_) async =>
              http.Response.bytes(utf8.encode(jsonEncode(payload)), 200),
        ),
      );
      await expectLater(
        adapter.resolvePlayback(
          _source,
          const VideoRef(sourceId: 'age', sourceVideoId: '1'),
        ),
        throwsA(isA<VideoDataException>()),
      );
    }

    await expectFailure({'video': {}});
    await expectFailure({
      'player_vip': 'ffm3u8',
      'video': {
        'id': 1,
        'name': '只有VIP',
        'playlists': {
          'ffm3u8': [
            ['第01集', 'age_x'],
          ],
        },
      },
    });
  });
}
