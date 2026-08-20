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
    this.skipped = false,
  });

  /// 预取让行：该片正由播放路径拉取，本次跳过（由下一轮调度补抓）。
  factory CacheFetchResult.skipped() => CacheFetchResult(
    statusCode: HttpStatus.noContent,
    headers: const {},
    body: const Stream.empty(),
    skipped: true,
  );

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final bool fromCache;
  final bool skipped;
}

class CacheQuotaException implements Exception {
  const CacheQuotaException();
}

class CacheResourceValidationException implements Exception {
  const CacheResourceValidationException();
}

/// 分片内容完整性校验失败（字节数与声明不符，或格式魔数不匹配）。
/// 与密钥格式问题区分开：下载任务应将其视为可重试的网络类失败。
class CacheResourceIntegrityException implements Exception {
  const CacheResourceIntegrityException();
}

/// 落盘前条目已不可写（已被删除或正在删除）：放弃本次缓存写入，
/// 按旁路语义处理，不影响回源播放。
class CacheEntryNotWritableException implements Exception {
  const CacheEntryNotWritableException();
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
    this.encryptedSegments = false,
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

  /// 分片为加密内容（AES-128 密文）：跳过格式魔数校验（密文没有
  /// TS 同步字节/fMP4 box 头），字节数比对仍然有效。
  final bool encryptedSegments;
  final SingleFlight<CacheFetchResult> singleFlight;
  bool _reportedCacheBypass = false;

  /// 预取在途的 resourceId（覆盖响应头+body 全程，由 endBackground 解除）。
  /// 播放路径发现同一片在预取时独立回源，不 join——缓存 body 是单订阅流，
  /// 共享会让后到者直接失败（起播卡死的根因）。
  final Set<String> backgroundFetches = {};
  int _bypassSeq = 0;

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
    bool background = false,
  }) async {
    final cached = await _serveCached(resourceId, ext, downstreamHeaders);
    if (cached != null) return cached;
    if (method == 'HEAD') {
      return _passthrough(origin, downstreamHeaders, head: true);
    }
    if (!_cacheEnabled) {
      return _passthrough(origin, downstreamHeaders);
    }
    if (_rangeHeader(downstreamHeaders) != null) {
      return _fetchRangeWithCache(origin, resourceId, ext, downstreamHeaders);
    }
    if (background) {
      // 播放路径正在拉同一片：预取让行，等下一轮调度补抓。
      if (singleFlight.contains(resourceId) ||
          backgroundFetches.contains(resourceId)) {
        return CacheFetchResult.skipped();
      }
      backgroundFetches.add(resourceId);
      try {
        return await _fetchAndCache(origin, resourceId, ext);
      } catch (_) {
        backgroundFetches.remove(resourceId);
        rethrow;
      }
    }
    if (backgroundFetches.contains(resourceId)) {
      // 预取正在后台拉同一片：播放器独立回源（独占流 + 独立临时文件），
      // 短时重复下载换来起播不被预取拖累。
      return _fetchAndCache(
        origin,
        resourceId,
        ext,
        partialTag: 'play${_bypassSeq++}',
      );
    }
    return singleFlight.run(
      resourceId,
      () => _fetchAndCache(origin, resourceId, ext),
    );
  }

  /// 预取 body 消费完毕（或放弃）后调用，解除该片的后台在途标记。
  void endBackground(String resourceId) {
    backgroundFetches.remove(resourceId);
  }

  /// Range 请求未命中缓存：先按完整资源写穿缓存，落盘后再从缓存切出
  /// 请求的字节区间（206）。首次会比请求的区间多下载字节，但后续请求
  /// 全部命中本地——避免 fMP4/BYTERANGE 类内容每次都回源、缓存命中率塌陷。
  Future<CacheFetchResult> _fetchRangeWithCache(
    Uri origin,
    String resourceId,
    String ext,
    Map<String, String>? downstreamHeaders,
  ) async {
    // 不走 singleFlight：其共享结果的 body 是单订阅流，重复订阅会直接抛错；
    // 并发重复回源的概率低、代价可接受。独立临时文件避免与预取在途写冲突。
    final full = await _fetchAndCache(
      origin,
      resourceId,
      ext,
      partialTag: 'range${_bypassSeq++}',
    );
    if (full.statusCode != HttpStatus.ok) return full;
    // body 完全消费完毕时，_fetchAndCache 的提交（commitResource）已完成。
    await full.body.drain<void>();
    final cached = await _serveCached(resourceId, ext, downstreamHeaders);
    if (cached != null) return cached;
    // 缓存写入失败（如配额已满）：退回 Range 透传，不影响本次播放。
    return _passthrough(origin, downstreamHeaders);
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
    String ext, {
    String? partialTag,
  }) async {
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
    // 源站若做了内容编码（如 gzip），content-length 是编码后的长度，
    // 与实际写入字节数不可比，此时跳过字节数校验。
    final hasContentEncoding = upstream.headers.containsKey('content-encoding');
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
    final defaultPart = store!.partialFile(
      contentKeyHash!,
      revisionKeyHash!,
      resourceId,
    );
    // 旁路写入（播放器绕过预取在途、Range 写穿）使用独立临时文件，
    // 避免与另一个在途写任务同时写同一个 .part 导致内容交错。
    final part = partialTag == null
        ? defaultPart
        : File('${defaultPart.path}.$partialTag');
    // 写入前守卫：条目在 reserve 之后被删除时不再重建目录，直接旁路。
    if (!await manager!.isWritable(entryKey!)) {
      await lease.cancel();
      _reportCacheBypass(PlaybackFallbackReason.cacheWriteFailed);
      return CacheFetchResult(
        statusCode: upstream.statusCode,
        headers: _upstreamHeaders(upstream),
        body: upstream.stream,
      );
    }
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
          // 完整性校验第 1 层：声明了长度就必须写满，否则视为截断。
          if (!hasContentEncoding &&
              declaredLength > 0 &&
              written != declaredLength) {
            throw const CacheResourceIntegrityException();
          }
          // 完整性校验第 2 层：未加密分片做格式魔数检查，挡住
          // "200 但内容是 HTML 错误页"这类张冠李戴的响应。
          if (!encryptedSegments && !(await _passesMagicCheck(part, ext))) {
            throw const CacheResourceIntegrityException();
          }
          if (!await lease.ensureCapacity(written)) {
            throw const CacheQuotaException();
          }
          if (declaredLength <= 0) {
            onResourceLength?.call(resourceId, written);
          }
          // 提交前守卫：条目在在途写入期间被删除时放弃落盘，
          // 避免 create(recursive: true) 重建已删目录形成孤儿。
          // 删除与写入之间的残余竞态由启动反向清扫兜底。
          if (!await manager!.isWritable(entryKey!)) {
            throw const CacheEntryNotWritableException();
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

  /// 格式魔数检查（只对已知媒体格式生效，未知扩展名一律放行）：
  /// - TS 分片：首字节必须是 0x47 同步字节，或以 ID3 标签开头；
  /// - fMP4：第 5~8 字节必须是 box 类型（ftyp/styp/moof/sidx/free）。
  static Future<bool> _passesMagicCheck(File file, String ext) async {
    const tsSyncByte = 0x47;
    const mp4BoxTypes = {'ftyp', 'styp', 'moof', 'sidx', 'free'};
    int headLength;
    switch (ext) {
      case 'ts':
        headLength = 3;
      case 'm4s' || 'mp4':
        headLength = 8;
      default:
        return true;
    }
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final head = await raf.read(headLength);
      if (head.length < headLength) return false;
      if (ext == 'ts') {
        if (head[0] == tsSyncByte) return true;
        return head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33; // ID3
      }
      final boxType = String.fromCharCodes(head.sublist(4, 8));
      return mp4BoxTypes.contains(boxType);
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
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
