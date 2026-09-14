import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/library.dart';
import '../../domain/recommendation.dart';
import '../../domain/watch_record.dart';
import '../network/json_http_client.dart';
import 'anonymous_subject_store.dart';
import 'recommendation_client.dart';
import 'recommendation_request.dart';

class RecommendationApiException implements Exception {
  const RecommendationApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
    this.clientRequestId,
    this.retryable = false,
    this.retryAfterSeconds,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;
  final String? clientRequestId;
  final bool retryable;
  final int? retryAfterSeconds;

  bool get isInvalidSubject =>
      statusCode == 401 && code == 'INVALID_ANONYMOUS_SUBJECT';
  bool get isExpiredCursor =>
      statusCode == 410 && code == 'RECOMMENDATION_CURSOR_EXPIRED';

  @override
  String toString() => message;
}

class BackendRecommendationClient
    implements PaginatedRecommendationClient, StreamingRecommendationClient {
  BackendRecommendationClient({
    required JsonHttpClient httpClient,
    required AnonymousSubjectStore subjectStore,
    void Function(String message)? logSink,
  }) : _httpClient = httpClient,
       _subjectStore = subjectStore,
       _logSink = logSink ?? _defaultLog;

  static const _subjectHeader = 'X-Jive-Anonymous-Subject';
  final JsonHttpClient _httpClient;
  final AnonymousSubjectStore _subjectStore;
  final void Function(String message) _logSink;
  Future<String>? _subjectRequest;

  @override
  RecommendationStreamRequest recommendStream({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) => _openStream(
    () => backendRecommendationPayload(
      clientRequestId: createClientRequestId(),
      history: history,
      library: library,
    ),
  );

  @override
  RecommendationStreamRequest nextPageStream(String cursor) {
    final normalized = cursor.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(cursor, 'cursor', '不能为空');
    }
    return _openStream(
      () => {'clientRequestId': createClientRequestId(), 'cursor': normalized},
    );
  }

  RecommendationStreamRequest _openStream(
    Map<String, dynamic> Function() bodyFactory,
  ) {
    final abort = Completer<void>();
    return RecommendationStreamRequest(
      events: _authorizedStream(bodyFactory, abort),
      cancel: () async {
        if (!abort.isCompleted) abort.complete();
      },
    );
  }

  Stream<RecommendationStreamEvent> _authorizedStream(
    Map<String, dynamic> Function() bodyFactory,
    Completer<void> abort,
  ) async* {
    var subject = await _subject();
    for (var attempt = 0; attempt < 2; attempt++) {
      final body = bodyFactory();
      final expectedClientRequestId = '${body['clientRequestId'] ?? ''}';
      final deadline = Timer(_httpClient.timeout, () {
        if (!abort.isCompleted) abort.complete();
      });
      final watch = Stopwatch()..start();
      try {
        final response = await _httpClient.sendStream(
          'POST',
          '/api/v1/recommendations/personalized',
          body: body,
          headers: {'Accept': 'application/x-ndjson', _subjectHeader: subject},
          abortTrigger: abort.future,
        );
        if (response.statusCode != 200) {
          final buffered = await _bufferJsonResponse(response);
          final error = _parseError(buffered);
          if (error.isInvalidSubject && attempt == 0) {
            await _subjectStore.clear();
            subject = await _subject(forceIssue: true);
            continue;
          }
          throw error;
        }
        final contentType = response.headers['content-type']?.toLowerCase();
        if (contentType == null ||
            !contentType.startsWith('application/x-ndjson')) {
          throw RecommendationApiException(
            statusCode: 200,
            code: 'INVALID_STREAM_CONTENT_TYPE',
            message: '推荐服务返回了无效的流格式',
            requestId: _responseRequestId(response.headers),
          );
        }

        var state = _RecommendationStreamState.idle;
        var lastIndex = 0;
        var startClientRequestId = '';
        RecommendationBatch? doneResult;
        await for (final line
            in response.stream
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (line.trim().isEmpty) continue;
          final decoded = jsonDecode(line);
          if (decoded is! Map) throw const FormatException('invalid event');
          final json = Map<String, dynamic>.from(decoded);
          switch ('${json['type'] ?? ''}') {
            case 'start':
              if (state != _RecommendationStreamState.idle) {
                throw const FormatException('duplicate start');
              }
              final requestId = _text(json['requestId']);
              final clientRequestId = _text(json['clientRequestId']);
              final mode = switch ('${json['mode'] ?? ''}') {
                'personalized' => RecommendationMode.personalized,
                'cold_start' => RecommendationMode.coldStart,
                _ => null,
              };
              final source = switch ('${json['source'] ?? ''}') {
                'llm' => RecommendationSource.llm,
                'none' => RecommendationSource.none,
                _ => null,
              };
              if (requestId == null ||
                  clientRequestId != expectedClientRequestId ||
                  mode == null ||
                  source == null) {
                throw const FormatException('invalid start');
              }
              startClientRequestId = clientRequestId!;
              state = _RecommendationStreamState.streaming;
              yield RecommendationStreamStart(
                requestId: requestId,
                clientRequestId: clientRequestId,
                mode: mode,
                source: source,
              );
              break;
            case 'item':
              if (state != _RecommendationStreamState.streaming) {
                throw const FormatException('item outside stream');
              }
              final index = _integer(json['index']);
              final item = RecommendationCandidate.tryFromJson(json['item']);
              if (index == null ||
                  index != lastIndex + 1 ||
                  index > 24 ||
                  item == null) {
                throw const FormatException('invalid item');
              }
              lastIndex = index;
              yield RecommendationStreamItem(index: index, item: item);
              break;
            case 'done':
              if (state != _RecommendationStreamState.streaming) {
                throw const FormatException('done outside stream');
              }
              final rawResult = json['result'];
              if (rawResult is! Map) {
                throw const FormatException('invalid done');
              }
              final resultJson = Map<String, dynamic>.from(rawResult);
              resultJson['generatedAt'] ??= resultJson['servedAt'];
              final result = RecommendationBatch.tryFromJson(resultJson);
              if (result == null ||
                  result.clientRequestId != startClientRequestId) {
                throw const FormatException('invalid done result');
              }
              state = _RecommendationStreamState.completed;
              doneResult = result;
              break;
            case 'error':
              if (state != _RecommendationStreamState.streaming ||
                  json['error'] is! Map) {
                throw const FormatException('invalid stream error');
              }
              throw _parseError(
                JsonHttpResponse(
                  statusCode: 200,
                  headers: response.headers,
                  body: {'error': json['error']},
                ),
              );
            default:
              throw const FormatException('unknown stream event');
          }
        }
        if (state != _RecommendationStreamState.completed) {
          throw const FormatException('stream ended before done');
        }
        yield RecommendationStreamDone(doneResult!);
        _logSink(
          'stream_complete elapsedMs=${watch.elapsedMilliseconds} '
          'requestId=${_responseRequestId(response.headers) ?? ''}',
        );
        return;
      } on RecommendationApiException {
        rethrow;
      } on JsonHttpException catch (error) {
        throw RecommendationApiException(
          statusCode: 0,
          code: error.isTimeout ? 'CLIENT_TIMEOUT' : 'NETWORK_ERROR',
          message: error.isTimeout ? '推荐请求超时' : '无法连接推荐服务',
          retryable: true,
        );
      } on FormatException {
        throw const RecommendationApiException(
          statusCode: 200,
          code: 'INVALID_NDJSON_STREAM',
          message: '推荐服务返回了无效的流数据',
        );
      } on http.RequestAbortedException {
        throw RecommendationApiException(
          statusCode: 0,
          code: deadline.isActive ? 'REQUEST_CANCELLED' : 'CLIENT_TIMEOUT',
          message: deadline.isActive ? '推荐请求已取消' : '推荐请求超时',
          retryable: !deadline.isActive,
        );
      } finally {
        deadline.cancel();
      }
    }
  }

  Future<JsonHttpResponse> _bufferJsonResponse(
    http.StreamedResponse response,
  ) async {
    Object? body;
    final bytes = await response.stream.toBytes();
    if (bytes.isNotEmpty) {
      try {
        body = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        body = null;
      }
    }
    return JsonHttpResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: body,
    );
  }

  @override
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  }) {
    final clientRequestId = createClientRequestId();
    final body = backendRecommendationPayload(
      clientRequestId: clientRequestId,
      history: history,
      library: library,
    );
    return _authorizedBatch(body);
  }

  @override
  Future<RecommendationBatch> nextPage(String cursor) {
    final normalized = cursor.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(cursor, 'cursor', '不能为空');
    }
    return _authorizedBatch({
      'clientRequestId': createClientRequestId(),
      'cursor': normalized,
    });
  }

  @override
  Future<void> reportEvent(RecommendationEvent event) async {
    if (event.sessionId.isEmpty) return;
    try {
      await _authorizedRequest('/api/v1/recommendations/events', {
        'clientRequestId': createClientRequestId(),
        'sessionId': event.sessionId,
        'pageIndex': event.pageIndex.clamp(1, 3),
        'candidatePosition': event.candidatePosition.clamp(1, 24),
        'event': event.type.wireName,
        'occurredAt': event.occurredAt.toIso8601String(),
      });
    } catch (error) {
      _logSink('event_failed errorType=${error.runtimeType}');
    }
  }

  Future<RecommendationBatch> _authorizedBatch(
    Map<String, dynamic> body,
  ) async {
    final response = await _authorizedRequest(
      '/api/v1/recommendations/personalized',
      body,
    );
    if (response.body is! Map) {
      throw _parseError(response, fallbackCode: 'INVALID_JSON_RESPONSE');
    }
    final json = Map<String, dynamic>.from(response.body! as Map);
    // Cold-start responses legitimately omit generatedAt.
    json['generatedAt'] ??= json['servedAt'];
    final batch = RecommendationBatch.tryFromJson(json);
    if (batch == null) {
      throw RecommendationApiException(
        statusCode: response.statusCode,
        code: 'INVALID_JSON_RESPONSE',
        message: '推荐服务返回了无效数据',
        requestId: response.requestId,
      );
    }
    return batch;
  }

  Future<JsonHttpResponse> _authorizedRequest(
    String path,
    Map<String, dynamic> body,
  ) async {
    var subject = await _subject();
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await _send(path, body, subject);
      if (response.isSuccess) return response;
      final error = _parseError(response);
      if (!error.isInvalidSubject || attempt == 1) throw error;
      await _subjectStore.clear();
      subject = await _subject(forceIssue: true);
    }
    throw StateError('unreachable');
  }

  Future<JsonHttpResponse> _send(
    String path,
    Map<String, dynamic> body,
    String subject,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final response = await _httpClient.post(
        path,
        body: body,
        headers: {_subjectHeader: subject},
      );
      watch.stop();
      _logSink(
        'request_complete elapsedMs=${watch.elapsedMilliseconds} '
        'status=${response.statusCode} requestId=${response.requestId ?? ''}',
      );
      return response;
    } on JsonHttpException catch (error) {
      watch.stop();
      throw RecommendationApiException(
        statusCode: 0,
        code: error.isTimeout ? 'CLIENT_TIMEOUT' : 'NETWORK_ERROR',
        message: error.isTimeout ? '推荐请求超时' : '无法连接推荐服务',
        retryable: true,
      );
    }
  }

  Future<String> _subject({bool forceIssue = false}) async {
    if (!forceIssue) {
      final stored = await _subjectStore.read();
      if (stored != null) return stored;
    }
    final pending = _subjectRequest;
    if (pending != null) return pending;
    final request = _issueSubject();
    _subjectRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_subjectRequest, request)) _subjectRequest = null;
    }
  }

  Future<String> _issueSubject() async {
    late JsonHttpResponse response;
    try {
      response = await _httpClient.post(
        '/api/v1/recommendations/anonymous-subject',
        body: const <String, dynamic>{},
      );
    } on JsonHttpException catch (error) {
      throw RecommendationApiException(
        statusCode: 0,
        code: error.isTimeout ? 'CLIENT_TIMEOUT' : 'NETWORK_ERROR',
        message: error.isTimeout ? '匿名主体签发超时' : '无法连接推荐服务',
        retryable: true,
      );
    }
    if (response.statusCode != 201 || response.body is! Map) {
      throw _parseError(response, fallbackCode: 'SUBJECT_ISSUE_FAILED');
    }
    final subject = '${(response.body as Map)['anonymousSubjectId'] ?? ''}'
        .trim();
    if (subject.isEmpty) {
      throw const RecommendationApiException(
        statusCode: 201,
        code: 'INVALID_JSON_RESPONSE',
        message: '匿名主体签发响应无效',
      );
    }
    await _subjectStore.write(subject);
    return subject;
  }

  RecommendationApiException _parseError(
    JsonHttpResponse response, {
    String fallbackCode = 'RECOMMENDATION_REQUEST_FAILED',
  }) {
    final envelope = response.body is Map
        ? (response.body as Map)['error']
        : null;
    final error = envelope is Map ? envelope : const <String, dynamic>{};
    final retryHeader = int.tryParse(response.headers['retry-after'] ?? '');
    return RecommendationApiException(
      statusCode: response.statusCode,
      code: '${error['code'] ?? fallbackCode}',
      message: '${error['message'] ?? '推荐服务暂时不可用'}',
      requestId: _text(error['requestId']) ?? response.requestId,
      clientRequestId: _text(error['clientRequestId']),
      retryable: error['retryable'] == true,
      retryAfterSeconds: retryHeader ?? _integer(error['retryAfterSeconds']),
    );
  }

  static void _defaultLog(String message) {
    debugPrintSynchronously('[Jive][Recommendation] $message', wrapWidth: null);
    developer.log(message, name: 'jive.recommendation');
  }
}

String? _text(Object? value) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}

int? _integer(Object? value) => value is int ? value : int.tryParse('$value');

String? _responseRequestId(Map<String, String> headers) {
  final value = headers['x-request-id'];
  if (value == null) return null;
  final sanitized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._:-]'), '');
  return sanitized.isEmpty ? null : sanitized;
}

enum _RecommendationStreamState { idle, streaming, completed }
