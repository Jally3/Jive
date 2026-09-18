import 'package:http/http.dart' as http;
import '../../domain/playback_source.dart';

/// 通过响应头和少量文件头字节识别远程播放资源的格式。
class ContentTypeSniffer {
  /// [ttl] 控制同一 URL 的识别结果在内存中的有效时间。
  ContentTypeSniffer({this.ttl = const Duration(minutes: 10)});

  /// 格式识别缓存的有效期。
  final Duration ttl;
  final Map<String, _Sniffed> _cache = {};

  /// 识别 [url] 对应的媒体格式。
  ///
  /// 优先使用 HEAD 响应的 Content-Type/Content-Disposition；无法判断时，
  /// 再下载前 512 字节并检查 HLS、MP4、DASH 的文件特征。
  Future<PlaybackFormat> sniff(String url) async {
    final cached = _cache[url];
    if (cached != null) {
      if (DateTime.now().difference(cached.at) < ttl) {
        return cached.format;
      }
      _cache.remove(url);
    }
    PlaybackFormat format = PlaybackFormat.unknown;
    try {
      final response = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      final ct = response.headers['content-type'] ?? '';
      format = _fromContentType(ct);
      if (format == PlaybackFormat.unknown) {
        format = _fromContentDisposition(
          response.headers['content-disposition'] ?? '',
        );
      }
    } catch (_) {
      format = PlaybackFormat.unknown;
    }
    if (format == PlaybackFormat.unknown) {
      format = await _sniffBytes(url);
    }
    _cache[url] = _Sniffed(format);
    return format;
  }

  /// 通过 Range 请求读取文件头；网络异常时安全回退为 unknown。
  Future<PlaybackFormat> _sniffBytes(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url), headers: {'Range': 'bytes=0-511'})
          .timeout(const Duration(seconds: 5));
      final body = response.bodyBytes;
      if (body.isEmpty) return PlaybackFormat.unknown;
      return _fromMagicBytes(body);
    } catch (_) {
      return PlaybackFormat.unknown;
    }
  }

  /// 根据 [bytes] 的魔数或文本头判断媒体格式。
  PlaybackFormat _fromMagicBytes(List<int> bytes) {
    if (bytes.length < 4) return PlaybackFormat.unknown;

    final head = String.fromCharCodes(bytes.take(256));
    if (head.startsWith('#EXTM3U')) return PlaybackFormat.hls;

    if (bytes.length >= 8) {
      final ftyp = String.fromCharCodes(bytes.sublist(4, 8));
      if (ftyp.startsWith('ftyp')) return PlaybackFormat.mp4;
    }

    if (head.startsWith('<?xml') && head.contains('<MPD')) {
      return PlaybackFormat.dash;
    }
    return PlaybackFormat.unknown;
  }

  /// 将服务端 Content-Type 映射为应用内播放格式。
  PlaybackFormat _fromContentType(String ct) {
    final lower = ct.toLowerCase();
    if (lower.contains('application/vnd.apple.mpegurl') ||
        lower.contains('application/x-mpegurl') ||
        lower.contains('audio/mpegurl')) {
      return PlaybackFormat.hls;
    }
    if (lower.contains('video/mp4') || lower.contains('audio/mp4')) {
      return PlaybackFormat.mp4;
    }
    if (lower.contains('application/dash+xml') ||
        lower.contains('video/vnd.mpeg.dash.mpd')) {
      return PlaybackFormat.dash;
    }
    return PlaybackFormat.unknown;
  }

  /// 从下载文件名相关的 Content-Disposition 中推断格式。
  PlaybackFormat _fromContentDisposition(String cd) {
    final lower = cd.toLowerCase();
    if (lower.contains('.m3u8')) return PlaybackFormat.hls;
    if (lower.contains('.mp4')) return PlaybackFormat.mp4;
    if (lower.contains('.mpd')) return PlaybackFormat.dash;
    return PlaybackFormat.unknown;
  }
}

/// 一条带创建时间的内存识别缓存记录。
class _Sniffed {
  _Sniffed(this.format) : at = DateTime.now();
  final PlaybackFormat format;
  final DateTime at;
}
