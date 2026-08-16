import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/adapters/mac_cms_v10_adapter.dart';
import 'package:jive/domain/playback_selection.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

void main() {
  test('adapter builds stable line and episode identities', () async {
    final adapter = MacCmsV10Adapter(
      MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 1,
              'list': [
                {
                  'vod_id': 7,
                  'vod_name': '测试片',
                  'vod_play_from':
                      '线路A'
                      r'$$$'
                      '线路B',
                  'vod_play_url':
                      r'第1集$https://cdn.example.com/a/1.m3u8#第2集$https://cdn.example.com/a/2.m3u8'
                      r'$$$'
                      r'第1集$https://cdn2.example.com/b/1.m3u8',
                },
              ],
            }),
          ),
          200,
        ),
      ),
    );
    final video = await adapter.resolvePlayback(
      _source,
      const VideoRef(sourceId: 'storm', sourceVideoId: '7'),
    );
    expect(video.playbackLines, hasLength(2));
    expect(video.playbackLines.first.identity, 'macv10:line:0:线路a');
    expect(video.playbackLines.last.identity, 'macv10:line:1:线路b');
    expect(
      video.playbackLines.first.episodes.first.identity,
      'macv10:episode:0:第1集',
    );
    expect(
      video.playbackLines.first.episodes.last.identity,
      'macv10:episode:1:第2集',
    );
    expect(video.episodes, same(video.playbackLines.first.episodes));
  });

  test(
    'selectionFor requires stable identities and chooses the default line',
    () {
      final video = Video(
        id: '7',
        title: '测试片',
        episodes: [
          const Episode(
            id: '1',
            name: '第1集',
            url: 'https://cdn.example.com/a/1.m3u8',
            identity: 'ep:1',
          ),
        ],
        playbackLines: [
          PlaybackLine(
            id: '0',
            name: '线路1',
            identity: 'line:0',
            episodes: [
              const Episode(
                id: '1',
                name: '第1集',
                url: 'https://cdn.example.com/a/1.m3u8',
                identity: 'ep:1',
              ),
            ],
          ),
        ],
      );
      final selection = selectionFor(video, video.episodes.first);
      expect(selection, isNotNull);
      expect(selection!.hasStableIdentity, isTrue);
      expect(selection.playbackLineIdentity, 'line:0');
      expect(selection.episodeIdentity, 'ep:1');
      expect(selection.playbackSource.format, PlaybackFormat.hls);
    },
  );

  test('selectionFor returns null when identities are missing', () {
    final video = Video(
      id: '7',
      title: '测试片',
      episodes: [const Episode(id: '1', name: '第1集', url: 'https://x/y.m3u8')],
      playbackLines: [
        PlaybackLine(
          id: '0',
          name: '线路1',
          episodes: [
            const Episode(id: '1', name: '第1集', url: 'https://x/y.m3u8'),
          ],
        ),
      ],
    );
    expect(selectionFor(video, video.episodes.first), isNull);
  });

  test('selectionFor matches the same episode identity across refresh', () {
    final line = PlaybackLine(
      id: '0',
      name: '线路1',
      identity: 'line:0',
      episodes: [
        const Episode(
          id: '1',
          name: '第1集',
          url: 'https://cdn.example.com/old/1.m3u8',
          identity: 'ep:1',
        ),
      ],
    );
    final staleEpisode = const Episode(
      id: '1',
      name: '第1集',
      url: 'https://cdn.example.com/old/1.m3u8',
      identity: 'ep:1',
    );
    final video = Video(
      id: '7',
      title: '测试片',
      episodes: line.episodes,
      playbackLines: [line],
    );
    final selection = selectionFor(video, staleEpisode);
    expect(selection!.episodeIdentity, 'ep:1');
    expect(selection.episode.url, 'https://cdn.example.com/old/1.m3u8');
  });
}

final _source = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);
