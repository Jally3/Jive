import 'dart:collection';

enum PlaybackFormat { unknown, hls, mp4, dash }

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

const Set<String> sessionHeaderWhitelist = {
  'accept',
  'accept-language',
  'origin',
  'referer',
  'user-agent',
};

const Set<String> downstreamHeaderWhitelist = {
  'range',
  'if-range',
  'if-none-match',
  'if-modified-since',
};

Map<String, String> filterSessionHeaders(Map<String, String> headers) =>
    _filter(headers, sessionHeaderWhitelist);

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
