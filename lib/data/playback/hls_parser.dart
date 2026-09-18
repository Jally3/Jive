import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../domain/playback_source.dart';
import './ad_filter.dart';

/// HLS 是否能进入本地代理/缓存链路；不支持时播放器应改用源地址直连。
enum HlsCacheability { cacheable, directFallback }

/// HLS 解析决策，封装可缓存清单或必须直连的原因。
class HlsDecision {
  /// 清单无需过滤且可以进入代理/缓存链路。
  const HlsDecision.cacheable(HlsMediaPlaylist playlist)
    : cacheability = HlsCacheability.cacheable,
      mediaPlaylist = playlist,
      sourcePlaylist = playlist,
      filterConfidence = null,
      reason = null;

  /// 清单已过滤广告；[sourcePlaylist] 保留原始清单用于审计和缓存元数据。
  /// [filterConfidence] 是所有命中过滤块中的最低置信度。
  const HlsDecision.filtered(
    HlsMediaPlaylist playlist, {
    required this.sourcePlaylist,
    required this.filterConfidence,
  }) : cacheability = HlsCacheability.cacheable,
       mediaPlaylist = playlist,
       reason = null;

  /// 清单无法安全改写；[reason] 用于映射用户可见的回退原因。
  const HlsDecision.directFallback(String this.reason)
    : cacheability = HlsCacheability.directFallback,
      mediaPlaylist = null,
      sourcePlaylist = null,
      filterConfidence = null;

  final HlsCacheability cacheability;
  final HlsMediaPlaylist? mediaPlaylist;
  final HlsMediaPlaylist? sourcePlaylist;
  final double? filterConfidence;
  final String? reason;

  bool get isCacheable => cacheability == HlsCacheability.cacheable;
}

/// 一个 HLS 媒体分片及其与前一分片的边界信息。
class HlsSegment {
  /// [byteRange] 对应 EXT-X-BYTERANGE，[duration] 单位为秒。
  /// [discontinuityBefore] 表示该分片前存在时间戳/编码连续性断点。
  const HlsSegment({
    required this.uri,
    this.byteRange,
    this.duration,
    this.discontinuityBefore = false,
  });

  final Uri uri;
  final String? byteRange;
  final double? duration;
  final bool discontinuityBefore;
}

/// 解析后的 HLS 媒体清单，以及代理、缓存和时间轴所需元数据。
class HlsMediaPlaylist {
  /// [baseUri] 用来解析相对资源地址，[raw] 保留当前实际使用的清单文本。
  /// [timelineMapping] 仅在删除分片后存在，用来换算原始/过滤后时间轴。
  const HlsMediaPlaylist({
    required this.baseUri,
    required this.segments,
    this.mapUri,
    this.mapByteRange,
    this.hasEncryption = false,
    this.hasUnsupportedEncryption = false,
    this.hasImplicitEncryptionIv = false,
    this.keyUris = const [],
    this.isLive = false,
    this.mediaSequence = 0,
    required this.raw,
    this.timelineMapping,
    this.adFilterReport,
  });

  final Uri baseUri;
  final List<HlsSegment> segments;
  final Uri? mapUri;
  final String? mapByteRange;
  final bool hasEncryption;
  final bool hasUnsupportedEncryption;
  final bool hasImplicitEncryptionIv;
  final List<Uri> keyUris;
  final bool isLive;
  final int mediaSequence;
  final String raw;
  final TimelineMapping? timelineMapping;
  final AdFilterReport? adFilterReport;

  /// 复制清单并替换过滤报告，其余解析结果保持不变。
  HlsMediaPlaylist copyWith({AdFilterReport? adFilterReport}) =>
      HlsMediaPlaylist(
        baseUri: baseUri,
        segments: segments,
        mapUri: mapUri,
        mapByteRange: mapByteRange,
        hasEncryption: hasEncryption,
        hasUnsupportedEncryption: hasUnsupportedEncryption,
        hasImplicitEncryptionIv: hasImplicitEncryptionIv,
        keyUris: keyUris,
        isLive: isLive,
        mediaSequence: mediaSequence,
        raw: raw,
        timelineMapping: timelineMapping,
        adFilterReport: adFilterReport ?? this.adFilterReport,
      );
}

/// 将远端 HLS 清单改写成本地代理地址后的执行计划。
class HlsProxyPlan {
  /// [resources] 记录资源 ID 到源站 URI 的映射；[extByResourceId]
  /// 为磁盘缓存提供文件扩展名；[expectedResourceCount] 用于判断缓存完整度。
  const HlsProxyPlan({
    required this.proxyManifest,
    required this.resources,
    required this.extByResourceId,
    this.mapResourceId,
    required this.expectedResourceCount,
  });

  final String proxyManifest;
  final Map<String, Uri> resources;
  final Map<String, String> extByResourceId;
  final String? mapResourceId;
  final int expectedResourceCount;
}

const Set<String> _allowedMediaTags = {
  'VERSION',
  'TARGETDURATION',
  'MEDIA-SEQUENCE',
  'PLAYLIST-TYPE',
  'ENDLIST',
  'INDEPENDENT-SEGMENTS',
  'DISCONTINUITY',
  'DISCONTINUITY-SEQUENCE',
  'MAP',
  'ALLOW-CACHE',
  'START',
  'PROGRAM-DATE-TIME',
  'BYTERANGE',
  'KEY',
};

/// 负责下载、解析、校验 HLS 清单，并生成本地代理清单。
class HlsParser {
  /// [maxHops] 限制 master playlist 嵌套深度，避免循环或异常清单。
  /// [adFilter] 默认关闭；启用后只过滤规则可确认的分片块。
  HlsParser({
    required this.client,
    this.maxHops = 3,
    this.adFilter = const AdFilter(),
  });

  final http.Client client;
  final int maxHops;
  final AdFilter adFilter;

  /// 从 [source] 开始解析 master/media 清单，并跟随最多 [maxHops] 层变体。
  ///
  /// 网络错误、HTTP 错误或不支持的清单不会抛给播放器，而是返回直连决策。
  Future<HlsDecision> resolve(PlaybackSource source) async {
    var current = source;
    for (var hop = 0; hop < maxHops; hop++) {
      http.Response response;
      try {
        response = await client
            .get(current.url, headers: filterSessionHeaders(current.headers))
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        return const HlsDecision.directFallback('manifest 请求失败');
      }
      if (response.statusCode != 200) {
        return HlsDecision.directFallback(
          'manifest HTTP ${response.statusCode}',
        );
      }
      final body = utf8.decode(response.bodyBytes);
      final finalUri = response.request?.url ?? current.url;
      if (_isMaster(body)) {
        final variant = _firstVariantUri(body, finalUri);
        if (variant == null) {
          return const HlsDecision.directFallback('master 缺少可用变体');
        }
        current = current.copyWith(url: variant);
        continue;
      }
      return decideMedia(body, finalUri);
    }
    return const HlsDecision.directFallback('master 层级过深');
  }

  /// 校验并解析媒体清单 [body]；[baseUri] 用于解析其中的相对 URL。
  ///
  /// 直播、不支持的标签/加密格式会回退直连；其余清单可选执行广告过滤。
  HlsDecision decideMedia(String body, Uri baseUri) {
    final unsupported = _unsupportedTag(body);
    if (unsupported != null) {
      return HlsDecision.directFallback('不支持标签 $unsupported');
    }
    final playlist = _parseMedia(body, baseUri);
    if (playlist.hasUnsupportedEncryption) {
      return const HlsDecision.directFallback('不支持的加密流回退直连');
    }
    if (playlist.isLive) {
      return const HlsDecision.directFallback('直播流回退直连');
    }
    if (adFilter.enabled && !playlist.hasImplicitEncryptionIv) {
      final outcome = adFilter.filter(playlist);
      if (outcome.removedAny && outcome.filtered.isNotEmpty) {
        return HlsDecision.filtered(
          buildFilteredPlaylist(playlist, outcome),
          sourcePlaylist: playlist,
          filterConfidence: outcome.confidence,
        );
      }
      return HlsDecision.cacheable(
        playlist.copyWith(adFilterReport: outcome.report),
      );
    }
    return HlsDecision.cacheable(playlist);
  }

  /// 根据 [outcome] 构建移除广告分片后的新清单和时间轴映射。
  HlsMediaPlaylist buildFilteredPlaylist(
    HlsMediaPlaylist original,
    AdFilterResult outcome,
  ) {
    final raw = _buildFilteredRaw(original, outcome);
    return HlsMediaPlaylist(
      baseUri: original.baseUri,
      segments: outcome.filtered,
      mapUri: original.mapUri,
      mapByteRange: original.mapByteRange,
      hasEncryption: original.hasEncryption,
      hasUnsupportedEncryption: original.hasUnsupportedEncryption,
      hasImplicitEncryptionIv: original.hasImplicitEncryptionIv,
      keyUris: original.keyUris,
      isLive: original.isLive,
      mediaSequence: original.mediaSequence,
      raw: raw,
      timelineMapping: outcome.mapping,
      adFilterReport: outcome.report,
    );
  }

  /// 逐行删除被标记分片，并正确保留/补回 DISCONTINUITY 边界。
  String _buildFilteredRaw(HlsMediaPlaylist original, AdFilterResult outcome) {
    final buffer = StringBuffer();
    var sawMap = false;
    var segmentIndex = 0;
    var outputCount = 0;
    var needsDiscontinuity = false;
    final pendingSegmentTags = <String>[];
    for (final rawLine in const LineSplitter().convert(original.raw)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MAP:')) {
        if (!sawMap) {
          buffer.writeln(line);
          sawMap = true;
        }
        continue;
      }
      if (line.startsWith('#')) {
        // 原广告缝和未删除的断点都要留下 DISCONTINUITY，否则拼接后 PTS 对不上。
        if (line == '#EXT-X-DISCONTINUITY') {
          needsDiscontinuity = true;
          continue;
        }
        if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) continue;
        // PDT 跟着被删广告会留下墙钟空洞，过滤后不再写入。
        if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) continue;
        if (line.startsWith('#EXTINF') ||
            line.startsWith('#EXT-X-BYTERANGE:')) {
          pendingSegmentTags.add(line);
        } else {
          buffer.writeln(line);
        }
        continue;
      }
      if (!outcome.isRemoved(segmentIndex)) {
        if (needsDiscontinuity && outputCount > 0) {
          buffer.writeln('#EXT-X-DISCONTINUITY');
        }
        for (final tag in pendingSegmentTags) {
          buffer.writeln(tag);
        }
        buffer.writeln(line);
        outputCount++;
        needsDiscontinuity = false;
      } else {
        needsDiscontinuity = true;
      }
      segmentIndex++;
      pendingSegmentTags.clear();
    }
    return buffer.toString();
  }

  /// 把媒体清单文本解析成分片、初始化段、加密和直播状态等结构化信息。
  HlsMediaPlaylist _parseMedia(String body, Uri baseUri) {
    final segments = <HlsSegment>[];
    Uri? mapUri;
    String? mapByteRange;
    var hasEncryption = false;
    var hasUnsupportedEncryption = false;
    var hasImplicitEncryptionIv = false;
    final keyUris = <Uri>[];
    var hasEndlist = false;
    var mediaSequence = 0;
    var discontinuityBefore = false;
    double? pendingDuration;
    String? pendingByteRange;

    for (final rawLine in const LineSplitter().convert(body)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MAP:')) {
        final uri = _attr(line, 'URI');
        final byterange = _attr(line, 'BYTERANGE');
        if (uri != null) {
          mapUri = baseUri.resolve(uri);
          mapByteRange = byterange;
        }
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final method = (_attrValue(line, 'METHOD') ?? '').toUpperCase();
        if (method != 'NONE') hasEncryption = true;
        if (method == 'AES-128') {
          final keyFormat = _attrValue(line, 'KEYFORMAT');
          final uri = _attrValue(line, 'URI');
          final iv = _attrValue(line, 'IV');
          if (iv == null) {
            hasImplicitEncryptionIv = true;
          } else if (!RegExp(r'^0x[0-9a-fA-F]{32}$').hasMatch(iv)) {
            hasUnsupportedEncryption = true;
          }
          if ((keyFormat == null || keyFormat.toLowerCase() == 'identity') &&
              uri != null) {
            final resolved = baseUri.resolve(uri);
            if (!keyUris.contains(resolved)) keyUris.add(resolved);
          } else {
            hasUnsupportedEncryption = true;
          }
        } else if (method != 'NONE') {
          hasUnsupportedEncryption = true;
        }
      } else if (line.startsWith('#EXTINF:')) {
        pendingDuration = double.tryParse(
          line.substring(8).trim().split(',').first,
        );
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        pendingByteRange = line.substring(17).trim();
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuityBefore = true;
      } else if (line == '#EXT-X-ENDLIST') {
        hasEndlist = true;
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence = int.tryParse(line.substring(22).trim()) ?? 0;
      } else if (!line.startsWith('#')) {
        final uri = baseUri.resolve(line);
        segments.add(
          HlsSegment(
            uri: uri,
            byteRange: pendingByteRange,
            duration: pendingDuration,
            discontinuityBefore: discontinuityBefore,
          ),
        );
        pendingDuration = null;
        pendingByteRange = null;
        discontinuityBefore = false;
      }
    }
    return HlsMediaPlaylist(
      baseUri: baseUri,
      segments: segments,
      mapUri: mapUri,
      mapByteRange: mapByteRange,
      hasEncryption: hasEncryption,
      hasUnsupportedEncryption: hasUnsupportedEncryption,
      hasImplicitEncryptionIv: hasImplicitEncryptionIv,
      keyUris: keyUris,
      isLive: !hasEndlist,
      mediaSequence: mediaSequence,
      raw: body,
    );
  }

  /// 把 [playlist] 中的远端资源 URL 改写为带 [sessionToken] 的本地路径。
  ///
  /// 分片、EXT-X-MAP 和 AES-128 密钥都会登记为可代理资源。
  HlsProxyPlan buildProxyPlan(HlsMediaPlaylist playlist, String sessionToken) {
    final resources = <String, Uri>{};
    final extByResourceId = <String, String>{};
    final rewritten = StringBuffer();
    String? mapResourceId;

    String register(Uri uri, {String? forceExt}) {
      final id = resourceId(uri);
      resources[id] = uri;
      extByResourceId[id] = forceExt ?? extFor(uri);
      return '/play/$sessionToken/res/$id';
    }

    for (final rawLine in const LineSplitter().convert(playlist.raw)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        rewritten.writeln();
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        rewritten.writeln(line);
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        final uriValue = _attr(line, 'URI');
        if (uriValue != null) {
          final mapUri = playlist.baseUri.resolve(uriValue);
          final id = resourceId(mapUri);
          mapResourceId = id;
          final path = register(mapUri);
          final replaced = line.replaceFirst('URI="$uriValue"', 'URI="$path"');
          rewritten.writeln(replaced);
        } else {
          rewritten.writeln(line);
        }
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:')) {
        final method = (_attrValue(line, 'METHOD') ?? '').toUpperCase();
        final uriValue = _attrValue(line, 'URI');
        if (method == 'AES-128' && uriValue != null) {
          final keyUri = playlist.baseUri.resolve(uriValue);
          final path = register(keyUri, forceExt: 'key');
          rewritten.writeln(
            line.replaceFirst(RegExp(r'URI="[^"]*"'), 'URI="$path"'),
          );
        } else {
          rewritten.writeln(line);
        }
        continue;
      }
      if (!line.startsWith('#')) {
        final uri = playlist.baseUri.resolve(line);
        final id = register(uri);
        rewritten.writeln(id);
        continue;
      }
      rewritten.writeln(line);
    }
    return HlsProxyPlan(
      proxyManifest: rewritten.toString(),
      resources: resources,
      extByResourceId: extByResourceId,
      mapResourceId: mapResourceId,
      expectedResourceCount: resources.length,
    );
  }

  /// 使用完整 URI 的 SHA-256 生成稳定且不泄露源站路径的资源 ID。
  static String resourceId(Uri uri) =>
      'sha256:${sha256.convert(utf8.encode(uri.toString())).toString()}';

  /// 从 URI 路径提取安全扩展名，无法确认时使用 bin。
  static String extFor(Uri uri) {
    final path = uri.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final ext = path.substring(dot + 1);
      if (ext.length <= 8 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return ext;
    }
    return 'bin';
  }

  /// 读取必须带双引号的 HLS 属性值。
  static String? _attr(String line, String key) {
    final pattern = RegExp('$key="([^"]*)"');
    final match = pattern.firstMatch(line);
    return match?.group(1);
  }

  /// 读取可带引号或不带引号的 HLS 属性值。
  static String? _attrValue(String line, String key) {
    final quoted = RegExp('$key="([^"]*)"').firstMatch(line)?.group(1);
    if (quoted != null) return quoted;
    return RegExp('$key=([^,]*)').firstMatch(line)?.group(1)?.trim();
  }

  static bool _isMaster(String body) =>
      body.contains('#EXT-X-STREAM-INF:') || body.contains('#EXT-X-STREAM-INF');

  /// 选取 master 清单中的第一个变体 URI。
  static Uri? _firstVariantUri(String body, Uri baseUri) {
    final lines = const LineSplitter().convert(body);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        for (var j = i + 1; j < lines.length; j++) {
          final line = lines[j].trim();
          if (line.isEmpty) continue;
          if (line.startsWith('#')) break;
          return baseUri.resolve(line);
        }
      }
    }
    return null;
  }

  /// 返回首个代理链路不支持的标签；返回 null 表示标签集合可安全改写。
  static String? _unsupportedTag(String body) {
    final seen = <String>{};
    for (final match in RegExp(r'#EXT-X-[A-Z0-9-]+').allMatches(body)) {
      final tag = match.group(0)!;
      seen.add(tag);
      if (tag == '#EXT-X-STREAM-INF') continue;
      if (!_allowedMediaTags.contains(tag.substring(7))) return tag;
    }
    if (body.contains('#EXT-X-I-FRAME-STREAM-INF')) {
      return '#EXT-X-I-FRAME-STREAM-INF';
    }
    if (body.contains('#EXT-X-MEDIA:')) return '#EXT-X-MEDIA';
    return null;
  }
}

/// 统一的缓存 revision 键：流式缓存与显式下载共用同一目录。
/// 指纹基于实际使用的（可能已过滤广告的）清单——清单内容本身已蕴含
/// 过滤规则版本的影响，因此无需额外的过滤版本后缀。两条路径必须使用
/// 同一个函数，否则同一剧集会在磁盘上裂成两份。
///
/// [baseUri] 区分源清单地址，[manifestFingerprint] 区分清单内容版本。
String hlsRevisionKeyHash(Uri baseUri, String manifestFingerprint) =>
    'sha256:${sha256.convert(utf8.encode('$baseUri|$manifestFingerprint'))}';
