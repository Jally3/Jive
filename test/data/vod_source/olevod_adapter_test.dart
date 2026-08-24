import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/vod_source/adapters/olevod_adapter.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

final _source = VodSource(
  id: 'olevod',
  name: '新欧乐影院',
  baseUri: Uri.parse('https://api.olelive.com'),
  adapterType: OlevodAdapter.adapterTypeName,
);

void main() {
  test('vv token matches the official plugin for a fixed unix second', () {
    expect(
      olevodVvTokenFromUnixSeconds(1710000000),
      '04a00010ff7100525ec10088f75380f9',
    );
  });

  test('fetchPage maps newest catalog and stamps _vv', () async {
    late Uri seen;
    final adapter = OlevodAdapter(
      MockClient((request) async {
        seen = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'list': [
                  {
                    'id': 48027,
                    'name': '沧元图',
                    'pic': 'upload/a.jpg',
                    'remarks': '更新至第91集',
                  },
                ],
              },
            }),
          ),
          200,
        );
      }),
      now: () => DateTime.fromMillisecondsSinceEpoch(1710000000 * 1000),
    );

    final page = await adapter.fetchPage(_source, page: 2);
    expect(seen.path, '/v1/pub/vod/newest/2/12');
    expect(seen.queryParameters['_vv'], '04a00010ff7100525ec10088f75380f9');
    expect(page.items.single.title, '沧元图');
    expect(page.items.single.sourceVideoId, '48027');
    expect(
      page.items.single.posterUrl,
      'https://static.olelive.com/upload/a.jpg',
    );
    expect(page.pageCount, 2);
  });

  test('search reads vod groups and skips 超清 cards', () async {
    final adapter = OlevodAdapter(
      MockClient((request) async {
        expect(request.url.path, contains('/v1/pub/index/search/'));
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'total': 2,
                'data': [
                  {
                    'type': 'vod',
                    'list': [
                      {'id': 1, 'name': 'A', 'pic': 'a.jpg', 'remarks': '更新至1'},
                      {'id': 2, 'name': 'B', 'pic': 'b.jpg', 'remarks': '超清'},
                    ],
                  },
                ],
              },
            }),
          ),
          200,
        );
      }),
    );

    final page = await adapter.fetchPage(_source, keyword: '沧元图');
    expect(page.items.map((item) => item.title), ['A']);
  });

  test('resolvePlayback drops VIP lines and keeps https m3u8', () async {
    final adapter = OlevodAdapter(
      MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'id': 48027,
                'name': '沧元图',
                'pic': 'upload/a.jpg',
                'remarks': '更新至第2集',
                'urls': [
                  {
                    'title': '第01集',
                    'url': 'https://cdn.example.com/1.m3u8',
                    'vip': false,
                  },
                  {
                    'title': 'VIP',
                    'url': 'https://cdn.example.com/vip.m3u8',
                    'vip': true,
                  },
                  {
                    'title': '坏链',
                    'url': 'http://cdn.example.com/2.m3u8',
                    'vip': false,
                  },
                ],
              },
            }),
          ),
          200,
        ),
      ),
    );

    final video = await adapter.resolvePlayback(
      _source,
      const VideoRef(sourceId: 'olevod', sourceVideoId: '48027'),
    );
    expect(video.title, '沧元图');
    expect(video.episodes, hasLength(1));
    expect(video.episodes.single.name, '第01集');
    expect(video.episodes.single.url, 'https://cdn.example.com/1.m3u8');
    expect(video.playbackLines.single.identity, 'olevod:line:default');
  });

  test('fetchDetail includes playable episodes for the detail page', () async {
    final adapter = OlevodAdapter(
      MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'id': 48027,
                'name': '沧元图',
                'pic': 'upload/a.jpg',
                'urls': [
                  {
                    'title': '第01集',
                    'url': 'https://cdn.example.com/1.m3u8',
                    'vip': false,
                  },
                ],
              },
            }),
          ),
          200,
        ),
      ),
    );
    final video = await adapter.fetchDetail(
      _source,
      const VideoRef(sourceId: 'olevod', sourceVideoId: '48027'),
    );
    expect(video.title, '沧元图');
    expect(video.episodes, hasLength(1));
    expect(video.episodes.single.url, endsWith('.m3u8'));
  });

  test('401 becomes a geo/signature error', () async {
    final adapter = OlevodAdapter(
      MockClient((request) async => http.Response('unauthorized', 401)),
    );
    await expectLater(
      adapter.fetchPage(_source),
      throwsA(
        isA<VideoDataException>().having(
          (error) => error.message,
          'message',
          contains('海外 IP'),
        ),
      ),
    );
  });
}
