import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/playback_selection.dart';
import '../../domain/playback_source.dart';
import '../../domain/video.dart';

/// 播放页解析失败时抛出的面向用户异常，避免泄露底层网络异常细节。
class PlaybackUrlResolutionException implements Exception {
  const PlaybackUrlResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 将格式未知的播放页 URL 解析成可直接播放的 HTTPS 媒体 URL。
class PlaybackUrlResolver {
  /// [client] 由上层注入，便于复用会话 Header 和编写网络测试。
  /// [maxHtmlBytes] 限制解析页大小，避免把大型二进制误当 HTML 处理。
  PlaybackUrlResolver({required this.client, this.maxHtmlBytes = 128 * 1024});

  final http.Client client;
  final int maxHtmlBytes;
  final Map<String, ({PlaybackSource source, DateTime at})> _cache = {};

  /// 清除一个原始播放 URL 的解析缓存。
  void clearCacheFor(Uri url) => _cache.remove(url.toString());

  /// 清除当前解析器持有的全部 URL 解析缓存。
  void clearCache() => _cache.clear();

  /// 解析 [selection] 中的播放源，并在 URL 变化时同步重建 Episode。
  ///
  /// 选择对象里的来源、线路和剧集身份保持不变，仅替换可播放地址与格式。
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

  /// 解析一个播放源；已知格式直接返回，未知格式使用 10 分钟内存缓存。
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

  /// 请求未知地址：若响应本身不是媒体，则把它作为 HTML 解析页提取候选 URL。
  Future<PlaybackSource> _resolveUnknown(PlaybackSource source) async {
    final initial = source.url;
    if (!_isAllowed(initial)) {
      throw const PlaybackUrlResolutionException('播放地址不安全或不受支持');
    }
    // HTML 解析页（AGE jx 等）常用 chunked 传输。带 Range 在 iOS 上会一直等到超时。
    // Range 只用于后面的媒体探测，见 _rangeGetMedia。
    final isAgeResolver = initial.toString().contains('/m3u8/?url=');
    final htmlHeaders = filterSessionHeaders(source.headers);
    if (isAgeResolver) {
      // AGE 插件拉解析页时不带 Referer/Origin，避免解析站异常等待。
      htmlHeaders.removeWhere((key, _) {
        final name = key.toLowerCase();
        return name == 'referer' || name == 'origin';
      });
    }
    final response = await client
        .get(initial, headers: htmlHeaders)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw PlaybackUrlResolutionException('解析页请求失败（${response.statusCode}）');
    }
    final finalUri = response.request?.url ?? initial;
    final directFormat = _formatFrom(
      finalUri,
      response.headers['content-type'] ?? '',
      response.bodyBytes,
    );
    if (directFormat != PlaybackFormat.unknown) {
      return _finalSource(source, finalUri, directFormat);
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
      throw const PlaybackUrlResolutionException('解析页中没有可用播放地址');
    }
    final hintedFormat = _formatFrom(candidate, '', const []);
    if (hintedFormat != PlaybackFormat.unknown) {
      // AGE 已抽出带扩展名的 m3u8，再 HEAD 容易被 CDN 卡住；直接交给播放器。
      if (isAgeResolver) {
        return _finalSource(source, candidate, hintedFormat);
      }
      return _probeHintedMedia(source, candidate, hintedFormat);
    }
    return _rangeGetMedia(source, candidate, hintedFormat);
  }

  /// 对已有扩展名提示的 [candidate] 先发 HEAD，失败后再用 Range GET 探测。
  Future<PlaybackSource> _probeHintedMedia(
    PlaybackSource source,
    Uri candidate,
    PlaybackFormat hintedFormat,
  ) async {
    try {
      final head = await client
          .head(candidate, headers: filterSessionHeaders(source.headers))
          .timeout(const Duration(seconds: 8));
      if (head.statusCode >= 200 && head.statusCode < 400) {
        return _finalSource(
          source,
          head.request?.url ?? candidate,
          hintedFormat,
        );
      }
    } catch (_) {
      // HEAD 502/405/timeout: fall through to a ranged GET probe.
    }
    return _rangeGetMedia(source, candidate, hintedFormat);
  }

  /// 下载 [candidate] 的前 512 字节，结合最终重定向 URL 和响应头确认格式。
  Future<PlaybackSource> _rangeGetMedia(
    PlaybackSource source,
    Uri candidate,
    PlaybackFormat hintedFormat,
  ) async {
    final media = await client
        .get(
          candidate,
          headers: {
            ...filterSessionHeaders(source.headers),
            'range': 'bytes=0-511',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (media.statusCode != 200 && media.statusCode != 206) {
      throw const PlaybackUrlResolutionException('真实视频地址不可用');
    }
    final mediaUri = media.request?.url ?? candidate;
    final format = _formatFrom(
      mediaUri,
      media.headers['content-type'] ?? '',
      media.bodyBytes,
    );
    final resolvedFormat = format == PlaybackFormat.unknown
        ? hintedFormat
        : format;
    if (resolvedFormat == PlaybackFormat.unknown) {
      throw const PlaybackUrlResolutionException('真实视频格式无法识别');
    }
    return _finalSource(source, mediaUri, resolvedFormat);
  }

  /// 保留原播放源的 Header，仅替换最终 [url] 和已确认的 [format]。
  PlaybackSource _finalSource(
    PlaybackSource source,
    Uri url,
    PlaybackFormat format,
  ) => source.copyWith(
    url: url,
    format: format,
    headers: Map<String, String>.from(source.headers),
  );

  /// 从 HTML 中收集常见脚本变量、url/src 字段和 video/source 标签地址。
  ///
  /// 仅保留 HTTPS 候选，并优先选择 HLS，其次 MP4、DASH。
  Uri? _bestMediaCandidate(String html, Uri baseUri) {
    final decoded = html.replaceAll('&amp;', '&');
    final patterns = <RegExp>[
      RegExp(
        r'''(?:const|let|var)\s+(?:vid|url|videoUrl|Vurl)\s*=\s*['"]([^'"]+)['"]''',
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

  /// 按应用偏好的媒体格式给候选地址评分。
  static int _score(Uri uri) {
    final lower = uri.toString().toLowerCase();
    if (lower.contains('.m3u8')) return 30;
    if (lower.contains('.mp4')) return 20;
    if (lower.contains('.mpd')) return 10;
    return 0;
  }

  static bool _isAllowed(Uri uri) =>
      uri.scheme == 'https' && uri.host.isNotEmpty;

  /// 综合 URL 后缀、Content-Type 与文件头魔数识别播放格式。
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
