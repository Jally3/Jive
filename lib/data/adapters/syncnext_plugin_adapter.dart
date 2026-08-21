import 'package:http/http.dart' as http;
import '../../domain/playback_source.dart';
import '../../domain/video.dart';
import '../../domain/vod_source.dart';
import '../video_repository.dart';
import '../vod_source_adapter.dart';
import 'syncnext_plugin_models.dart';
import 'syncnext_plugin_runtime.dart';

class SyncnextPluginAdapter implements EpisodePlaybackResolver {
  SyncnextPluginAdapter(
    this.client, {
    SyncnextPluginSessionFactory? sessionFactory,
  }) : _sessionFactory = sessionFactory ?? JsPluginSession.open;

  static const adapterTypeName = 'syncnext_plugin';

  final http.Client client;
  final SyncnextPluginSessionFactory _sessionFactory;
  final Map<String, Future<SyncnextPluginSession>> _sessions = {};

  @override
  String get adapterType => adapterTypeName;

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async {
    final session = await _sessionFor(source);
    return session.config.categories();
  }

  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    final session = await _sessionFor(source);
    final trimmed = keyword?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return _search(source, session, page: page, keyword: trimmed);
    }
    return _catalog(source, session, page: page, categoryId: categoryId);
  }

  @override
  Future<Video> fetchDetail(VodSource source, VideoRef ref) =>
      _detail(source, ref, requireEpisodes: false);

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      _detail(source, ref, requireEpisodes: true);

  @override
  Future<PlaybackSource> resolveEpisodePlayback(
    VodSource source,
    String episodeUrl,
  ) async {
    if (pluginEpisodeHandle(episodeUrl).isEmpty) {
      throw const VideoDataException('播放地址不安全或不受支持');
    }
    final session = await _sessionFor(source);
    final player = session.config.player;
    if (player == null) {
      throw const VideoDataException('插件未提供播放入口');
    }
    final result = await session.invoke(
      player.javascript,
      url: episodeUrl,
      timeout: player.timeout,
    );
    if (result.isEmptyView) {
      throw VideoDataException(_emptyMessage(result.payload));
    }
    if (!result.isPlayer) {
      throw const VideoDataException('插件未返回播放地址');
    }
    final playable = playbackSourceFromPluginPlayer(
      result,
      referer: source.baseUri,
    );
    if (playable.url.scheme != 'https') {
      throw const VideoDataException('插件返回了无效播放地址');
    }
    return playable;
  }

  Future<VideoPage> _catalog(
    VodSource source,
    SyncnextPluginSession session, {
    required int page,
    int? categoryId,
  }) async {
    final spec = session.config.pageFor(categoryId);
    if (spec == null) {
      throw const VideoDataException('插件没有可用分类');
    }
    if (!spec.hasPageNumber && page > 1) {
      return VideoPage(items: const [], page: page, pageCount: page - 1);
    }
    final url = fillPluginTemplate(spec.url, pageNumber: page);
    final result = await session.invoke(
      spec.javascript,
      url: url,
      timeout: spec.timeout,
    );
    if (result.isEmptyView) {
      throw VideoDataException(_emptyMessage(result.payload));
    }
    final items = _videosFromMedias(
      source,
      result.payload,
      typeId: categoryId ?? 1,
    );
    if (items.isEmpty && page <= 1) {
      throw const VideoDataException('没有解析到内容，站点可能开启了访问验证');
    }
    return VideoPage(
      items: items,
      page: page,
      pageCount: pluginPageCount(
        hasPager: spec.hasPageNumber,
        page: page,
        itemCount: items.length,
      ),
    );
  }

  Future<VideoPage> _search(
    VodSource source,
    SyncnextPluginSession session, {
    required int page,
    required String keyword,
  }) async {
    final spec = session.config.search;
    if (spec == null) {
      throw const VideoDataException('该来源不支持搜索');
    }
    final hasPager = spec.url.contains(r'${pageNumber}');
    if (!hasPager && page > 1) {
      return VideoPage(items: const [], page: page, pageCount: 1);
    }
    final url = fillPluginTemplate(
      spec.url,
      pageNumber: page,
      keyword: keyword,
    );
    final result = await session.invoke(
      spec.javascript,
      url: url,
      pluginKey: '${source.pluginConfigUri}',
      timeout: spec.timeout,
    );
    if (result.isEmptyView) {
      throw VideoDataException(_emptyMessage(result.payload));
    }
    final items = _videosFromMedias(source, result.payload);
    if (items.isEmpty && page <= 1) {
      throw const VideoDataException('没有解析到内容，站点可能开启了访问验证');
    }
    return VideoPage(
      items: items,
      page: page,
      pageCount: pluginPageCount(
        hasPager: hasPager,
        page: page,
        itemCount: items.length,
      ),
    );
  }

  Future<Video> _detail(
    VodSource source,
    VideoRef ref, {
    required bool requireEpisodes,
  }) async {
    final session = await _sessionFor(source);
    final spec = session.config.episodes;
    if (spec == null) {
      throw const VideoDataException('插件未提供剧集入口');
    }
    final detailUrl = ref.sourceVideoId;
    if (!detailUrl.startsWith('https://')) {
      throw const VideoDataException('视频详情地址无效');
    }
    final result = await session.invoke(
      spec.javascript,
      url: detailUrl,
      timeout: spec.timeout,
    );
    if (result.isEmptyView) {
      throw VideoDataException(_emptyMessage(result.payload));
    }
    final lines = playbackLinesFromPluginPayload(result.payload);
    if (requireEpisodes && (lines.isEmpty || lines.first.episodes.isEmpty)) {
      throw const VideoDataException('该视频暂时没有可用播放地址');
    }
    final defaultLine = lines.isEmpty ? null : lines.first;
    return Video(
      id: ref.sourceVideoId,
      title: _fallbackTitle(ref.sourceVideoId),
      sourceId: source.id,
      sourceVideoId: ref.sourceVideoId,
      posterUrl: '',
      episodes: defaultLine?.episodes ?? const [],
      playbackLines: lines,
    );
  }

  List<Video> _videosFromMedias(
    VodSource source,
    Object? payload, {
    int typeId = 0,
  }) {
    final decoded = decodePluginJson(payload);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map)
          videoFromPluginMedia(
            source,
            Map<String, dynamic>.from(item),
            typeId: typeId,
          ),
    ].where((item) => item.sourceVideoId.isNotEmpty).toList();
  }

  Future<SyncnextPluginSession> _sessionFor(VodSource source) {
    final configUri = source.pluginConfigUri;
    if (configUri == null) {
      throw const VideoDataException('插件配置地址无效');
    }
    return _sessions.putIfAbsent(source.id, () async {
      try {
        return await _sessionFactory(
          client: client,
          pluginConfigUri: configUri,
        );
      } catch (error) {
        _sessions.remove(source.id);
        if (error is VideoDataException) rethrow;
        throw const VideoDataException('插件加载失败');
      }
    });
  }
}

String _emptyMessage(Object? payload) {
  final text = '$payload'.trim();
  if (text.isEmpty || text == 'null') return '没有找到内容';
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
