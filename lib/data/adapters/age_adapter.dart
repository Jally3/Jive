import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/video.dart';
import '../../domain/vod_source.dart';
import '../video_repository.dart';
import '../vod_source_adapter.dart';

class AgeAdapter implements VodSourceAdapter {
  AgeAdapter(this.client);
  final http.Client client;

  static const adapterTypeName = 'age_v2';
  static const pageSize = 32;
  static const playerUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
  static const _defaultZjResolver = 'https://jx.ejtsyc.com:8443/m3u8/?url=';
  static const _preferredLineKeys = [
    'ffm3u8',
    'bfzym3u8',
    'wjm3u8',
    'lzm3u8',
    'hnm3u8',
  ];

  static const categories = <VideoCategory>[
    VideoCategory(id: 1, name: '热门'),
    VideoCategory(id: 2, name: '连载'),
    VideoCategory(id: 3, name: '剧场版'),
    VideoCategory(id: 4, name: 'WEB'),
  ];

  @override
  String get adapterType => adapterTypeName;

  static Map<String, String> sessionHeaders(String resolverUrl) {
    final headers = <String, String>{'User-Agent': playerUserAgent};
    if (resolverUrl.startsWith('https://')) {
      headers['Referer'] = resolverUrl;
    }
    return headers;
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      categories;

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    final trimmed = keyword?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return _fetchSearch(source, page: page, keyword: trimmed);
    }
    return _fetchCatalog(source, page: page, categoryId: categoryId);
  }

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) async {
    final payload = await _getJson(source, '/v2/detail/${ref.sourceVideoId}');
    return _videoFromDetail(source, payload, includePlayback: false);
  }

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async {
    final payload = await _getJson(source, '/v2/detail/${ref.sourceVideoId}');
    final video = _videoFromDetail(source, payload, includePlayback: true);
    if (video.episodes.isEmpty) {
      throw const VideoDataException('该视频暂时没有可用播放地址');
    }
    return video;
  }

  Future<VideoPage> _fetchCatalog(
    VodSource source, {
    required int page,
    int? categoryId,
  }) async {
    final query = <String, String>{
      'genre': 'all',
      'label': 'all',
      'letter': 'all',
      'order': 'time',
      'region': 'all',
      'resource': 'all',
      'season': 'all',
      'status': 'all',
      'year': 'all',
      'page': '$page',
      'size': '$pageSize',
    };
    switch (categoryId) {
      case 1:
        query['order'] = 'click';
      case 2:
        query['status'] = '连载';
      case 3:
        query['genre'] = '剧场版';
      case 4:
        query['genre'] = 'WEB';
    }
    final json = await _getJson(source, '/v2/catalog', query);
    final videos = _asList(json['videos']);
    final total = _int(json['total']);
    final pageCount = total > 0
        ? ((total + pageSize - 1) ~/ pageSize).clamp(1, 1000000)
        : (videos.length >= pageSize ? page + 1 : page);
    return VideoPage(
      items: videos
          .whereType<Map>()
          .map(
            (item) => _videoFromCard(
              source,
              Map<String, dynamic>.from(item),
              typeId: categoryId ?? 0,
            ),
          )
          .where((item) => item.sourceVideoId.isNotEmpty)
          .toList(),
      page: page,
      pageCount: pageCount,
      total: total > 0 ? total : null,
    );
  }

  Future<VideoPage> _fetchSearch(
    VodSource source, {
    required int page,
    required String keyword,
  }) async {
    final json = await _getJson(source, '/v2/search', {
      'page': '$page',
      'query': keyword,
    });
    final data = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : json;
    final videos = _asList(data['videos']);
    final total = _int(data['total']);
    final totalPage = _int(data['totalPage']);
    final pageCount = totalPage > 0
        ? totalPage
        : (total > 0
              ? ((total + videos.length.clamp(1, pageSize) - 1) ~/
                        videos.length.clamp(1, pageSize))
                    .clamp(1, 1000000)
              : (videos.length >= pageSize ? page + 1 : page));
    return VideoPage(
      items: videos
          .whereType<Map>()
          .map(
            (item) => _videoFromCard(
              source,
              Map<String, dynamic>.from(item),
              typeId: 0,
            ),
          )
          .where((item) => item.sourceVideoId.isNotEmpty)
          .toList(),
      page: page,
      pageCount: pageCount,
      total: total > 0 ? total : null,
    );
  }

  Video _videoFromCard(
    VodSource source,
    Map<String, dynamic> item, {
    required int typeId,
  }) {
    final id = '${item['id'] ?? ''}';
    final type = _str(item['type']);
    return Video(
      id: id,
      title: _str(item['name'], fallback: id.isEmpty ? '未命名视频' : id),
      sourceId: source.id,
      sourceVideoId: id,
      posterUrl: _str(item['cover']),
      typeId: typeId,
      category: type,
      remarks: _description(item),
      description: _str(item['intro']),
      year: _str(item['year']),
      area: _str(item['area']),
      director: _str(item['writer']),
    );
  }

  Video _videoFromDetail(
    VodSource source,
    Map<String, dynamic> payload, {
    required bool includePlayback,
  }) {
    final videoJson = payload['video'];
    if (videoJson is! Map) {
      throw const VideoDataException('没有找到视频详情');
    }
    final video = Map<String, dynamic>.from(videoJson);
    final id = '${video['id'] ?? ''}';
    if (id.isEmpty) {
      throw const VideoDataException('没有找到视频详情');
    }
    final lines = _playbackLines(
      payload,
      video,
      videoId: id,
      includePlayback: includePlayback,
    );
    final defaultLine = lines.isEmpty ? null : lines.first;
    return Video(
      id: id,
      title: _str(video['name'], fallback: id),
      sourceId: source.id,
      sourceVideoId: id,
      posterUrl: _str(video['cover']),
      typeId: 0,
      category: _str(video['type']),
      remarks: _str(video['uptodate'], fallback: _str(video['status'])),
      description: _str(video['intro_clean'], fallback: _str(video['intro'])),
      updatedAt: _str(video['time_format_1'], fallback: _str(video['time'])),
      year: _str(video['year']),
      area: _str(video['area']),
      director: _str(video['writer']),
      episodes: defaultLine?.episodes ?? const [],
      playbackLines: includePlayback ? lines : const [],
    );
  }

  List<PlaybackLine> _playbackLines(
    Map<String, dynamic> payload,
    Map<String, dynamic> video, {
    required String videoId,
    required bool includePlayback,
  }) {
    final playlists = video['playlists'];
    if (playlists is! Map) return const [];
    final playlistMap = <String, dynamic>{
      for (final entry in playlists.entries) '${entry.key}': entry.value,
    };
    final vip = _vipKeys(payload['player_vip']);
    final labels = payload['player_label_arr'] is Map
        ? Map<String, dynamic>.from(payload['player_label_arr'] as Map)
        : const <String, dynamic>{};
    final zjPrefix = _resolverPrefix(payload);
    final ordered = _orderedLineKeys(playlistMap.keys.toList(), vip);
    final lines = <PlaybackLine>[];
    for (final lineKey in ordered) {
      final raw = playlistMap[lineKey];
      if (raw is! List) continue;
      final episodes = <Episode>[];
      var slot = 0;
      for (final pair in raw) {
        if (pair is! List || pair.length < 2) continue;
        final title = _str(pair[0], fallback: '第${slot + 1}集');
        final cryptograph = _str(pair[1]);
        if (cryptograph.isEmpty) continue;
        slot += 1;
        final number = _episodeNumber(title);
        final alignKey = number > 0 ? 'num:$number' : 'slot:$slot';
        final resolverUrl = includePlayback ? '$zjPrefix$cryptograph' : '';
        if (includePlayback && !resolverUrl.startsWith('https://')) continue;
        episodes.add(
          Episode(
            id: '$videoId:$alignKey',
            name: title,
            url: resolverUrl,
            identity: 'age:episode:$alignKey',
          ),
        );
      }
      if (episodes.isEmpty) continue;
      lines.add(
        PlaybackLine(
          id: '${lines.length}',
          name: _str(labels[lineKey], fallback: lineKey),
          episodes: episodes,
          identity: 'age:line:$lineKey',
        ),
      );
    }
    return lines;
  }

  List<String> _orderedLineKeys(List<String> keys, Set<String> vip) {
    final nonVip = keys.where((key) => !vip.contains(key)).toList();
    final ordered = <String>[];
    for (final preferred in _preferredLineKeys) {
      if (nonVip.contains(preferred)) ordered.add(preferred);
    }
    for (final key in nonVip) {
      if (!ordered.contains(key)) ordered.add(key);
    }
    return ordered;
  }

  Set<String> _vipKeys(Object? raw) {
    final text = _str(raw);
    if (text.isEmpty) return const {};
    return text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  String _resolverPrefix(Map<String, dynamic> payload) {
    final playerJx = payload['player_jx'];
    if (playerJx is Map) {
      final zj = _str(playerJx['zj']);
      if (zj.startsWith('https://')) return zj;
    }
    return _defaultZjResolver;
  }

  int _episodeNumber(String title) {
    final text = title.replaceAll(RegExp(r'\s+'), '');
    final match =
        RegExp(r'第0*(\d+)(?:[集话話期卷篇]|$)').firstMatch(text) ??
        RegExp(r'^0*(\d+)(?:[集话話期卷篇]|$)').firstMatch(text);
    return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
  }

  String _description(Map<String, dynamic> item) {
    final uptodate = _str(item['uptodate']);
    if (uptodate.isNotEmpty) return uptodate;
    final parts = <String>[
      _str(item['status']),
      _str(item['type']),
    ].where((part) => part.isNotEmpty);
    return parts.join(' · ');
  }

  Future<Map<String, dynamic>> _getJson(
    VodSource source,
    String path, [
    Map<String, String>? query,
  ]) async {
    try {
      final uri = Uri(
        scheme: source.baseUri.scheme,
        host: source.baseUri.host,
        port: source.baseUri.hasPort ? source.baseUri.port : null,
        path: path,
        queryParameters: query,
      );
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw VideoDataException('服务器响应异常（${response.statusCode}）');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const VideoDataException('服务器返回了无法识别的数据');
      }
      final code = decoded['code'];
      if (code != null &&
          _int(code) != 0 &&
          _int(code) != 200 &&
          _int(code) != 1) {
        throw VideoDataException(
          '${decoded['message'] ?? decoded['msg'] ?? '请求失败'}',
        );
      }
      return decoded;
    } on VideoDataException {
      rethrow;
    } on FormatException {
      throw const VideoDataException('视频数据解析失败');
    } on http.ClientException {
      throw const VideoDataException('网络连接失败，请稍后重试');
    } catch (_) {
      throw const VideoDataException('请求超时或网络不可用');
    }
  }
}

String _str(Object? value, {String fallback = ''}) {
  final text = '$value'.trim();
  if (text.isEmpty || text == 'null') return fallback;
  return text;
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

List<dynamic> _asList(Object? value) => value is List ? value : const [];
