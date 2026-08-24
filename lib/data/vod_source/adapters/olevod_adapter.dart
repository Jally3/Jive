import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../../domain/video.dart';
import '../../../domain/vod_source.dart';
import '../../video_repository.dart';
import '../vod_source_adapter.dart';

class OlevodAdapter implements VodSourceAdapter {
  OlevodAdapter(this.client, {this.now});

  final http.Client client;
  final DateTime Function()? now;

  static const adapterTypeName = 'olevod_v1';
  static const _newestPageSize = 12;
  static const _listPageSize = 48;
  static const playerUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';

  static const categories = <VideoCategory>[
    VideoCategory(id: 1, name: '首页'),
    VideoCategory(id: 2, name: '电影'),
    VideoCategory(id: 3, name: '连续剧'),
    VideoCategory(id: 4, name: '短剧'),
    VideoCategory(id: 5, name: '综艺'),
    VideoCategory(id: 6, name: '动漫'),
  ];

  @override
  String get adapterType => adapterTypeName;

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
      return _search(source, page: page, keyword: trimmed);
    }
    return _catalog(source, page: page, categoryId: categoryId);
  }

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) =>
      _detail(source, ref);

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      _detail(source, ref);

  Future<VideoPage> _catalog(
    VodSource source, {
    required int page,
    int? categoryId,
  }) async {
    final spec = _catalogSpec(categoryId);
    final json = await _getJson(
      source,
      spec.path.replaceAll('{page}', '$page'),
    );
    final list = _asList(_dataMap(json)['list']);
    final items = <Video>[];
    for (final item in list) {
      if (item is! Map) continue;
      final video = _videoFromCard(
        source,
        Map<String, dynamic>.from(item),
        spec.typeId,
      );
      if (video.sourceVideoId.isEmpty) continue;
      items.add(video);
    }
    return VideoPage(
      items: items,
      page: page,
      pageCount: items.length >= spec.pageSize ? page + 1 : page,
    );
  }

  Future<VideoPage> _search(
    VodSource source, {
    required int page,
    required String keyword,
  }) async {
    if (page > 1) {
      return const VideoPage(items: [], page: 2, pageCount: 1);
    }
    final json = await _getJson(
      source,
      '/v1/pub/index/search/$keyword/vod/0/1/4',
    );
    final groups = _asList(_dataMap(json)['data']);
    final items = <Video>[];
    for (final group in groups) {
      if (group is! Map) continue;
      final map = Map<String, dynamic>.from(group);
      if (_str(map['type']) != 'vod') continue;
      for (final item in _asList(map['list'])) {
        if (item is! Map) continue;
        final video = _videoFromCard(
          source,
          Map<String, dynamic>.from(item),
          0,
        );
        if (video.sourceVideoId.isEmpty) continue;
        if (video.remarks == '超清') continue;
        items.add(video);
      }
    }
    return VideoPage(items: items, page: 1, pageCount: 1);
  }

  Future<Video> _detail(VodSource source, VideoRef ref) async {
    final json = await _getJson(
      source,
      '/v1/pub/vod/detail/${ref.sourceVideoId}/true',
    );
    final data = _dataMap(json);
    final id = _str(data['id'], fallback: ref.sourceVideoId);
    if (id.isEmpty) {
      throw const VideoDataException('没有找到视频详情');
    }
    final episodes = <Episode>[];
    var slot = 0;
    for (final item in _asList(data['urls'])) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      if (map['vip'] == true) continue;
      final url = _httpsOrEmpty(_str(map['url']));
      if (url.isEmpty) continue;
      slot += 1;
      final title = _str(map['title'], fallback: '第$slot集');
      episodes.add(
        Episode(
          id: '$id:$slot',
          name: title,
          url: url,
          identity: 'olevod:episode:$id:$slot',
        ),
      );
    }
    if (episodes.isEmpty) {
      throw const VideoDataException('该视频暂时没有可用播放地址');
    }
    final line = episodes.isEmpty
        ? null
        : PlaybackLine(
            id: '0',
            name: '默认',
            episodes: episodes,
            identity: 'olevod:line:default',
          );
    return Video(
      id: id,
      title: _str(data['name'], fallback: id),
      sourceId: source.id,
      sourceVideoId: id,
      posterUrl: _imageUrl(_str(data['pic'])),
      remarks: _str(data['remarks']),
      description: _str(data['content'], fallback: _str(data['blurb'])),
      year: _str(data['year']),
      area: _str(data['area']),
      actors: _str(data['actor']),
      director: _str(data['director']),
      episodes: episodes,
      playbackLines: line == null ? const [] : [line],
    );
  }

  Video _videoFromCard(
    VodSource source,
    Map<String, dynamic> item,
    int typeId,
  ) {
    if (item['vip'] == true) {
      return const Video(id: '', title: '', sourceVideoId: '');
    }
    final id = _str(item['id']);
    return Video(
      id: id,
      title: _str(item['name'], fallback: id.isEmpty ? '未命名视频' : id),
      sourceId: source.id,
      sourceVideoId: id,
      posterUrl: _imageUrl(_str(item['pic'])),
      typeId: typeId,
      remarks: _str(item['remarks']),
    );
  }

  _CatalogSpec _catalogSpec(int? categoryId) {
    switch (categoryId) {
      case 2:
        return const _CatalogSpec(
          path: '/v1/pub/vod/list/true/3/0/0/1/0/0/update/{page}/48',
          pageSize: _listPageSize,
          typeId: 2,
        );
      case 3:
        return const _CatalogSpec(
          path: '/v1/pub/vod/list/true/3/0/0/2/0/0/update/{page}/48',
          pageSize: _listPageSize,
          typeId: 3,
        );
      case 4:
        return const _CatalogSpec(
          path: '/v1/pub/vod/list/true/3/0/0/14/0/0/update/{page}/48',
          pageSize: _listPageSize,
          typeId: 4,
        );
      case 5:
        return const _CatalogSpec(
          path: '/v1/pub/vod/list/true/3/0/0/3/0/0/update/{page}/48',
          pageSize: _listPageSize,
          typeId: 5,
        );
      case 6:
        return const _CatalogSpec(
          path: '/v1/pub/vod/list/true/3/0/0/4/0/0/update/{page}/48',
          pageSize: _listPageSize,
          typeId: 6,
        );
      default:
        return const _CatalogSpec(
          path: '/v1/pub/vod/newest/{page}/12',
          pageSize: _newestPageSize,
          typeId: 1,
        );
    }
  }

  Future<Map<String, dynamic>> _getJson(VodSource source, String path) async {
    try {
      final uri = Uri(
        scheme: source.baseUri.scheme,
        host: source.baseUri.host,
        port: source.baseUri.hasPort ? source.baseUri.port : null,
        path: path,
        queryParameters: {'_vv': olevodVvToken(now: now?.call())},
      );
      final response = await client
          .get(
            uri,
            headers: {
              'User-Agent': playerUserAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const VideoDataException('该来源需要海外 IP，或签名校验失败');
      }
      if (response.statusCode != 200) {
        throw VideoDataException('服务器响应异常（${response.statusCode}）');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const VideoDataException('服务器返回了无法识别的数据');
      }
      final code = decoded['code'];
      if (code != null && code != 0 && code != 200 && '$code' != '0') {
        throw VideoDataException(
          '${decoded['msg'] ?? decoded['message'] ?? '请求失败'}',
        );
      }
      return decoded;
    } on VideoDataException {
      rethrow;
    } on FormatException {
      throw const VideoDataException('该来源需要海外 IP，当前网络无法访问');
    } on http.ClientException {
      throw const VideoDataException('网络连接失败，请稍后重试');
    } catch (_) {
      throw const VideoDataException('请求超时或网络不可用');
    }
  }
}

class _CatalogSpec {
  const _CatalogSpec({
    required this.path,
    required this.pageSize,
    required this.typeId,
  });

  final String path;
  final int pageSize;
  final int typeId;
}

/// `_vv` token used by OleVod. Matches plugin_olevod/main.js `signature()`.
String olevodVvToken({DateTime? now}) {
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return olevodVvTokenFromUnixSeconds(seconds);
}

String olevodVvTokenFromUnixSeconds(int seconds) {
  final text = '$seconds';
  final lanes = List<String>.generate(4, (_) => '');
  for (final rune in text.runes) {
    final bits = rune.toRadixString(2);
    lanes[0] += _slice(bits, 2, 3);
    lanes[1] += _slice(bits, 3, 4);
    lanes[2] += _slice(bits, 4, 5);
    lanes[3] += bits.length > 5 ? bits.substring(5) : '';
  }
  final parts = [for (final lane in lanes) _hexFromBits(lane)];
  final digest = md5.convert(utf8.encode(text)).toString();
  return digest.substring(0, 3) +
      parts[0] +
      digest.substring(6, 11) +
      parts[1] +
      digest.substring(14, 19) +
      parts[2] +
      digest.substring(22, 27) +
      parts[3] +
      digest.substring(30);
}

String _slice(String text, int start, int end) {
  if (start >= text.length) return '';
  return text.substring(start, end > text.length ? text.length : end);
}

String _hexFromBits(String bits) {
  if (bits.isEmpty) return '000';
  var hex = int.parse(bits, radix: 2).toRadixString(16);
  if (hex.length == 2) return '0$hex';
  if (hex.length == 1) return '00$hex';
  return hex;
}

Map<String, dynamic> _dataMap(Map<String, dynamic> json) {
  final data = json['data'];
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  return const {};
}

String _imageUrl(String pic) {
  if (pic.startsWith('https://')) return pic;
  if (pic.isEmpty || pic.startsWith('http://')) return '';
  return 'https://static.olelive.com/$pic';
}

String _httpsOrEmpty(String value) {
  final text = value.trim();
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return '';
  return text;
}

String _str(Object? value, {String fallback = ''}) {
  final text = '$value'.trim();
  if (text.isEmpty || text == 'null') return fallback;
  return text;
}

List<dynamic> _asList(Object? value) => value is List ? value : const [];
