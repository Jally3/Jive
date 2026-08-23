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
  test('inferPlaybackFormat treats dotted media paths as final', () {
    expect(
      inferPlaybackFormat('https://cdn.example.com/a/1.m3u8'),
      PlaybackFormat.hls,
    );
    expect(
      inferPlaybackFormat('https://cdn.example.com/a/1.mp4'),
      PlaybackFormat.mp4,
    );
  });

  test('inferPlaybackFormat does not treat /m3u8/ directories as HLS', () {
    expect(
      inferPlaybackFormat('https://jx.example.com:8443/m3u8/?url=age_x'),
      PlaybackFormat.unknown,
    );
    expect(
      inferPlaybackFormat('https://cdn.example.com/hls/token'),
      PlaybackFormat.unknown,
    );
  });

  test('inferPlaybackFormat still honors m3u8 query tokens', () {
    expect(
      inferPlaybackFormat('https://play.example.com/token?format=m3u8'),
      PlaybackFormat.hls,
    );
  });

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

  test('selection prefers a direct m3u8 line over an HTML wrapper', () {
    const wrapper = Episode(
      id: '1',
      name: '第1集',
      url: 'https://v.example.com/play/abc',
      identity: 'ep:1',
    );
    const direct = Episode(
      id: '1',
      name: '第1集',
      url: 'https://cdn.example.com/abc/index.m3u8',
      identity: 'ep:1',
    );
    final video = Video(
      id: '7',
      title: '测试片',
      episodes: const [wrapper],
      playbackLines: const [
        PlaybackLine(
          id: '0',
          name: 'gsyun',
          identity: 'line:wrapper',
          episodes: [wrapper],
        ),
        PlaybackLine(
          id: '1',
          name: 'gsm3u8',
          identity: 'line:m3u8',
          episodes: [direct],
        ),
      ],
    );

    final selection = selectionFor(video, wrapper)!;
    expect(selection.playbackLineIdentity, 'line:m3u8');
    expect(selection.playbackSource.url, Uri.parse(direct.url));
    expect(selection.playbackSource.format, PlaybackFormat.hls);
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

  test('refreshSelectionFor keeps the current line and uses its fresh URL', () {
    const previousEpisode = Episode(
      id: '1',
      name: '第1集',
      url: 'https://old.example.com/b/1.m3u8',
      identity: 'ep:1',
    );
    final previous = PlaybackSelection(
      sourceId: 'storm',
      sourceVideoId: '7',
      title: '测试片',
      playbackLineIdentity: 'line:b',
      episodeIdentity: previousEpisode.identity,
      episode: previousEpisode,
      playbackSource: PlaybackSource(
        url: Uri.parse(previousEpisode.url),
        format: PlaybackFormat.hls,
      ),
    );
    const freshEpisode = Episode(
      id: '1',
      name: '第1集',
      url: 'https://fresh.example.com/b/1.m3u8',
      identity: 'ep:1',
    );
    final fresh = Video(
      id: '7',
      title: '测试片',
      sourceId: 'storm',
      playbackLines: const [
        PlaybackLine(
          id: '0',
          name: 'm3u8',
          identity: 'line:a',
          episodes: [
            Episode(
              id: '1',
              name: '第1集',
              url: 'https://fresh.example.com/a/1.m3u8',
              identity: 'ep:1',
            ),
          ],
        ),
        PlaybackLine(
          id: '1',
          name: '备用线路',
          identity: 'line:b',
          episodes: [freshEpisode],
        ),
      ],
    );

    final refreshed = refreshSelectionFor(
      freshVideo: fresh,
      priorEpisode: previousEpisode,
      previousSelection: previous,
    );

    expect(refreshed, isNotNull);
    expect(refreshed!.playbackLineIdentity, 'line:b');
    expect(refreshed.episode, same(freshEpisode));
    expect(
      refreshed.playbackSource.url,
      Uri.parse('https://fresh.example.com/b/1.m3u8'),
    );
  });

  test(
    'refreshSelectionFor falls back by name only within the current line',
    () {
      const previousEpisode = Episode(
        id: 'old-id',
        name: '第2集',
        url: 'https://old.example.com/2.m3u8',
        identity: 'old-identity',
      );
      final previous = PlaybackSelection(
        sourceId: 'storm',
        sourceVideoId: '7',
        title: '测试片',
        playbackLineIdentity: 'line:b',
        episodeIdentity: previousEpisode.identity,
        episode: previousEpisode,
        playbackSource: PlaybackSource(
          url: Uri.parse(previousEpisode.url),
          format: PlaybackFormat.hls,
        ),
      );
      const freshMatch = Episode(
        id: 'new-id',
        name: '第2集',
        url: 'https://fresh.example.com/b/2.m3u8',
        identity: 'new-identity',
      );
      final fresh = Video(
        id: '7',
        title: '测试片',
        sourceId: 'storm',
        playbackLines: const [
          PlaybackLine(
            id: '0',
            name: '默认线路',
            identity: 'line:a',
            episodes: [
              Episode(
                id: 'old-id',
                name: '第2集',
                url: 'https://fresh.example.com/a/2.m3u8',
                identity: 'cross-line-identity',
              ),
            ],
          ),
          PlaybackLine(
            id: '1',
            name: '当前线路',
            identity: 'line:b',
            episodes: [freshMatch],
          ),
        ],
      );

      final refreshed = refreshSelectionFor(
        freshVideo: fresh,
        priorEpisode: previousEpisode,
        previousSelection: previous,
      );

      expect(refreshed, isNotNull);
      expect(refreshed!.playbackLineIdentity, 'line:b');
      expect(refreshed.episodeIdentity, 'new-identity');
      expect(refreshed.episode.url, 'https://fresh.example.com/b/2.m3u8');
    },
  );

  test(
    'refreshSelectionFor returns null when the previous line disappears',
    () {
      const previousEpisode = Episode(
        id: '1',
        name: '第1集',
        url: 'https://old.example.com/b/1.m3u8',
        identity: 'ep:1',
      );
      final previous = PlaybackSelection(
        sourceId: 'storm',
        sourceVideoId: '7',
        title: '测试片',
        playbackLineIdentity: 'line:b',
        episodeIdentity: previousEpisode.identity,
        episode: previousEpisode,
        playbackSource: PlaybackSource(
          url: Uri.parse(previousEpisode.url),
          format: PlaybackFormat.hls,
        ),
      );
      final fresh = Video(
        id: '7',
        title: '测试片',
        sourceId: 'storm',
        playbackLines: const [
          PlaybackLine(
            id: '0',
            name: '默认线路',
            identity: 'line:a',
            episodes: [
              Episode(
                id: '1',
                name: '第1集',
                url: 'https://fresh.example.com/a/1.m3u8',
                identity: 'ep:1',
              ),
            ],
          ),
        ],
      );

      expect(
        refreshSelectionFor(
          freshVideo: fresh,
          priorEpisode: previousEpisode,
          previousSelection: previous,
        ),
        isNull,
      );
    },
  );

  test(
    'refreshSelectionFor uses the fresh default line without a selection',
    () {
      const priorEpisode = Episode(
        id: '2',
        name: '第2集',
        url: 'https://old.example.com/2.m3u8',
        identity: 'old-identity',
      );
      const freshEpisode = Episode(
        id: '2',
        name: '第2集',
        url: 'https://fresh.example.com/2.m3u8',
        identity: 'fresh-identity',
      );
      final fresh = Video(
        id: '7',
        title: '测试片',
        sourceId: 'storm',
        playbackLines: const [
          PlaybackLine(
            id: '0',
            name: '默认 m3u8',
            identity: 'line:default',
            episodes: [freshEpisode],
          ),
        ],
      );

      final refreshed = refreshSelectionFor(
        freshVideo: fresh,
        priorEpisode: priorEpisode,
      );

      expect(refreshed, isNotNull);
      expect(refreshed!.playbackLineIdentity, 'line:default');
      expect(refreshed.episode, same(freshEpisode));
      expect(refreshed.playbackSource.url, Uri.parse(freshEpisode.url));
    },
  );

  test('indexOfEpisode prefers identity then name then id', () {
    const episodes = [
      Episode(id: '1', name: '第1集', url: 'https://a/1', identity: 'ep:1'),
      Episode(id: '2', name: '第2集', url: 'https://a/2', identity: 'ep:2'),
      Episode(id: '3', name: '第3集', url: 'https://a/3', identity: 'ep:3'),
    ];
    expect(
      indexOfEpisode(
        episodes,
        const Episode(id: '9', name: '其他', url: '', identity: 'ep:2'),
      ),
      1,
    );
    expect(
      indexOfEpisode(
        episodes,
        const Episode(id: '9', name: '第3集', url: '', identity: 'missing'),
      ),
      2,
    );
    expect(
      indexOfEpisode(episodes, const Episode(id: '1', name: '其他', url: '')),
      0,
    );
    expect(
      indexOfEpisode(episodes, const Episode(id: 'x', name: '没有', url: '')),
      isNull,
    );
  });
}

final _source = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);
