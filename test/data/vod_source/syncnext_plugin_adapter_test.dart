import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/vod_source/adapters/syncnext_plugin_adapter.dart';
import 'package:jive/data/vod_source/adapters/syncnext_plugin_models.dart';
import 'package:jive/data/vod_source/adapters/syncnext_plugin_runtime.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_config.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';

const _configJson = {
  'name': '独播库',
  'host': 'https://www.dbku.tv',
  'files': ['txml.js', 'app.js'],
  'pages': [
    {
      'key': 'index',
      'title': '连续剧',
      'url': 'https://www.dbku.tv/vodtype/2--------\${pageNumber}---.html',
      'javascript': 'buildMedias',
    },
    {
      'key': 'movie',
      'title': '电影',
      'url': 'https://www.dbku.tv/vodtype/1--------\${pageNumber}---.html',
      'javascript': 'buildMedias',
    },
  ],
  'episodes': {'javascript': 'Episodes'},
  'player': {'javascript': 'Player'},
  'search': {
    'url': 'https://www.dbku.tv/vodsearch/-------------.html?wd=\${keyword}',
    'javascript': 'Search',
  },
};

final _source = VodSource(
  id: 'dbku',
  name: '独播库',
  baseUri: Uri.parse('https://www.dbku.tv'),
  adapterType: SyncnextPluginAdapter.adapterTypeName,
  pluginConfigUri: Uri.parse(
    'https://raw.githubusercontent.com/qoli/syncnextPlugin/main/plugin_dbku/config.json',
  ),
);

SyncnextPluginConfig _config() => SyncnextPluginConfig.fromJson(_configJson);

class _ScriptedSession implements SyncnextPluginSession {
  _ScriptedSession(this.config, this.handlers);

  @override
  final SyncnextPluginConfig config;
  final Map<String, PluginInvokeResult Function(String? url, String? key)>
  handlers;
  final calls = <String>[];

  @override
  Future<PluginInvokeResult> invoke(
    String functionName, {
    String? url,
    String? pluginKey,
    Duration? timeout,
  }) async {
    calls.add('$functionName|$url');
    final handler = handlers[functionName];
    if (handler == null) {
      return PluginInvokeResult(
        type: 'empty',
        payload: 'missing $functionName',
      );
    }
    return handler(url, pluginKey);
  }
}

void main() {
  test('parses plugin pages, search and player endpoints', () {
    final config = _config();
    expect(config.name, '独播库');
    expect(config.host, 'https://www.dbku.tv');
    expect(config.files, ['txml.js', 'app.js']);
    expect(config.pages.map((page) => page.title), ['连续剧', '电影']);
    expect(config.categories().map((item) => '${item.id}:${item.name}'), [
      '1:连续剧',
      '2:电影',
    ]);
    expect(config.pageFor(null)?.key, 'index');
    expect(config.pageFor(2)?.key, 'movie');
    expect(config.search?.javascript, 'Search');
    expect(config.episodes?.javascript, 'Episodes');
    expect(config.player?.javascript, 'Player');
  });

  test('fills page and keyword placeholders', () {
    expect(
      fillPluginTemplate(
        'https://www.dbku.tv/vodtype/2--------\${pageNumber}---.html',
        pageNumber: 3,
      ),
      'https://www.dbku.tv/vodtype/2--------3---.html',
    );
    expect(
      fillPluginTemplate(
        'https://www.dbku.tv/vodsearch/?wd=\${keyword}',
        keyword: '港剧',
      ),
      'https://www.dbku.tv/vodsearch/?wd=%E6%B8%AF%E5%89%A7',
    );
  });

  test('maps plugin media cards onto Video', () {
    final video = videoFromPluginMedia(_source, {
      'id': 'https://www.dbku.tv/voddetail/12.html',
      'title': '某剧',
      'coverURLString': 'https://img.example.com/a.jpg',
      'descriptionText': '更新至12',
      'detailURLString': 'https://www.dbku.tv/voddetail/12.html',
    }, typeId: 1);
    expect(video.title, '某剧');
    expect(video.sourceId, 'dbku');
    expect(video.sourceVideoId, 'https://www.dbku.tv/voddetail/12.html');
    expect(video.posterUrl, 'https://img.example.com/a.jpg');
    expect(video.remarks, '更新至12');
    expect(video.typeId, 1);
  });

  test('drops non-https media detail URLs', () {
    final video = videoFromPluginMedia(_source, {
      'id': '12',
      'title': '坏链',
      'detailURLString': 'http://www.dbku.tv/voddetail/12.html',
    });
    expect(video.sourceVideoId, '12');
  });

  test('maps a flat episode list to one playback line', () {
    final lines = playbackLinesFromPluginPayload([
      {
        'id': 'e1',
        'title': '第1集',
        'episodeDetailURL': 'https://www.dbku.tv/vodplay/1-1-1.html',
      },
      {
        'id': 'e2',
        'title': '第2集',
        'episodeDetailURL': 'https://www.dbku.tv/vodplay/1-1-2.html',
      },
    ]);
    expect(lines, hasLength(1));
    expect(lines.first.name, '默认');
    expect(lines.first.identity, 'plugin:line:default');
    expect(lines.first.episodes.map((item) => item.name), ['第1集', '第2集']);
    expect(lines.first.episodes.first.url, contains('/vodplay/1-1-1.html'));
  });

  test('keeps plugin-private episode handles for Player()', () {
    final lines = playbackLinesFromPluginPayload([
      {
        'id': 'e1',
        'title': '第1集',
        'episodeDetailURL': 'youknow-episode:%7B%22vodId%22%3A%221%22%7D',
      },
      {
        'id': 'e2',
        'title': '第2集',
        'episodeDetailURL':
            'syncnext-libvio://episode-candidates?data=%7B%22sources%22%3A%5B%5D%7D',
      },
      {
        'id': 'bad',
        'title': '坏链',
        'episodeDetailURL': 'http://www.dbku.tv/vodplay/1.html',
      },
    ]);
    expect(lines, hasLength(1));
    expect(lines.first.episodes.map((item) => item.name), ['第1集', '第2集']);
    expect(lines.first.episodes.first.url, startsWith('youknow-episode:'));
    expect(lines.first.episodes.last.url, startsWith('syncnext-libvio://'));
  });

  test('maps grouped episode candidates to playback lines', () {
    final lines = playbackLinesFromPluginPayload([
      {
        'name': '线路A',
        'id': 'a',
        'episodes': [
          {
            'title': '01',
            'episodeDetailURL': 'https://www.dbku.tv/vodplay/1-1-1.html',
          },
        ],
      },
      {
        'name': '线路B',
        'id': 'b',
        'episodes': [
          {
            'title': '01',
            'episodeDetailURL': 'https://www.dbku.tv/vodplay/1-2-1.html',
          },
        ],
      },
    ]);
    expect(lines.map((line) => line.name), ['线路A', '线路B']);
    expect(lines.map((line) => line.identity), [
      'plugin:line:a',
      'plugin:line:b',
    ]);
  });

  test('player JSON carries https url and headers', () {
    final source = playbackSourceFromPluginPlayer(
      const PluginInvokeResult(
        type: 'playerJson',
        payload:
            '{"url":"https://cdn.example.com/index.m3u8","headers":{"Referer":"https://www.dbku.tv/"}}',
      ),
      referer: Uri.parse('https://www.dbku.tv'),
    );
    expect(source.url.toString(), 'https://cdn.example.com/index.m3u8');
    expect(source.format, PlaybackFormat.hls);
    expect(source.headers['Referer'], 'https://www.dbku.tv/');
    expect(source.headers['User-Agent'], isNotEmpty);
  });

  test('player candidates pick the first https url', () {
    final source = playbackSourceFromPluginPlayer(
      const PluginInvokeResult(
        type: 'playerCandidates',
        payload:
            '[{"url":"http://bad.example/a.m3u8"},{"url":"https://cdn.example.com/b.m3u8"}]',
      ),
      referer: Uri.parse('https://www.dbku.tv'),
    );
    expect(source.url.toString(), 'https://cdn.example.com/b.m3u8');
  });

  test(
    'adapter catalog, search, detail and player use plugin callbacks',
    () async {
      late _ScriptedSession session;
      final adapter = SyncnextPluginAdapter(
        http.Client(),
        sessionFactory: ({required client, required pluginConfigUri}) async {
          session = _ScriptedSession(_config(), {
            'buildMedias': (url, _) => PluginInvokeResult(
              type: 'medias',
              payload: [
                {
                  'id': 'https://www.dbku.tv/voddetail/12.html',
                  'title': '某剧',
                  'detailURLString': 'https://www.dbku.tv/voddetail/12.html',
                  'coverURLString': 'https://img.example.com/a.jpg',
                  'descriptionText': '更新至12',
                },
              ],
            ),
            'Search': (url, key) => PluginInvokeResult(
              type: 'searchMedias',
              payload: [
                {
                  'id': 'https://www.dbku.tv/voddetail/99.html',
                  'title': '搜索剧',
                  'detailURLString': 'https://www.dbku.tv/voddetail/99.html',
                },
              ],
            ),
            'Episodes': (url, _) => PluginInvokeResult(
              type: 'episodes',
              payload: [
                {
                  'title': '第1集',
                  'episodeDetailURL': 'https://www.dbku.tv/vodplay/12-1-1.html',
                },
              ],
            ),
            'Player': (url, _) => const PluginInvokeResult(
              type: 'player',
              payload: 'https://cdn.example.com/12.m3u8',
            ),
          });
          return session;
        },
      );

      expect(
        (await adapter.fetchCategories(_source)).map((item) => item.name),
        ['连续剧', '电影'],
      );

      final page = await adapter.fetchPage(_source, page: 2, categoryId: 2);
      expect(page.items.single.title, '某剧');
      expect(page.pageCount, 3);
      expect(session.calls.single, contains('buildMedias|'));
      expect(session.calls.single, contains('vodtype/1--------2---.html'));

      final search = await adapter.fetchPage(_source, keyword: '港剧');
      expect(search.items.single.title, '搜索剧');
      expect(session.calls.last, contains('wd=%E6%B8%AF%E5%89%A7'));

      final detail = await adapter.resolvePlayback(
        _source,
        const VideoRef(
          sourceId: 'dbku',
          sourceVideoId: 'https://www.dbku.tv/voddetail/12.html',
        ),
      );
      expect(detail.episodes, hasLength(1));
      expect(detail.playbackLines.single.identity, 'plugin:line:default');
      expect(detail.episodes.single.url, contains('/vodplay/12-1-1.html'));

      final playable = await adapter.resolveEpisodePlayback(
        _source,
        'https://www.dbku.tv/vodplay/12-1-1.html',
      );
      expect(playable.url.toString(), 'https://cdn.example.com/12.m3u8');
      expect(playable.format, PlaybackFormat.hls);
    },
  );

  test('adapter rejects a non-https player result', () async {
    final adapter = SyncnextPluginAdapter(
      http.Client(),
      sessionFactory: ({required client, required pluginConfigUri}) async =>
          _ScriptedSession(_config(), {
            'Player': (url, _) =>
                const PluginInvokeResult(type: 'player', payload: 'http://x/a'),
          }),
    );
    await expectLater(
      adapter.resolveEpisodePlayback(_source, 'https://www.dbku.tv/play.html'),
      throwsA(isA<VideoDataException>()),
    );
  });

  test('adapter can resolve a plugin-private episode handle', () async {
    final adapter = SyncnextPluginAdapter(
      http.Client(),
      sessionFactory: ({required client, required pluginConfigUri}) async =>
          _ScriptedSession(_config(), {
            'Player': (url, _) => const PluginInvokeResult(
              type: 'player',
              payload: 'https://cdn.example.com/ok.m3u8',
            ),
          }),
    );
    final playable = await adapter.resolveEpisodePlayback(
      _source,
      'youknow-episode:%7B%22vodId%22%3A%221%22%7D',
    );
    expect(playable.url.toString(), 'https://cdn.example.com/ok.m3u8');
  });

  test('empty first catalog page is treated as a parse failure', () async {
    final adapter = SyncnextPluginAdapter(
      http.Client(),
      sessionFactory: ({required client, required pluginConfigUri}) async =>
          _ScriptedSession(_config(), {
            'buildMedias': (url, _) =>
                const PluginInvokeResult(type: 'medias', payload: []),
          }),
    );
    await expectLater(
      adapter.fetchPage(_source),
      throwsA(
        isA<VideoDataException>().having(
          (error) => error.message,
          'message',
          contains('访问验证'),
        ),
      ),
    );
  });

  test('plugin emptyView bubbles up as a data exception', () async {
    final adapter = SyncnextPluginAdapter(
      http.Client(),
      sessionFactory: ({required client, required pluginConfigUri}) async =>
          _ScriptedSession(_config(), {
            'buildMedias': (url, _) => const PluginInvokeResult(
              type: 'empty',
              payload: '無法載入內容，請稍後再試',
            ),
          }),
    );
    await expectLater(
      adapter.fetchPage(_source),
      throwsA(
        isA<VideoDataException>().having(
          (error) => error.message,
          'message',
          contains('無法載入內容'),
        ),
      ),
    );
  });

  test('plugin sources without https config uri are not loadable', () {
    expect(VodSourceConfig.isLoadable(_source), isTrue);
    expect(
      VodSourceConfig.isLoadable(
        VodSource(
          id: 'dbku',
          name: '独播库',
          baseUri: Uri.parse('https://www.dbku.tv'),
          adapterType: SyncnextPluginAdapter.adapterTypeName,
        ),
      ),
      isFalse,
    );
  });

  test('github raw plugin uris get jsdelivr mirrors', () {
    final github = Uri.parse(
      'https://raw.githubusercontent.com/qoli/syncnextPlugin/main/plugin_dbku/config.json',
    );
    expect(pluginResourceCandidates(github).map((uri) => '$uri'), [
      '$github',
      'https://cdn.jsdelivr.net/gh/qoli/syncnextPlugin@main/plugin_dbku/config.json',
      'https://cdn.jsdmirror.com/gh/qoli/syncnextPlugin@main/plugin_dbku/config.json',
    ]);
    final site = Uri.parse('https://www.dbku.tv/vodtype/2.html');
    expect(pluginResourceCandidates(site), [site]);
  });

  test('bundle load falls back to jsdelivr when github cert fails', () async {
    final requested = <String>[];
    final client = MockClient((request) async {
      requested.add('${request.url}');
      if (request.url.host == 'raw.githubusercontent.com') {
        throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
      }
      if (request.url.host != 'cdn.jsdelivr.net') {
        return http.Response('missing', 404);
      }
      final name = request.url.pathSegments.last;
      if (name == 'config.json') {
        return http.Response.bytes(utf8.encode(jsonEncode(_configJson)), 200);
      }
      if (name == 'txml.js') {
        return http.Response('function tXml(){}', 200);
      }
      if (name == 'app.js') {
        return http.Response('function buildMedias(){}', 200);
      }
      return http.Response('missing', 404);
    });

    final bundle = await SyncnextPluginBundle.load(
      client,
      _source.pluginConfigUri!,
    );
    expect(bundle.config.name, '独播库');
    expect(bundle.scripts.map((script) => script.name), ['txml.js', 'app.js']);
    expect(requested.any((url) => url.contains('cdn.jsdelivr.net')), isTrue);
  });
}
