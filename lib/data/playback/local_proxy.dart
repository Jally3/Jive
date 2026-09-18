import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../domain/playback_source.dart';
import '../cache/cache_io.dart';

/// 一个播放会话在本地代理中的路由表与读取状态。
class ProxySessionRoute {
  /// [token] 隔离不同播放会话；[proxyManifest] 是已改写资源地址的清单。
  /// [resources] 把稳定资源 ID 映射回源站 URI，[extByResourceId] 记录缓存扩展名。
  /// [sessionHeaders] 是访问源站所需请求头，[fetcher] 非空时启用缓存读取链路。
  ProxySessionRoute({
    required this.token,
    required this.proxyManifest,
    required this.resources,
    required this.extByResourceId,
    required this.sessionHeaders,
    required this.client,
    this.fetcher,
  });

  final String token;
  final String proxyManifest;
  final Map<String, Uri> resources;
  final Map<String, String> extByResourceId;
  final Map<String, String> sessionHeaders;
  final http.Client client;
  final ResourceFetcher? fetcher;

  int activeReads = 0;
  bool closing = false;
}

/// 仅监听 127.0.0.1 的轻量 HTTP 代理，为播放器提供统一 HLS 地址。
class LocalProxyServer {
  /// [bindServer] 可在测试中注入；生产环境自动绑定随机空闲端口。
  LocalProxyServer({Future<HttpServer> Function()? bindServer})
    : _bindServer = bindServer ?? _defaultBindServer;

  final Future<HttpServer> Function() _bindServer;
  HttpServer? _server;
  final Map<String, ProxySessionRoute> _routes = {};
  int _port = 0;
  Future<void> _lifecycle = Future<void>.value();

  int get port => _port;
  bool get isRunning => _server != null;
  bool get hasSessions => _routes.isNotEmpty;

  /// 启动本地服务；重复调用是幂等的，生命周期操作会串行执行。
  Future<void> start() => _enqueueLifecycle(() async {
    if (_server != null) return;
    final server = await _bindServer();
    try {
      server.listen(_handle, onError: (_) {});
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
    _server = server;
    _port = server.port;
  });

  /// 生成播放器使用的本地 manifest URL。
  String baseUrl(String token) =>
      'http://127.0.0.1:$_port/play/$token/index.m3u8';

  /// 注册一个会话路由；相同 token 会被新路由替换。
  void register(ProxySessionRoute route) => _routes[route.token] = route;

  /// 注销会话，使旧的本地播放地址立即失效。
  void unregister(String token) => _routes.remove(token);

  /// 清空全部路由并强制关闭监听端口。
  Future<void> close() => _enqueueLifecycle(() async {
    final server = _server;
    _server = null;
    _port = 0;
    _routes.clear();
    if (server != null) await server.close(force: true);
  });

  /// 串行化 start/close，且让一次失败不会污染后续生命周期操作。
  Future<void> _enqueueLifecycle(Future<void> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    // A failed bind must be reported to its caller without poisoning later
    // start/close operations queued on the same server instance.
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static Future<HttpServer> _defaultBindServer() =>
      HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  /// 根据 `/play/{token}/...` 路径分发 manifest 或资源请求。
  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 3 || segments[0] != 'play') {
        await _respond(request, HttpStatus.notFound, null);
        return;
      }
      final route = _routes[segments[1]];
      if (route == null) {
        await _respond(request, HttpStatus.notFound, null);
        return;
      }
      if (segments.length == 3 && segments[2] == 'index.m3u8') {
        await _respond(
          request,
          HttpStatus.ok,
          route.proxyManifest,
          contentType: 'application/vnd.apple.mpegurl',
        );
        return;
      }
      if (segments.length == 4 && segments[2] == 'res') {
        final resourceId = segments[3];
        final origin = route.resources[resourceId];
        if (origin == null) {
          await _respond(request, HttpStatus.notFound, null);
          return;
        }
        await _serveResource(request, route, resourceId, origin);
        return;
      }
      await _respond(request, HttpStatus.notFound, null);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 通过缓存感知的 ResourceFetcher 响应单个分片、密钥或初始化段。
  ///
  /// [resourceId] 是清单中的稳定 ID，[origin] 是其源站地址。
  Future<void> _serveResource(
    HttpRequest request,
    ProxySessionRoute route,
    String resourceId,
    Uri origin,
  ) async {
    if (route.closing) {
      await _respond(request, HttpStatus.serviceUnavailable, null);
      return;
    }
    route.activeReads++;
    try {
      final fetcher = route.fetcher;
      if (fetcher == null) {
        await _legacyPassthrough(request, route, origin);
        return;
      }
      final result = await fetcher.fetch(
        method: request.method,
        origin: origin,
        resourceId: resourceId,
        ext: route.extByResourceId[resourceId] ?? 'bin',
        downstreamHeaders: _headerMap(request.headers),
      );
      final response = request.response;
      response.statusCode = result.statusCode;
      for (final entry in result.headers.entries) {
        if (entry.key.toLowerCase() == 'content-type') {
          try {
            response.headers.contentType = ContentType.parse(entry.value);
          } catch (_) {}
        } else {
          response.headers.set(entry.key, entry.value);
        }
      }
      if (request.method == 'HEAD') {
        await result.body.drain<void>();
        await response.close();
        return;
      }
      await response.addStream(result.body);
      await response.close();
    } finally {
      route.activeReads--;
    }
  }

  /// 未配置缓存 Fetcher 时直接把播放器请求安全转发到 HTTPS 源站。
  Future<void> _legacyPassthrough(
    HttpRequest request,
    ProxySessionRoute route,
    Uri origin,
  ) async {
    if (origin.scheme != 'https') {
      await _respond(request, HttpStatus.badRequest, null);
      return;
    }
    final headers = <String, String>{
      ...filterSessionHeaders(route.sessionHeaders),
      ...filterDownstreamHeaders(_headerMap(request.headers)),
    };
    http.StreamedResponse upstream;
    try {
      final upstreamRequest = http.Request(request.method, origin);
      upstreamRequest.headers.addAll(headers);
      upstream = await route.client.send(upstreamRequest);
    } catch (_) {
      await _respond(request, HttpStatus.badGateway, null);
      return;
    }
    final response = request.response;
    response.statusCode = upstream.statusCode;
    for (final name in responseHeaderWhitelist) {
      final value = upstream.headers[name];
      if (value != null) response.headers.set(name, value);
    }
    if (request.method == 'HEAD') {
      await upstream.stream.drain<void>();
      await response.close();
      return;
    }
    await response.addStream(upstream.stream);
    await response.close();
  }

  /// 写入简单的状态码/文本响应，常用于 manifest 和错误返回。
  Future<void> _respond(
    HttpRequest request,
    int status,
    String? body, {
    String? contentType,
  }) async {
    final response = request.response;
    response.statusCode = status;
    if (body != null) {
      if (contentType != null) {
        response.headers.contentType = ContentType.parse(contentType);
      }
      response.add(utf8.encode(body));
    }
    await response.close();
  }

  /// 把 dart:io 的多值请求头转换为 http 包使用的单值 Map。
  static Map<String, String> _headerMap(HttpHeaders headers) {
    final result = <String, String>{};
    headers.forEach((name, values) {
      if (values.isNotEmpty) result[name] = values.first;
    });
    return result;
  }
}
