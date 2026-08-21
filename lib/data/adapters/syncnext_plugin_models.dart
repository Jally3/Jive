import 'dart:convert';
import '../../domain/playback_selection.dart';
import '../../domain/playback_source.dart';
import '../../domain/video.dart';
import '../../domain/vod_source.dart';

const pluginUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';

class SyncnextPluginPage {
  const SyncnextPluginPage({
    required this.key,
    required this.title,
    required this.url,
    required this.javascript,
    this.timeout = const Duration(seconds: 20),
  });

  final String key;
  final String title;
  final String url;
  final String javascript;
  final Duration timeout;

  bool get hasPageNumber => url.contains(r'${pageNumber}');
}

class SyncnextPluginEndpoint {
  const SyncnextPluginEndpoint({
    required this.javascript,
    this.url = '',
    this.timeout = const Duration(seconds: 20),
  });

  final String javascript;
  final String url;
  final Duration timeout;
}

class SyncnextPluginConfig {
  const SyncnextPluginConfig({
    required this.name,
    required this.host,
    required this.files,
    required this.pages,
    this.notification = '',
    this.search,
    this.episodes,
    this.player,
  });

  final String name;
  final String host;
  final List<String> files;
  final List<SyncnextPluginPage> pages;
  final String notification;
  final SyncnextPluginEndpoint? search;
  final SyncnextPluginEndpoint? episodes;
  final SyncnextPluginEndpoint? player;

  factory SyncnextPluginConfig.fromJson(Map<String, dynamic> json) {
    final pages = <SyncnextPluginPage>[];
    final rawPages = json['pages'];
    if (rawPages is List) {
      for (final item in rawPages) {
        if (item is! Map) continue;
        final page = Map<String, dynamic>.from(item);
        final javascript = _str(page['javascript']);
        final url = _str(page['url']);
        if (javascript.isEmpty || url.isEmpty) continue;
        pages.add(
          SyncnextPluginPage(
            key: _str(page['key'], fallback: 'page${pages.length}'),
            title: _str(page['title'], fallback: '分类'),
            url: url,
            javascript: javascript,
            timeout: _timeout(page['timeout']),
          ),
        );
      }
    }
    return SyncnextPluginConfig(
      name: _str(json['name'], fallback: '插件源'),
      host: _str(json['host']),
      files: [
        for (final file in _asList(json['files']))
          if (_str(file).isNotEmpty) _str(file),
      ],
      pages: pages,
      notification: _str(json['notification']),
      search: _endpoint(json['search'], requireUrl: true),
      episodes: _endpoint(json['episodes']),
      player: _endpoint(json['player']),
    );
  }

  List<VideoCategory> categories() => [
    for (var i = 0; i < pages.length; i++)
      VideoCategory(id: i + 1, name: pages[i].title),
  ];

  SyncnextPluginPage? pageFor(int? categoryId) {
    if (pages.isEmpty) return null;
    if (categoryId == null || categoryId < 1 || categoryId > pages.length) {
      return pages.first;
    }
    return pages[categoryId - 1];
  }
}

class PluginInvokeResult {
  const PluginInvokeResult({required this.type, this.payload});

  final String type;
  final Object? payload;

  bool get isEmptyView => type == 'empty';
  bool get isMedias => type == 'medias' || type == 'searchMedias';
  bool get isEpisodes => type == 'episodes' || type == 'episodesCandidates';
  bool get isPlayer =>
      type == 'player' || type == 'playerJson' || type == 'playerCandidates';
}

String fillPluginTemplate(String template, {int? pageNumber, String? keyword}) {
  var url = template;
  if (pageNumber != null) {
    url = url.replaceAll(r'${pageNumber}', '$pageNumber');
  }
  if (keyword != null) {
    url = url.replaceAll(r'${keyword}', Uri.encodeComponent(keyword));
  }
  return url;
}

int pluginPageCount({
  required bool hasPager,
  required int page,
  required int itemCount,
}) {
  if (!hasPager) return page;
  return itemCount == 0 ? page : page + 1;
}

Video videoFromPluginMedia(
  VodSource source,
  Map<String, dynamic> item, {
  int typeId = 0,
}) {
  final detailUrl = _httpsOrEmpty(
    _str(item['detailURLString'], fallback: _str(item['detailURL'])),
  );
  final id = _str(item['id'], fallback: detailUrl);
  final sourceVideoId = detailUrl.isNotEmpty ? detailUrl : id;
  return Video(
    id: id.isNotEmpty ? id : sourceVideoId,
    title: _str(item['title'], fallback: _fallbackTitle(sourceVideoId)),
    sourceId: source.id,
    sourceVideoId: sourceVideoId,
    posterUrl: _httpsOrEmpty(_str(item['coverURLString'])),
    typeId: typeId,
    remarks: _str(item['descriptionText']),
    description: _str(item['descriptionText']),
  );
}

List<PlaybackLine> playbackLinesFromPluginPayload(Object? payload) {
  final decoded = decodePluginJson(payload);
  if (decoded is List) {
    if (decoded.isEmpty) return const [];
    final first = decoded.first;
    if (first is Map && first['episodes'] is List) {
      return [
        for (var i = 0; i < decoded.length; i++)
          if (decoded[i] is Map)
            _lineFromGroup(Map<String, dynamic>.from(decoded[i] as Map), i),
      ].where((line) => line.episodes.isNotEmpty).toList();
    }
    final episodes = episodesFromPluginPayload(decoded);
    if (episodes.isEmpty) return const [];
    return [
      PlaybackLine(
        id: '0',
        name: '默认',
        episodes: episodes,
        identity: 'plugin:line:default',
      ),
    ];
  }
  if (decoded is Map) {
    final map = Map<String, dynamic>.from(decoded);
    if (map['episodes'] is List) {
      final line = _lineFromGroup(map, 0);
      return line.episodes.isEmpty ? const [] : [line];
    }
    final groups = map['candidates'] ?? map['lines'] ?? map['playlists'];
    if (groups is List) {
      return playbackLinesFromPluginPayload(groups);
    }
  }
  return const [];
}

List<Episode> episodesFromPluginPayload(Object? payload) {
  final decoded = decodePluginJson(payload);
  if (decoded is! List) return const [];
  final episodes = <Episode>[];
  var slot = 0;
  for (final item in decoded) {
    if (item is! Map) continue;
    final map = Map<String, dynamic>.from(item);
    final url = pluginEpisodeHandle(
      _str(
        map['episodeDetailURL'],
        fallback: _str(map['url'], fallback: _str(map['id'])),
      ),
    );
    if (url.isEmpty) continue;
    slot += 1;
    final title = _str(map['title'], fallback: '第$slot集');
    episodes.add(
      Episode(
        id: _str(map['id'], fallback: url),
        name: title,
        url: url,
        identity: 'plugin:episode:$url',
      ),
    );
  }
  return episodes;
}

PlaybackSource playbackSourceFromPluginPlayer(
  PluginInvokeResult result, {
  required Uri referer,
}) {
  final headers = <String, String>{
    'User-Agent': pluginUserAgent,
    if (referer.hasScheme) 'Referer': '$referer',
  };
  var url = '';
  switch (result.type) {
    case 'player':
      url = _httpsOrEmpty('${result.payload ?? ''}');
    case 'playerJson':
      final data = _asStringKeyedMap(decodePluginJson(result.payload));
      url = _httpsOrEmpty(_str(data['url']));
      _mergeHeaders(headers, data['headers']);
    case 'playerCandidates':
      final candidates = decodePluginJson(result.payload);
      if (candidates is List) {
        for (final item in candidates) {
          if (item is! Map) continue;
          final data = Map<String, dynamic>.from(item);
          final candidateUrl = _httpsOrEmpty(_str(data['url']));
          if (candidateUrl.isEmpty) continue;
          url = candidateUrl;
          _mergeHeaders(headers, data['headers']);
          break;
        }
      }
    default:
      url = '';
  }
  final uri = Uri.tryParse(url) ?? Uri();
  return PlaybackSource(
    url: uri,
    format: inferPlaybackFormat(url),
    headers: headers,
  );
}

Object? decodePluginJson(Object? payload) {
  if (payload == null) return null;
  if (payload is String) {
    final text = payload.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return payload;
    }
  }
  return payload;
}

PlaybackLine _lineFromGroup(Map<String, dynamic> group, int index) {
  final name = _str(
    group['name'],
    fallback: _str(group['title'], fallback: '线路${index + 1}'),
  );
  final key = _str(
    group['id'],
    fallback: _str(group['key'], fallback: '$index'),
  );
  return PlaybackLine(
    id: '$index',
    name: name,
    episodes: episodesFromPluginPayload(group['episodes']),
    identity: 'plugin:line:$key',
  );
}

void _mergeHeaders(Map<String, String> target, Object? raw) {
  if (raw is! Map) return;
  for (final entry in raw.entries) {
    final name = '${entry.key}'.trim();
    final value = '${entry.value}'.trim();
    if (name.isEmpty || value.isEmpty) continue;
    target[name] = value;
  }
}

Map<String, dynamic> _asStringKeyedMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return const {};
}

SyncnextPluginEndpoint? _endpoint(Object? raw, {bool requireUrl = false}) {
  if (raw is! Map) return null;
  final map = Map<String, dynamic>.from(raw);
  final javascript = _str(map['javascript']);
  if (javascript.isEmpty) return null;
  final url = _str(map['url']);
  if (requireUrl && url.isEmpty) return null;
  return SyncnextPluginEndpoint(
    javascript: javascript,
    url: url,
    timeout: _timeout(map['timeout']),
  );
}

Duration _timeout(Object? raw) {
  final seconds = raw is int ? raw : int.tryParse('$raw') ?? 20;
  return Duration(seconds: seconds.clamp(5, 180));
}

String _httpsOrEmpty(String value) {
  final text = value.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return '';
  return text;
}

/// Episode handles consumed by plugin `Player()`. HTTPS play pages are kept;
/// Syncnext private payloads such as `youknow-episode:` are kept too.
String pluginEpisodeHandle(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  if (text.startsWith('https://')) return _httpsOrEmpty(text);
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(text);
  if (scheme == null) return '';
  const blocked = {
    'http',
    'https',
    'javascript',
    'data',
    'file',
    'magnet',
    'ftp',
    'ed2k',
  };
  if (blocked.contains(scheme.group(1)!.toLowerCase())) return '';
  return text;
}

String _fallbackTitle(String sourceVideoId) {
  final uri = Uri.tryParse(sourceVideoId);
  if (uri == null || uri.pathSegments.isEmpty) {
    return sourceVideoId.isEmpty ? '未命名视频' : sourceVideoId;
  }
  final last = uri.pathSegments.last.replaceAll(RegExp(r'\.html?$'), '');
  if (last.isEmpty) return sourceVideoId;
  try {
    return Uri.decodeComponent(last);
  } catch (_) {
    return last;
  }
}

String _str(Object? value, {String fallback = ''}) {
  final text = '$value'.trim();
  if (text.isEmpty || text == 'null') return fallback;
  return text;
}

List<dynamic> _asList(Object? value) => value is List ? value : const [];
