import 'dart:async';
import 'dart:convert';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;
import '../video_repository.dart';
import 'syncnext_plugin_models.dart';

abstract class SyncnextPluginSession {
  SyncnextPluginConfig get config;

  Future<PluginInvokeResult> invoke(
    String functionName, {
    String? url,
    String? pluginKey,
    Duration? timeout,
  });
}

typedef SyncnextPluginSessionFactory =
    Future<SyncnextPluginSession> Function({
      required http.Client client,
      required Uri pluginConfigUri,
    });

class SyncnextPluginBundle {
  const SyncnextPluginBundle({required this.config, required this.scripts});

  final SyncnextPluginConfig config;
  final List<({String name, String source})> scripts;

  static Future<SyncnextPluginBundle> load(
    http.Client client,
    Uri configUri,
  ) async {
    if (configUri.scheme != 'https' || configUri.host.isEmpty) {
      throw const VideoDataException('插件配置地址无效');
    }
    final headers = {
      'User-Agent': pluginUserAgent,
      'Accept': 'application/json,text/plain,*/*',
    };
    final configResponse = await _getPluginResource(
      client,
      configUri,
      headers,
      missingMessage: (code) => '插件配置加载失败（$code）',
    );
    late final Object decoded;
    try {
      decoded = jsonDecode(utf8.decode(configResponse.bodyBytes));
    } catch (_) {
      throw const VideoDataException('插件配置格式无效');
    }
    if (decoded is! Map) {
      throw const VideoDataException('插件配置格式无效');
    }
    final config = SyncnextPluginConfig.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    if (config.files.isEmpty || config.pages.isEmpty) {
      throw const VideoDataException('插件缺少页面或脚本');
    }
    final scripts = <({String name, String source})>[];
    for (final file in config.files) {
      final fileUri = configUri.resolve(file);
      if (fileUri.scheme != 'https') {
        throw const VideoDataException('插件脚本地址不安全');
      }
      final fileResponse = await _getPluginResource(
        client,
        fileUri,
        headers,
        missingMessage: (_) => '插件脚本加载失败（$file）',
      );
      scripts.add((name: file, source: utf8.decode(fileResponse.bodyBytes)));
    }
    return SyncnextPluginBundle(config: config, scripts: scripts);
  }
}

/// GitHub raw is often intercepted or served with a mismatched cert on
/// mainland / simulator networks. Keep the original URI first, then CDN mirrors.
List<Uri> pluginResourceCandidates(Uri uri) {
  final candidates = <Uri>[];
  void add(Uri next) {
    if (next.scheme != 'https' || next.host.isEmpty) return;
    if (candidates.contains(next)) return;
    candidates.add(next);
  }

  add(uri);
  if (uri.host != 'raw.githubusercontent.com') return candidates;
  final segs = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segs.length < 4) return candidates;
  final user = segs[0];
  final repo = segs[1];
  final ref = segs[2];
  final path = segs.skip(3).join('/');
  if (user.isEmpty || repo.isEmpty || ref.isEmpty || path.isEmpty) {
    return candidates;
  }
  final ghPath = '/gh/$user/$repo@$ref/$path';
  add(Uri(scheme: 'https', host: 'cdn.jsdelivr.net', path: ghPath));
  add(Uri(scheme: 'https', host: 'cdn.jsdmirror.com', path: ghPath));
  return candidates;
}

Future<http.Response> _getPluginResource(
  http.Client client,
  Uri uri,
  Map<String, String> headers, {
  required String Function(int statusCode) missingMessage,
}) async {
  Object? lastError;
  var sawCertFailure = false;
  var sawTimeout = false;
  for (final candidate in pluginResourceCandidates(uri)) {
    try {
      final response = await client
          .get(candidate, headers: headers)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response;
      }
      lastError = VideoDataException(missingMessage(response.statusCode));
    } on TimeoutException {
      sawTimeout = true;
      lastError = const VideoDataException('插件资源下载超时');
    } catch (error) {
      if (_isCertFailure(error)) sawCertFailure = true;
      lastError = error;
    }
  }
  if (lastError is VideoDataException) throw lastError;
  if (sawCertFailure) {
    throw const VideoDataException('插件脚本下载失败（证书校验）');
  }
  if (sawTimeout) {
    throw const VideoDataException('插件资源下载超时');
  }
  throw const VideoDataException('插件资源下载失败');
}

bool _isCertFailure(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('certificate') ||
      text.contains('handshake') ||
      text.contains('ssl');
}

class JsPluginSession implements SyncnextPluginSession {
  JsPluginSession._(this.config, this._runtime, this._client, this._cookies);

  @override
  final SyncnextPluginConfig config;
  final JavascriptRuntime _runtime;
  final http.Client _client;
  final _CookieJar _cookies;
  Completer<PluginInvokeResult>? _pending;
  Future<void> _chain = Future.value();
  bool _disposed = false;
  int _httpSeq = 0;
  final Set<int> _httpInFlight = {};
  final Map<int, Map<String, Object?>> _httpResults = {};

  static Future<JsPluginSession> open({
    required http.Client client,
    required Uri pluginConfigUri,
  }) async {
    final bundle = await SyncnextPluginBundle.load(client, pluginConfigUri);
    return fromBundle(client: client, bundle: bundle);
  }

  /// Loads an already-fetched plugin bundle. Used by tests to avoid GitHub.
  static Future<JsPluginSession> fromBundle({
    required http.Client client,
    required SyncnextPluginBundle bundle,
  }) async {
    // Plugins talk through `$http`; flutter_js XHR/fetch polyfills are unused
    // and can leave `exports`/`module` in the sandbox, breaking UMD libs
    // such as crypto-js.
    final runtime = getJavascriptRuntime(xhr: false);
    final session = JsPluginSession._(
      bundle.config,
      runtime,
      client,
      _CookieJar(),
    );
    try {
      session._bindChannels();
      session._evaluate(_bootstrapJs(bundle.config.host), 'bootstrap.js');
      for (final script in bundle.scripts) {
        session._evaluate(_preparePluginScript(script.source), script.name);
      }
      return session;
    } catch (error, stack) {
      session.dispose();
      Error.throwWithStackTrace(
        error is VideoDataException
            ? error
            : const VideoDataException('插件脚本初始化失败'),
        stack,
      );
    }
  }

  @override
  Future<PluginInvokeResult> invoke(
    String functionName, {
    String? url,
    String? pluginKey,
    Duration? timeout,
  }) {
    final wait = timeout ?? const Duration(seconds: 20);
    final done = Completer<PluginInvokeResult>();
    final next = _chain.catchError((_) {}).then((_) async {
      try {
        done.complete(
          await _invokeUnlocked(
            functionName,
            url: url,
            pluginKey: pluginKey,
            timeout: wait,
          ),
        );
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    _chain = next.catchError((_) {});
    return done.future;
  }

  Future<PluginInvokeResult> _invokeUnlocked(
    String functionName, {
    String? url,
    String? pluginKey,
    required Duration timeout,
  }) async {
    if (_disposed) {
      throw const VideoDataException('插件已关闭');
    }
    if (!_isJsIdentifier(functionName)) {
      throw const VideoDataException('插件缺少入口函数');
    }
    final pending = Completer<PluginInvokeResult>();
    _pending = pending;
    final args = [
      if (url != null) jsonEncode(url),
      if (pluginKey != null) jsonEncode(pluginKey),
    ].join(', ');
    final pump = Timer.periodic(const Duration(milliseconds: 20), (_) {
      _pump();
    });
    try {
      _evaluate(
        'try { $functionName($args); } catch (e) {'
            '  sendMessage("syncnextResult", JSON.stringify({'
            '    type: "empty",'
            '    payload: String(e && e.message ? e.message : e)'
            '  }));'
            '}',
        'invoke.js',
      );
      _pump();
      return await pending.future.timeout(timeout);
    } on TimeoutException {
      throw const VideoDataException('插件执行超时');
    } finally {
      pump.cancel();
      if (identical(_pending, pending)) _pending = null;
    }
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    _runtime.dispose();
  }

  void _bindChannels() {
    // Keep these handlers synchronous. flutter_js JavaScriptCore turns a
    // Future return into `evaluate("resolve(hugeJson)")`, which breaks on
    // negative Future.hashCode and on 200KB+ HTML bodies.
    _runtime.onMessage('syncnextHttpStart', (args) {
      final id = ++_httpSeq;
      _httpInFlight.add(id);
      unawaited(
        _fetch(args)
            .then((result) {
              _httpResults[id] = result;
            })
            .catchError((Object error) {
              _httpResults[id] = {
                'statusCode': 0,
                'headers': <String, String>{},
                'body': '',
                'error': '$error',
              };
            })
            .whenComplete(() {
              _httpInFlight.remove(id);
            }),
      );
      return id;
    });
    _runtime.onMessage('syncnextHttpPoll', (args) {
      final id = _httpIdFrom(args);
      if (_httpInFlight.contains(id)) {
        return {'pending': true};
      }
      return _httpResults.remove(id) ??
          {
            'statusCode': 0,
            'headers': <String, String>{},
            'body': '',
            'error': 'missing http job',
          };
    });
    _runtime.onMessage('syncnextResult', (args) {
      final result = _resultFromMessage(args);
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        pending.complete(result);
      }
      return null;
    });
  }

  Future<Map<String, Object?>> _fetch(Object? args) async {
    final req = _asMap(args);
    final url = Uri.tryParse('${req['url'] ?? ''}');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      throw const VideoDataException('插件请求地址不安全');
    }
    final method = '${req['method'] ?? 'GET'}'.toUpperCase();
    final headers = <String, String>{
      'User-Agent': pluginUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    final rawHeaders = req['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final name = '${entry.key}'.trim();
        final value = '${entry.value}'.trim();
        if (name.isEmpty || value.isEmpty) continue;
        headers[name] = value;
      }
    }
    final cookie = _cookies.headerFor(url);
    if (cookie.isNotEmpty &&
        !headers.keys.any((key) => key.toLowerCase() == 'cookie')) {
      headers['Cookie'] = cookie;
    }
    final body = req['body'];
    late http.Response response;
    switch (method) {
      case 'POST':
        if (!headers.keys.any((key) => key.toLowerCase() == 'content-type') &&
            body != null) {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
        }
        response = await _client
            .post(url, headers: headers, body: body?.toString())
            .timeout(const Duration(seconds: 20));
      case 'HEAD':
        response = await _client
            .head(url, headers: headers)
            .timeout(const Duration(seconds: 15));
      default:
        response = await _client
            .get(url, headers: headers)
            .timeout(const Duration(seconds: 20));
    }
    _cookies.store(url, response.headers);
    var text = utf8.decode(response.bodyBytes, allowMalformed: true);
    const maxBytes = 4 * 1024 * 1024;
    if (text.length > maxBytes) {
      text = text.substring(0, maxBytes);
    }
    final headersOut = Map<String, String>.from(response.headers);
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      headersOut['Set-Cookie'] = setCookie;
      headersOut['set-cookie'] = setCookie;
    }
    return {
      'statusCode': response.statusCode,
      'headers': headersOut,
      'body': text,
    };
  }

  void _evaluate(String source, String name) {
    final result = _runtime.evaluate(source, sourceUrl: name);
    if (result.isError) {
      final detail = result.stringResult.trim();
      final suffix = detail.isEmpty
          ? ''
          : '：${detail.length > 180 ? detail.substring(0, 180) : detail}';
      throw VideoDataException('插件脚本执行失败（$name）$suffix');
    }
    _pump();
  }

  void _pump() {
    try {
      _runtime.executePendingJob();
    } catch (_) {}
  }
}

int _httpIdFrom(Object? args) {
  if (args is int) return args;
  final map = _asMap(args);
  final raw = map['id'] ?? args;
  if (raw is int) return raw;
  return int.tryParse('$raw') ?? 0;
}

PluginInvokeResult _resultFromMessage(Object? args) {
  final map = _asMap(args);
  return PluginInvokeResult(
    type: '${map['type'] ?? ''}',
    payload: map['payload'],
  );
}

Map<String, dynamic> _asMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  return const {};
}

class _CookieJar {
  final Map<String, Map<String, String>> _byHost = {};

  void store(Uri url, Map<String, String> headers) {
    final raw = headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    final pair = raw.split(';').first;
    final index = pair.indexOf('=');
    if (index <= 0) return;
    final name = pair.substring(0, index).trim();
    final value = pair.substring(index + 1).trim();
    if (name.isEmpty) return;
    _byHost.putIfAbsent(url.host, () => <String, String>{})[name] = value;
  }

  String headerFor(Uri url) {
    final merged = <String, String>{};
    for (final entry in _byHost.entries) {
      if (url.host == entry.key || url.host.endsWith('.${entry.key}')) {
        merged.addAll(entry.value);
      }
    }
    if (merged.isEmpty) return '';
    return merged.entries.map((item) => '${item.key}=${item.value}').join('; ');
  }
}

bool _isJsIdentifier(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);

bool _looksLikeUmd(String source) {
  final head = source.trimLeft();
  return head.startsWith('!function') && head.contains('typeof exports');
}

String _preparePluginScript(String source) {
  var prepared = source.replaceAll(
    RegExp(r'//[#@]\s*sourceMappingURL=.*$', multiLine: true),
    '',
  );
  if (!_looksLikeUmd(prepared)) return prepared;
  return '(function(){\n'
      'var exports, module, define;\n'
      '$prepared\n'
      'if (typeof CryptoJS === "undefined" && typeof module === "object" && module && module.exports) {\n'
      '  globalThis.CryptoJS = module.exports;\n'
      '}\n'
      '}).call(globalThis);';
}

String _bootstrapJs(String host) =>
    '''
(function () {
  var globalObject = (typeof globalThis !== "undefined")
    ? globalThis
    : (typeof this !== "undefined" ? this : {});
  globalObject.window = globalObject.window || globalObject;
  globalObject.global = globalObject.global || globalObject;
  globalObject.globalThis = globalObject;
  globalObject.__syncnextPrimaryHost = ${jsonEncode(host)};
  if (typeof globalObject.atob !== "function") {
    globalObject.atob = function (input) {
      var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      var str = String(input || "").replace(/=+\$/, "");
      var output = "";
      var buffer = 0;
      var bits = 0;
      for (var i = 0; i < str.length; i++) {
        var val = chars.indexOf(str.charAt(i));
        if (val < 0) continue;
        buffer = (buffer << 6) | val;
        bits += 6;
        if (bits >= 8) {
          bits -= 8;
          output += String.fromCharCode((buffer >> bits) & 0xff);
        }
      }
      return output;
    };
  }
  globalObject.console = globalObject.console || {};
  globalObject.console.log = function () {};
  globalObject.console.warn = function () {};
  globalObject.console.error = function () {};
  globalObject.print = function () {};
  function parseMsg(raw) {
    if (raw == null) return raw;
    if (typeof raw === "string") {
      try { return JSON.parse(raw); } catch (e) { return raw; }
    }
    return raw;
  }
  globalObject.\$http = {
    fetch: function (req) {
      return new Promise(function (resolve, reject) {
        var id;
        try {
          id = sendMessage("syncnextHttpStart", JSON.stringify(req || {}));
        } catch (e) {
          reject(e);
          return;
        }
        function poll() {
          var raw;
          try {
            raw = sendMessage("syncnextHttpPoll", JSON.stringify({ id: id }));
          } catch (e) {
            reject(e);
            return;
          }
          var parsed = parseMsg(raw);
          if (!parsed || parsed.pending) {
            setTimeout(poll, 20);
            return;
          }
          if (parsed.error && !parsed.body) {
            reject(parsed.error);
            return;
          }
          resolve({
            statusCode: parsed.statusCode || 0,
            headers: parsed.headers || {},
            body: parsed.body || ""
          });
        }
        setTimeout(poll, 0);
      });
    },
    head: function (req) {
      var copy = {};
      req = req || {};
      for (var key in req) copy[key] = req[key];
      copy.method = "HEAD";
      return globalObject.\$http.fetch(copy);
    }
  };
  globalObject.\$vision = {
    recognizeText: function (b64, cb) {
      if (typeof cb === "function") {
        cb({ error: { code: "unsupported" } });
      }
    }
  };
  function emit(type, payload) {
    sendMessage("syncnextResult", JSON.stringify({ type: type, payload: payload }));
  }
  globalObject.\$next = {
    toMedias: function (json) { emit("medias", json); },
    toSearchMedias: function (json) { emit("searchMedias", json); },
    toEpisodes: function (json) { emit("episodes", json); },
    toEpisodesCandidates: function (json) { emit("episodesCandidates", json); },
    toPlayer: function (url) { emit("player", String(url || "")); },
    toPlayerByJSON: function (json) { emit("playerJson", json); },
    toPlayerCandidates: function (json) { emit("playerCandidates", json); },
    emptyView: function (msg) { emit("empty", String(msg || "")); },
    aliLink: function () { emit("empty", "不支持阿里云盘"); },
    aliPlay: function () { emit("empty", "不支持阿里云盘"); }
  };
})();
''';
