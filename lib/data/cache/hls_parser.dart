import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../domain/playback_source.dart';
import 'ad_filter.dart';

enum HlsCacheability { cacheable, directFallback }

class HlsDecision {
  const HlsDecision.cacheable(HlsMediaPlaylist playlist)
    : cacheability = HlsCacheability.cacheable,
      mediaPlaylist = playlist,
      sourcePlaylist = playlist,
      filterConfidence = null,
      reason = null;

  const HlsDecision.filtered(
    HlsMediaPlaylist playlist, {
    required this.sourcePlaylist,
    required this.filterConfidence,
  }) : cacheability = HlsCacheability.cacheable,
       mediaPlaylist = playlist,
       reason = null;

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

class HlsSegment {
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

class HlsMediaPlaylist {
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
}

class HlsProxyPlan {
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

class HlsParser {
  HlsParser({
    required this.client,
    this.maxHops = 3,
    this.adFilter = const AdFilter(),
  });

  final http.Client client;
  final int maxHops;
  final AdFilter adFilter;

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
    }
    return HlsDecision.cacheable(playlist);
  }

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
    );
  }

  String _buildFilteredRaw(HlsMediaPlaylist original, AdFilterResult outcome) {
    final buffer = StringBuffer();
    var sawMap = false;
    var segmentIndex = 0;
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
        if (line == '#EXT-X-DISCONTINUITY') continue;
        if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) continue;
        if (line.startsWith('#EXTINF') ||
            line.startsWith('#EXT-X-BYTERANGE:') ||
            line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
          pendingSegmentTags.add(line);
        } else {
          buffer.writeln(line);
        }
        continue;
      }
      if (!outcome.isRemoved(segmentIndex)) {
        for (final tag in pendingSegmentTags) {
          buffer.writeln(tag);
        }
        buffer.writeln(line);
      }
      segmentIndex++;
      pendingSegmentTags.clear();
    }
    return buffer.toString();
  }

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

  static String resourceId(Uri uri) =>
      'sha256:${sha256.convert(utf8.encode(uri.toString())).toString()}';

  static String extFor(Uri uri) {
    final path = uri.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final ext = path.substring(dot + 1);
      if (ext.length <= 8 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return ext;
    }
    return 'bin';
  }

  static String? _attr(String line, String key) {
    final pattern = RegExp('$key="([^"]*)"');
    final match = pattern.firstMatch(line);
    return match?.group(1);
  }

  static String? _attrValue(String line, String key) {
    final quoted = RegExp('$key="([^"]*)"').firstMatch(line)?.group(1);
    if (quoted != null) return quoted;
    return RegExp('$key=([^,]*)').firstMatch(line)?.group(1)?.trim();
  }

  static bool _isMaster(String body) =>
      body.contains('#EXT-X-STREAM-INF:') || body.contains('#EXT-X-STREAM-INF');

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
