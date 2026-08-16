import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/video.dart';
import '../../domain/vod_source.dart';
import '../video_repository.dart';
import '../vod_source_adapter.dart';

class MacCmsV10Adapter implements VodSourceAdapter {
  MacCmsV10Adapter(this.client);
  final http.Client client;

  @override
  String get adapterType => 'mac_cms_v10';

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    final query = <String, String>{'ac': 'detail', 'pg': '$page'};
    if (categoryId != null) query['t'] = '$categoryId';
    if (keyword != null && keyword.trim().isNotEmpty) {
      query['wd'] = keyword.trim();
    }
    final json = await _request(source, query);
    return _pageFromJson(source, json);
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async {
    final json = await _request(source, {'ac': 'list', 'pg': '1'});
    final raw = json['class'];
    if (raw is! List) throw const VideoDataException('分类数据格式异常');
    return raw
        .whereType<Map<String, dynamic>>()
        .map(
          (item) => VideoCategory(
            id: _int(item['type_id']),
            name: '${item['type_name'] ?? ''}',
            parentId: _int(item['type_pid']),
          ),
        )
        .where((item) => item.id > 0 && item.name.isNotEmpty)
        .toList();
  }

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) async {
    final json = await _request(source, {
      'ac': 'detail',
      'ids': ref.sourceVideoId,
    });
    final list = json['list'];
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw const VideoDataException('没有找到视频详情');
    }
    return _videoFromJson(
      source,
      Map<String, dynamic>.from(list.first as Map),
      includeEpisodes: false,
    );
  }

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) async {
    final json = await _request(source, {
      'ac': 'detail',
      'ids': ref.sourceVideoId,
    });
    final list = json['list'];
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw const VideoDataException('没有找到视频详情');
    }
    final detail = _videoFromJson(
      source,
      Map<String, dynamic>.from(list.first as Map),
      includeEpisodes: true,
    );
    if (detail.episodes.isEmpty) {
      throw const VideoDataException('该视频暂时没有可用播放地址');
    }
    return detail;
  }

  Future<Map<String, dynamic>> _request(
    VodSource source,
    Map<String, String> query,
  ) async {
    try {
      final uri = source.baseUri.replace(queryParameters: query);
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
      if (_int(decoded['code']) != 1) {
        throw VideoDataException('${decoded['msg'] ?? '请求失败'}');
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

  VideoPage _pageFromJson(VodSource source, Map<String, dynamic> json) {
    final raw = json['list'];
    if (raw is! List) throw const VideoDataException('视频列表格式异常');
    final total = _int(json['total']);
    return VideoPage(
      items: raw
          .whereType<Map<String, dynamic>>()
          .map((e) => _videoFromJson(source, e, includeEpisodes: false))
          .toList(),
      page: _int(json['page']).clamp(1, 1000000),
      pageCount: _int(json['pagecount']).clamp(1, 1000000),
      total: total > 0 ? total : null,
    );
  }

  Video _videoFromJson(
    VodSource source,
    Map<String, dynamic> json, {
    required bool includeEpisodes,
  }) {
    final playUrl = '${json['vod_play_url'] ?? ''}';
    final playFrom = '${json['vod_play_from'] ?? ''}';
    final lines = _buildPlaybackLines(playUrl, playFrom);
    final defaultLine = lines.isEmpty ? null : lines.first;
    return Video(
      id: '${json['vod_id'] ?? ''}',
      title: '${json['vod_name'] ?? '未命名视频'}',
      sourceId: source.id,
      sourceVideoId: '${json['vod_id'] ?? ''}',
      posterUrl: '${json['vod_pic'] ?? ''}',
      typeId: _int(json['type_id']),
      category: '${json['type_name'] ?? ''}',
      remarks: '${json['vod_remarks'] ?? ''}',
      description: _plain('${json['vod_content'] ?? ''}'),
      updatedAt: '${json['vod_time'] ?? ''}',
      year: '${json['vod_year'] ?? ''}',
      area: '${json['vod_area'] ?? ''}',
      actors: '${json['vod_actor'] ?? ''}',
      director: '${json['vod_director'] ?? ''}',
      episodes: includeEpisodes
          ? (defaultLine?.episodes ?? const [])
          : _episodeMetadata(playUrl),
      playbackLines: includeEpisodes ? lines : const [],
    );
  }

  List<PlaybackLine> _buildPlaybackLines(String rawUrl, String rawFrom) {
    final urlParts = rawUrl.split(r'$$$');
    final fromParts = rawFrom.split(r'$$$');
    final lines = <PlaybackLine>[];
    for (var i = 0; i < urlParts.length; i++) {
      final urlPart = urlParts[i].trim();
      if (urlPart.isEmpty) continue;
      final episodes = _parseEpisodes(urlPart, requireUrl: true);
      if (episodes.isEmpty) continue;
      final rawFromName = i < fromParts.length ? fromParts[i].trim() : '';
      final name = rawFromName.isNotEmpty ? rawFromName : '线路${i + 1}';
      lines.add(
        PlaybackLine(
          id: '${lines.length}',
          name: name,
          episodes: episodes,
          identity: 'macv10:line:$i:${_normalize(rawFromName)}',
        ),
      );
    }
    return lines;
  }

  List<Episode> _episodeMetadata(String raw) {
    for (final source in raw.split(r'$$$')) {
      final result = _parseEpisodes(source, requireUrl: false);
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  List<Episode> _parseEpisodes(String raw, {required bool requireUrl}) {
    final result = <Episode>[];
    final seen = <String>{};
    final items = raw.split('#');
    for (var rawIndex = 0; rawIndex < items.length; rawIndex++) {
      final item = items[rawIndex];
      final cut = item.indexOf(r'$');
      if (cut <= 0) continue;
      final name = item.substring(0, cut).trim();
      final url = item.substring(cut + 1).trim();
      if (name.isEmpty || !seen.add(name)) continue;
      if (requireUrl) {
        if (Uri.tryParse(url)?.hasScheme != true ||
            !url.startsWith('https://') ||
            !seen.add(url)) {
          continue;
        }
      }
      result.add(
        Episode(
          id: '${result.length + 1}',
          name: name,
          url: requireUrl ? url : '',
          identity: 'macv10:episode:$rawIndex:${_normalize(name)}',
        ),
      );
    }
    return result;
  }

  String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  String _plain(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .trim();
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;
