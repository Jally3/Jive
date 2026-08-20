import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/playback_selection.dart';
import '../../domain/playback_source.dart';
import '../../domain/video.dart';

class PlaybackUrlResolutionException implements Exception {
  const PlaybackUrlResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PlaybackUrlResolver {
  PlaybackUrlResolver({required this.client, this.maxHtmlBytes = 128 * 1024});

  final http.Client client;
  final int maxHtmlBytes;
  final Map<String, ({PlaybackSource source, DateTime at})> _cache = {};

  /// Removes the cached resolution for one original playback URL.
  void clearCacheFor(Uri url) => _cache.remove(url.toString());

  /// Removes every cached playback URL resolution held by this resolver.
  void clearCache() => _cache.clear();

  Future<PlaybackSelection> resolveSelection(
    PlaybackSelection selection,
  ) async {
    final source = await resolve(selection.playbackSource);
    if (source == selection.playbackSource) return selection;
    final episode = Episode(
      id: selection.episode.id,
      name: selection.episode.name,
      url: source.url.toString(),
      identity: selection.episode.identity,
    );
    return PlaybackSelection(
      sourceId: selection.sourceId,
      sourceVideoId: selection.sourceVideoId,
      title: selection.title,
      playbackLineIdentity: selection.playbackLineIdentity,
      episodeIdentity: selection.episodeIdentity,
      episode: episode,
      playbackSource: source,
    );
  }

  Future<PlaybackSource> resolve(PlaybackSource source) async {
    if (source.format != PlaybackFormat.unknown) return source;
    final cached = _cache[source.url.toString()];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 10)) {
      return cached.source;
    }
    try {
      final resolved = await _resolveUnknown(source);
      _cache[source.url.toString()] = (source: resolved, at: DateTime.now());
      return resolved;
    } on PlaybackUrlResolutionException {
      rethrow;
    } catch (_) {
      // http can surface transport failures as TimeoutException,
      // ClientException, SocketException, or platform-specific exceptions.
      // Keep that implementation detail out of the player state machine.
      throw const PlaybackUrlResolutionException('播放地址请求失败，请检查网络后重试');
    }
  }

  Future<PlaybackSource> _resolveUnknown(PlaybackSource source) async {
    final initial = source.url;
    if (!_isAllowed(initial)) {
      throw const PlaybackUrlResolutionException('播放地址不安全或不受支持');
    }
    final response = await client
        .get(
          initial,
          headers: {
            ...filterSessionHeaders(source.headers),
            'range': 'bytes=0-${maxHtmlBytes - 1}',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw const PlaybackUrlResolutionException('播放地址请求失败');
    }
    final finalUri = response.request?.url ?? initial;
    final directFormat = _formatFrom(
      finalUri,
      response.headers['content-type'] ?? '',
      response.bodyBytes,
    );
    if (directFormat != PlaybackFormat.unknown) {
      return source.copyWith(url: finalUri, format: directFormat);
    }
    if (response.bodyBytes.length > maxHtmlBytes) {
      throw const PlaybackUrlResolutionException('播放页面内容过大，无法解析');
    }
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.contains('html')) {
      throw const PlaybackUrlResolutionException('无法识别视频格式');
    }
    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    final candidate = _bestMediaCandidate(html, finalUri);
    if (candidate == null) {
      throw const PlaybackUrlResolutionException('播放页面中没有可用视频地址');
    }
    final hintedFormat = _formatFrom(candidate, '', const []);
    if (hintedFormat != PlaybackFormat.unknown) {
      final head = await client
          .head(candidate, headers: filterSessionHeaders(source.headers))
          .timeout(const Duration(seconds: 8));
      if (head.statusCode < 200 || head.statusCode >= 400) {
        throw const PlaybackUrlResolutionException('真实视频地址不可用');
      }
      return source.copyWith(
        url: head.request?.url ?? candidate,
        format: hintedFormat,
      );
    }
    final media = await client
        .get(
          candidate,
          headers: {
            ...filterSessionHeaders(source.headers),
            'range': 'bytes=0-511',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (media.statusCode < 200 || media.statusCode >= 400) {
      throw const PlaybackUrlResolutionException('真实视频地址不可用');
    }
    final mediaUri = media.request?.url ?? candidate;
    final format = _formatFrom(
      mediaUri,
      media.headers['content-type'] ?? '',
      media.bodyBytes,
    );
    if (format == PlaybackFormat.unknown) {
      throw const PlaybackUrlResolutionException('真实视频格式无法识别');
    }
    return source.copyWith(url: mediaUri, format: format);
  }

  Uri? _bestMediaCandidate(String html, Uri baseUri) {
    final decoded = html.replaceAll('&amp;', '&');
    final patterns = <RegExp>[
      RegExp(
        r'''(?:const|let|var)\s+(?:vid|url|videoUrl)\s*=\s*['"]([^'"]+)['"]''',
        caseSensitive: false,
      ),
      RegExp(r'''(?:url|src)\s*:\s*['"]([^'"]+)['"]''', caseSensitive: false),
      RegExp(
        r'''<(?:video|source)[^>]+src\s*=\s*['"]([^'"]+)['"]''',
        caseSensitive: false,
      ),
    ];
    final candidates = <Uri>[];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(decoded)) {
        final raw = match.group(1)?.trim();
        if (raw == null || raw.isEmpty) continue;
        final candidate = baseUri.resolve(raw);
        if (_isAllowed(candidate)) candidates.add(candidate);
      }
    }
    candidates.sort((a, b) => _score(b).compareTo(_score(a)));
    return candidates.firstOrNull;
  }

  static int _score(Uri uri) {
    final lower = uri.toString().toLowerCase();
    if (lower.contains('.m3u8')) return 30;
    if (lower.contains('.mp4')) return 20;
    if (lower.contains('.mpd')) return 10;
    return 0;
  }

  static bool _isAllowed(Uri uri) =>
      uri.scheme == 'https' && uri.host.isNotEmpty;

  static PlaybackFormat _formatFrom(
    Uri uri,
    String contentType,
    List<int> bytes,
  ) {
    final lower = uri.toString().toLowerCase();
    final type = contentType.toLowerCase();
    if (lower.contains('.m3u8') || type.contains('mpegurl')) {
      return PlaybackFormat.hls;
    }
    if (lower.contains('.mp4') || type.contains('video/mp4')) {
      return PlaybackFormat.mp4;
    }
    if (lower.contains('.mpd') || type.contains('dash+xml')) {
      return PlaybackFormat.dash;
    }
    final head = utf8.decode(bytes.take(256).toList(), allowMalformed: true);
    if (head.trimLeft().startsWith('#EXTM3U')) return PlaybackFormat.hls;
    if (bytes.length >= 8 &&
        ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp') {
      return PlaybackFormat.mp4;
    }
    if (head.contains('<MPD')) return PlaybackFormat.dash;
    return PlaybackFormat.unknown;
  }
}
