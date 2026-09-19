import 'dart:collection';

enum PlaybackFormat { unknown, hls, mp4, dash }

String playbackFormatLabel(PlaybackFormat format) => switch (format) {
  PlaybackFormat.hls => 'HLS (m3u8)',
  PlaybackFormat.mp4 => 'MP4',
  PlaybackFormat.dash => 'DASH (mpd)',
  PlaybackFormat.unknown => '未知格式',
};

class PlaybackSource {
  PlaybackSource({
    required this.url,
    this.format = PlaybackFormat.unknown,
    Map<String, String> headers = const {},
  }) : _headers = UnmodifiableMapView(Map<String, String>.from(headers));

  final Uri url;
  final PlaybackFormat format;
  final Map<String, String> _headers;

  Map<String, String> get headers => _headers;

  PlaybackSource copyWith({
    Uri? url,
    PlaybackFormat? format,
    Map<String, String>? headers,
  }) => PlaybackSource(
    url: url ?? this.url,
    format: format ?? this.format,
    headers: headers ?? this.headers,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackSource && url == other.url && format == other.format;

  @override
  int get hashCode => Object.hash(url, format);
}

/// 会话头黑名单：只剔除破坏代理请求框架或由 HTTP 客户端自动管理的头。
/// 源站/插件声明的鉴权头（Authorization、Cookie、自定义令牌）必须原样
/// 到达媒体上游，因此不能按白名单过滤。
const Set<String> sessionHeaderDenylist = {
  // 请求框架与逐跳头：代理按目标地址重建请求，这些头必须重新生成。
  'host',
  'content-length',
  'transfer-encoding',
  'connection',
  'keep-alive',
  'upgrade',
  'te',
  'trailer',
  'proxy-connection',
  // 由 http 客户端自动管理：显式声明会关闭透明解压并污染缓存完整性校验。
  'accept-encoding',
  // Range 语义由本地代理/缓存层自己处理，源站声明的 Range 会破坏整片缓存。
  'range',
};

const Set<String> downstreamHeaderWhitelist = {
  'range',
  'if-range',
  'if-none-match',
  'if-modified-since',
};

Map<String, String> filterSessionHeaders(Map<String, String> headers) =>
    _filterDenied(headers, sessionHeaderDenylist);

Map<String, String> filterDownstreamHeaders(Map<String, String> headers) =>
    _filter(headers, downstreamHeaderWhitelist);

Map<String, String> _filter(
  Map<String, String> headers,
  Set<String> whitelist,
) {
  final filtered = <String, String>{};
  for (final entry in headers.entries) {
    if (whitelist.contains(entry.key.toLowerCase())) {
      filtered[entry.key] = entry.value;
    }
  }
  return filtered;
}

Map<String, String> _filterDenied(
  Map<String, String> headers,
  Set<String> denylist,
) {
  final filtered = <String, String>{};
  for (final entry in headers.entries) {
    if (!denylist.contains(entry.key.toLowerCase())) {
      filtered[entry.key] = entry.value;
    }
  }
  return filtered;
}
