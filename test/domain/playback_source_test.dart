import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/playback_source.dart';

void main() {
  group('filterSessionHeaders', () {
    test('keeps media headers declared by the source or plugin', () {
      final filtered = filterSessionHeaders({
        'User-Agent': 'Jive/1.0',
        'Referer': 'https://origin.example.com/watch',
        'Origin': 'https://origin.example.com',
        'Accept': '*/*',
        'Accept-Language': 'zh-CN',
        // 插件可能声明的鉴权与自定义头，必须原样到达源站。
        'Authorization': 'Bearer token-123',
        'Cookie': 'session=abc',
        'X-Auth-Token': 'custom-token',
      });
      expect(filtered, {
        'User-Agent': 'Jive/1.0',
        'Referer': 'https://origin.example.com/watch',
        'Origin': 'https://origin.example.com',
        'Accept': '*/*',
        'Accept-Language': 'zh-CN',
        'Authorization': 'Bearer token-123',
        'Cookie': 'session=abc',
        'X-Auth-Token': 'custom-token',
      });
    });

    test('drops headers that break proxy request framing', () {
      final filtered = filterSessionHeaders({
        'Host': 'origin.example.com',
        'Content-Length': '123',
        'Transfer-Encoding': 'chunked',
        'Connection': 'keep-alive',
        'Keep-Alive': 'timeout=5',
        'Accept-Encoding': 'gzip',
        'Range': 'bytes=0-99',
        'Upgrade': 'h2c',
        'TE': 'trailers',
        'Trailer': 'X-Sum',
        'Proxy-Connection': 'keep-alive',
      });
      expect(filtered, isEmpty);
    });
  });

  group('filterDownstreamHeaders', () {
    test('keeps only conditional and range headers from the player', () {
      final filtered = filterDownstreamHeaders({
        'Range': 'bytes=0-99',
        'If-Range': '"v1"',
        'If-None-Match': '"etag"',
        'If-Modified-Since': 'Wed, 01 Jan 2025 00:00:00 GMT',
        // 播放器注入的无关头不得透传到源站。
        'Authorization': 'Bearer leaked',
        'Cookie': 'leaked=1',
        'User-Agent': 'player-ua',
        'X-Junk': 'junk',
      });
      expect(filtered.keys.toSet(), {
        'Range',
        'If-Range',
        'If-None-Match',
        'If-Modified-Since',
      });
    });
  });
}
