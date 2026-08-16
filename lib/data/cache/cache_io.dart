import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../domain/playback_status.dart';
import '../../domain/playback_source.dart';
import 'cache_index.dart';
import 'cache_manager.dart';
import 'single_flight.dart';

const Set<String> responseHeaderWhitelist = {
  'content-type',
  'content-length',
  'content-range',
  'accept-ranges',
  'etag',
  'last-modified',
  'cache-control',
  'expires',
  'date',
  'content-encoding',
};

class CacheFetchResult {
  CacheFetchResult({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.fromCache = false,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final bool fromCache;
}

class CacheQuotaException implements Exception {
  const CacheQuotaException();
}

class CacheResourceValidationException implements Exception {
  const CacheResourceValidationException();
}

class ResourceFetcher {
  ResourceFetcher({
    required this.client,
    required this.sessionHeaders,
    this.manager,
    this.store,
    this.entryKey,
    this.contentKeyHash,
    this.revisionKeyHash,
    this.onCacheBypass,
    this.onResourceLength,
    this.onBytesReceived,
    this.failOnCacheUnavailable = false,
    SingleFlight<CacheFetchResult>? singleFlight,
  }) : singleFlight = singleFlight ?? SingleFlight();

  final http.Client client;
  final Map<String, String> sessionHeaders;
  final CacheManager? manager;
  final CacheIndexStore? store;
  final String? entryKey;
  final String? contentKeyHash;
  final String? revisionKeyHash;
  final void Function(PlaybackFallbackReason reason)? onCacheBypass;
  final void Function(String resourceId, int length)? onResourceLength;
  final void Function(int bytes)? onBytesReceived;
  final bool failOnCacheUnavailable;
  final SingleFlight<CacheFetchResult> singleFlight;
  bool _reportedCacheBypass = false;

  bool get _cacheEnabled =>
      manager != null &&
      store != null &&
      entryKey != null &&
      contentKeyHash != null &&
      revisionKeyHash != null;

  Future<CacheFetchResult> fetch({
    String method = 'GET',
    required Uri origin,
    required String resourceId,
    required String ext,
    Map<String, String>? downstreamHeaders,
  }) async {
    final cached = await _serveCached(resourceId, ext, downstreamHeaders);
    if (cached != null) return cached;
    if (method == 'HEAD') {
      return _passthrough(origin, downstreamHeaders, head: true);
    }
    final range = _rangeHeader(downstreamHeaders);
    if (range != null || !_cacheEnabled) {
      return _passthrough(origin, downstreamHeaders);
    }
    return singleFlight.run(
      resourceId,
      () => _fetchAndCache(origin, resourceId, ext),
    );
  }

  Future<CacheFetchResult?> _serveCached(
    String resourceId,
    String ext,
    Map<String, String>? downstream,
  ) async {
    if (!_cacheEnabled) return null;
    final record = await manager!.resourceRecord(entryKey!, resourceId);
    if (record == null || !record.complete) return null;
    final file = store!.resourceFile(
      contentKeyHash!,
      revisionKeyHash!,
      resourceId,
      record.ext,
    );
    if (!await file.exists()) return null;
    await manager!.touch(entryKey!);
    final total = await file.length();
    onResourceLength?.call(resourceId, total);
    final rangeHeader = _rangeHeader(downstream);
    if (rangeHeader == null) {
      return CacheFetchResult(
        statusCode: HttpStatus.ok,
        headers: {
          'content-type': _mimeFor(record.ext),
          'content-length': '$total',
          'accept-ranges': 'bytes',
        },
        body: file.openRead(),
        fromCache: true,
      );
    }
    final parsed = _parseSingleRange(rangeHeader, total);
    if (parsed == null) {
      return CacheFetchResult(
        statusCode: HttpStatus.requestedRangeNotSatisfiable,
        headers: {'content-range': 'bytes */$total'},
        body: const Stream.empty(),
        fromCache: true,
      );
    }
    final (start, end) = parsed;
    final length = end - start + 1;
    return CacheFetchResult(
      statusCode: HttpStatus.partialContent,
      headers: {
        'content-type': _mimeFor(record.ext),
        'content-length': '$length',
        'content-range': 'bytes $start-$end/$total',
        'accept-ranges': 'bytes',
      },
      body: file.openRead(start, end + 1),
      fromCache: true,
    );
  }

  Future<CacheFetchResult> _passthrough(
    Uri origin,
    Map<String, String>? downstream, {
    bool head = false,
  }) async {
    final request = http.Request(head ? 'HEAD' : 'GET', origin);
    request.headers.addAll({
      ...filterSessionHeaders(sessionHeaders),
      ...filterDownstreamHeaders(downstream ?? const {}),
    });
    final upstream = await client.send(request);
    return CacheFetchResult(
      statusCode: upstream.statusCode,
      headers: _upstreamHeaders(upstream),
      body: upstream.stream,
    );
  }

  Future<CacheFetchResult> _fetchAndCache(
    Uri origin,
    String resourceId,
    String ext,
  ) async {
    final request = http.Request('GET', origin);
    request.headers.addAll(filterSessionHeaders(sessionHeaders));
    http.StreamedResponse upstream;
    try {
      upstream = await client.send(request);
    } catch (_) {
      throw const HttpException('回源请求失败');
    }
    if (upstream.statusCode != HttpStatus.ok) {
      return CacheFetchResult(
        statusCode: upstream.statusCode,
        headers: _upstreamHeaders(upstream),
        body: upstream.stream,
      );
    }
    final declaredLength =
        int.tryParse(upstream.headers['content-length'] ?? '') ?? 0;
    final reserveBytes = declaredLength > 0 ? declaredLength : 256 * 1024;
    if (declaredLength > 0) {
      onResourceLength?.call(resourceId, declaredLength);
    }
    final lease = await manager!.reserve(entryKey!, reserveBytes);
    if (lease == null) {
      _reportCacheBypass(PlaybackFallbackReason.cacheQuotaExceeded);
      if (failOnCacheUnavailable) {
        await upstream.stream.listen((_) {}).cancel();
        throw const CacheQuotaException();
      }
      return CacheFetchResult(
        statusCode: upstream.statusCode,
        headers: _upstreamHeaders(upstream),
        body: upstream.stream,
      );
    }
    final part = store!.partialFile(
      contentKeyHash!,
      revisionKeyHash!,
      resourceId,
    );
    await part.parent.create(recursive: true);
    final sink = part.openWrite();
    final controller = StreamController<List<int>>();
    var written = 0;
    upstream.stream.listen(
      (chunk) {
        written += chunk.length;
        onBytesReceived?.call(chunk.length);
        sink.add(chunk);
        controller.add(chunk);
      },
      onDone: () async {
        try {
          await sink.close();
          if (ext == 'key' && written != 16) {
            throw const CacheResourceValidationException();
          }
          if (!await lease.ensureCapacity(written)) {
            throw const CacheQuotaException();
          }
          if (declaredLength <= 0) {
            onResourceLength?.call(resourceId, written);
          }
          final resource = store!.resourceFile(
            contentKeyHash!,
            revisionKeyHash!,
            resourceId,
            ext,
          );
          await resource.parent.create(recursive: true);
          if (await part.exists()) {
            if (await resource.exists()) await resource.delete();
            await part.rename(resource.path);
          }
          await manager!.markPartial(entryKey!, resourceId, written);
          await lease.commitResource(
            resourceId: resourceId,
            size: written,
            ext: ext,
          );
        } catch (error) {
          _reportCacheBypass(
            error is CacheQuotaException
                ? PlaybackFallbackReason.cacheQuotaExceeded
                : PlaybackFallbackReason.cacheWriteFailed,
          );
          await lease.cancel();
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
          if (failOnCacheUnavailable) controller.addError(error);
        } finally {
          await controller.close();
        }
      },
      onError: (Object _) async {
        _reportCacheBypass(PlaybackFallbackReason.cacheWriteFailed);
        await sink.close();
        await lease.cancel();
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        await controller.close();
      },
    );
    return CacheFetchResult(
      statusCode: HttpStatus.ok,
      headers: _upstreamHeaders(upstream)..remove('content-length'),
      body: controller.stream,
    );
  }

  void _reportCacheBypass(PlaybackFallbackReason reason) {
    if (_reportedCacheBypass) return;
    _reportedCacheBypass = true;
    onCacheBypass?.call(reason);
  }

  static Map<String, String> _upstreamHeaders(http.StreamedResponse response) {
    final out = <String, String>{};
    for (final name in responseHeaderWhitelist) {
      final value = response.headers[name];
      if (value != null) out[name] = value;
    }
    return out;
  }

  static String? _rangeHeader(Map<String, String>? headers) {
    if (headers == null) return null;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'range') return entry.value;
    }
    return null;
  }

  static (int, int)? _parseSingleRange(String header, int total) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final a = match.group(1) ?? '';
    final b = match.group(2) ?? '';
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      final suffix = int.tryParse(b) ?? 0;
      if (suffix <= 0 || total <= 0) return null;
      final start = total - suffix;
      return (start < 0 ? 0 : start, total - 1);
    }
    final start = int.parse(a);
    if (start >= total) return null;
    if (b.isEmpty) return (start, total - 1);
    final end = int.parse(b);
    return (start, end >= total ? total - 1 : end);
  }

  static String _mimeFor(String ext) {
    switch (ext) {
      case 'ts':
        return 'video/mp2t';
      case 'm4s':
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'aac':
        return 'audio/aac';
      case 'm3u8':
        return 'application/vnd.apple.mpegurl';
      default:
        return 'application/octet-stream';
    }
  }
}
