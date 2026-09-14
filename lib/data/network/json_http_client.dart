import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class JsonHttpResponse {
  const JsonHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Object? body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
  String? get requestId {
    final value = headers['x-request-id'];
    if (value == null) return null;
    final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._:-]'), '');
    if (sanitized.isEmpty) return null;
    return sanitized.length <= 120 ? sanitized : sanitized.substring(0, 120);
  }
}

class JsonHttpException implements Exception {
  const JsonHttpException(this.message, {this.isTimeout = false});

  final String message;
  final bool isTimeout;

  @override
  String toString() => message;
}

/// Shared JSON transport for Jive-owned HTTP APIs.
///
/// It centralizes URL resolution, UTF-8 JSON encoding/decoding and timeouts.
/// Business clients remain responsible for interpreting status codes and must
/// never pass secrets or complete payloads to loggers.
class JsonHttpClient {
  JsonHttpClient({
    required http.Client client,
    required Uri baseUri,
    this.timeout = const Duration(seconds: 28),
  }) : _client = client,
       _baseUri = _normalizeBaseUri(baseUri);

  final http.Client _client;
  final Uri _baseUri;
  final Duration timeout;

  /// Opens a response without buffering its body. Callers own decoding and
  /// must consume or cancel the returned stream.
  Future<http.StreamedResponse> sendStream(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
    Future<void>? abortTrigger,
  }) async {
    final request = http.AbortableRequest(
      method,
      _resolve(path),
      abortTrigger: abortTrigger,
    );
    request.headers.addAll({
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      ...headers,
    });
    if (body != null) request.bodyBytes = utf8.encode(jsonEncode(body));
    try {
      return await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const JsonHttpException('请求超时', isTimeout: true);
    } on http.ClientException {
      throw const JsonHttpException('网络连接失败');
    }
  }

  Future<JsonHttpResponse> post(
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) => send('POST', path, body: body, headers: headers);

  Future<JsonHttpResponse> send(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(method, _resolve(path));
    request.headers.addAll({
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      ...headers,
    });
    if (body != null) request.bodyBytes = utf8.encode(jsonEncode(body));

    try {
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      Object? decoded;
      if (response.bodyBytes.isNotEmpty) {
        try {
          decoded = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          decoded = null;
        }
      }
      return JsonHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: decoded,
      );
    } on TimeoutException {
      throw const JsonHttpException('请求超时', isTimeout: true);
    } on http.ClientException {
      throw const JsonHttpException('网络连接失败');
    }
  }

  Uri _resolve(String path) =>
      _baseUri.resolve(path.replaceFirst(RegExp(r'^/+'), ''));
}

Uri _normalizeBaseUri(Uri uri) {
  if (!uri.hasScheme || uri.host.isEmpty) {
    throw ArgumentError.value(uri, 'baseUri', '必须是完整的 HTTP(S) URL');
  }
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return uri.replace(path: path, query: null, fragment: null);
}
