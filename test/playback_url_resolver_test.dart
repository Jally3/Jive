import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/cache/playback_url_resolver.dart';
import 'package:jive/domain/playback_selection.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:jive/domain/video.dart';

void main() {
  test('resolves an HTML player page to its real HLS URL', () async {
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        expect(request.url.path, '/play/token/index.m3u8');
        return http.Response(
          '',
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      expect(request.url.path, '/play/token');
      return http.Response(
        '''<html><script>const vid = '/play/token/index.m3u8';</script></html>''',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });
    final resolver = PlaybackUrlResolver(client: client);
    const episode = Episode(
      id: '1',
      name: '第1集',
      url: 'https://v.example.com/play/token',
      identity: 'episode:1',
    );
    final resolved = await resolver.resolveSelection(
      PlaybackSelection(
        sourceId: 'source',
        sourceVideoId: 'video',
        title: '影片',
        playbackLineIdentity: 'line',
        episodeIdentity: episode.identity,
        episode: episode,
        playbackSource: PlaybackSource(
          url: Uri.parse(episode.url),
          format: PlaybackFormat.unknown,
        ),
      ),
    );

    expect(
      resolved.playbackSource.url,
      Uri.parse('https://v.example.com/play/token/index.m3u8'),
    );
    expect(resolved.playbackSource.format, PlaybackFormat.hls);
    expect(resolved.episode.url, resolved.playbackSource.url.toString());
    client.close();
  });

  test('rejects an HTML page without a media candidate', () async {
    final resolver = PlaybackUrlResolver(
      client: MockClient(
        (_) async => http.Response(
          '<html>no player</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      ),
    );

    expect(
      () => resolver.resolve(
        PlaybackSource(url: Uri.parse('https://v.example.com/play/token')),
      ),
      throwsA(isA<PlaybackUrlResolutionException>()),
    );
  });
}
