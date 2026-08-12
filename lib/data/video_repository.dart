import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../domain/video.dart';

class VideoDataException implements Exception {
  const VideoDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class VideoRepository {
  Future<VideoPage> fetchPage({int page = 1, int? categoryId, String? keyword});
  Future<List<VideoCategory>> fetchCategories();
  Future<Video> fetchDetail(String videoId, {bool forceRefresh = false});
  Future<Video> resolvePlayback(String videoId);
}

class StormVideoRepository implements VideoRepository {
  StormVideoRepository(this.client);
  final http.Client client;
  static const base = 'https://bfzyapi.com/api.php/provide/vod/';
  final Map<String, ({Video video, DateTime fetchedAt})> _detailCache = {};

  @override
  Future<VideoPage> fetchPage({
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    final query = <String, String>{'ac': 'detail', 'pg': '$page'};
    if (categoryId != null) query['t'] = '$categoryId';
    if (keyword != null && keyword.trim().isNotEmpty) {
      query['wd'] = keyword.trim();
    }
    try {
      final json = await _request(
        Uri.parse(base).replace(queryParameters: query),
      );
      final parsed = _pageFromJson(json);
      if (page == 1 &&
          categoryId == null &&
          (keyword == null || keyword.isEmpty)) {
        return VideoPage(
          items: [...parsed.items],
          page: parsed.page,
          pageCount: parsed.pageCount,
        );
      }
      return parsed;
    } catch (error) {
      if (page == 1 &&
          categoryId == null &&
          (keyword == null || keyword.isEmpty)) {
        return const VideoPage(items: [], page: 1, pageCount: 1);
      }
      rethrow;
    }
  }

  @override
  Future<List<VideoCategory>> fetchCategories() async {
    final json = await _request(
      Uri.parse(base).replace(queryParameters: {'ac': 'list', 'pg': '1'}),
    );
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
  Future<Video> fetchDetail(String videoId, {bool forceRefresh = false}) async {
    final cached = _detailCache[videoId];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) <
            const Duration(minutes: 2)) {
      return cached.video;
    }
    final json = await _request(
      Uri.parse(
        base,
      ).replace(queryParameters: {'ac': 'detail', 'ids': videoId}),
    );
    final list = json['list'];
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw const VideoDataException('没有找到视频详情');
    }
    final detail = _videoFromJson(
      Map<String, dynamic>.from(list.first as Map),
      includeEpisodes: false,
    );
    _detailCache[videoId] = (video: detail, fetchedAt: DateTime.now());
    return detail;
  }

  @override
  Future<Video> resolvePlayback(String videoId) async {
    final json = await _request(
      Uri.parse(
        base,
      ).replace(queryParameters: {'ac': 'detail', 'ids': videoId}),
    );
    final list = json['list'];
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw const VideoDataException('没有找到视频详情');
    }
    final detail = _videoFromJson(
      Map<String, dynamic>.from(list.first as Map),
      includeEpisodes: true,
    );
    if (detail.episodes.isEmpty) {
      throw const VideoDataException('该视频暂时没有可用播放地址');
    }
    return detail;
  }

  Future<Map<String, dynamic>> _request(Uri uri) async {
    try {
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

  VideoPage _pageFromJson(Map<String, dynamic> json) {
    final raw = json['list'];
    if (raw is! List) throw const VideoDataException('视频列表格式异常');
    return VideoPage(
      items: raw
          .whereType<Map<String, dynamic>>()
          .map((e) => _videoFromJson(e, includeEpisodes: false))
          .toList(),
      page: _int(json['page']).clamp(1, 1000000),
      pageCount: _int(json['pagecount']).clamp(1, 1000000),
    );
  }

  Video _videoFromJson(
    Map<String, dynamic> json, {
    required bool includeEpisodes,
  }) => Video(
    id: '${json['vod_id'] ?? ''}',
    title: '${json['vod_name'] ?? '未命名视频'}',
    posterUrl: '${json['vod_pic'] ?? ''}',
    typeId: _int(json['type_id']),
    category: '${json['type_name'] ?? ''}',
    remarks: '${json['vod_remarks'] ?? ''}',
    description: _plain('${json['vod_content'] ?? ''}'),
    updatedAt: '${json['vod_time'] ?? ''}',
    episodes: includeEpisodes
        ? _episodes('${json['vod_play_url'] ?? ''}')
        : _episodeMetadata('${json['vod_play_url'] ?? ''}'),
  );

  List<Episode> _episodeMetadata(String raw) {
    for (final source in raw.split(r'$$$')) {
      final result = <Episode>[];
      final seen = <String>{};
      for (final item in source.split('#')) {
        final cut = item.indexOf(r'$');
        if (cut <= 0) continue;
        final name = item.substring(0, cut).trim();
        if (name.isEmpty || !seen.add(name)) continue;
        result.add(Episode(id: '${result.length + 1}', name: name, url: ''));
      }
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  List<Episode> _episodes(String raw) {
    final sources = raw.split(r'$$$');
    for (final source in sources) {
      final result = <Episode>[];
      final seen = <String>{};
      for (final item in source.split('#')) {
        final cut = item.indexOf(r'$');
        if (cut <= 0) continue;
        final name = item.substring(0, cut).trim();
        final url = item.substring(cut + 1).trim();
        if (name.isEmpty ||
            Uri.tryParse(url)?.hasScheme != true ||
            !url.startsWith('https://') ||
            !seen.add(url)) {
          continue;
        }
        result.add(Episode(id: '${result.length + 1}', name: name, url: url));
      }
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  String _plain(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .trim();
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

final videoRepositoryProvider = Provider<VideoRepository>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return StormVideoRepository(client);
});
