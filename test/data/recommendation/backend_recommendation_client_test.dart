import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/network/json_http_client.dart';
import 'package:jive/data/recommendation/anonymous_subject_store.dart';
import 'package:jive/data/recommendation/backend_recommendation_client.dart';
import 'package:jive/data/recommendation/recommendation_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('issues and persists subject then parses personalized response', () async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('anonymous-subject')) {
        return _jsonResponse({
          'anonymousSubjectId': 'v1.subject',
          'issuedAt': '2026-09-14T02:28:00Z',
        }, 201);
      }
      return _jsonResponse(_batchJson(), 200);
    });
    final prefs = await SharedPreferences.getInstance();
    final client = _client(transport, prefs);

    final batch = await client.recommend(history: const [], library: const []);
    await client.recommend(history: const [], library: const []);

    expect(requests, hasLength(3));
    expect(
      requests.where(
        (request) => request.url.path.endsWith('anonymous-subject'),
      ),
      hasLength(1),
    );
    expect(requests.last.headers['x-jive-anonymous-subject'], 'v1.subject');
    expect(prefs.getString('jive_anonymous_subject_v1'), 'v1.subject');
    final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(
      body.keys,
      containsAll([
        'clientRequestId',
        'locale',
        'pageSize',
        'history',
        'library',
      ]),
    );
    expect(
      body['clientRequestId'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(batch.items.single.modelConfidence, 0.91);
    expect(batch.page.nextCursor, 'cursor-2');
  });

  test('next page sends only clientRequestId and cursor', () async {
    SharedPreferences.setMockInitialValues({
      'jive_anonymous_subject_v1': 'v1.stored',
    });
    late http.Request captured;
    final client = _client(
      MockClient((request) async {
        captured = request;
        return _jsonResponse(_batchJson(page: 2), 200);
      }),
      await SharedPreferences.getInstance(),
    );

    await client.nextPage('opaque-cursor');

    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body.keys.toSet(), {'clientRequestId', 'cursor'});
    expect(body['cursor'], 'opaque-cursor');
  });

  test(
    '401 clears subject, reissues once and replays operation once',
    () async {
      SharedPreferences.setMockInitialValues({
        'jive_anonymous_subject_v1': 'v1.expired',
      });
      var personalizedCalls = 0;
      var issueCalls = 0;
      final client = _client(
        MockClient((request) async {
          if (request.url.path.endsWith('anonymous-subject')) {
            issueCalls++;
            return _jsonResponse({'anonymousSubjectId': 'v1.fresh'}, 201);
          }
          personalizedCalls++;
          if (personalizedCalls == 1) {
            return _jsonResponse({
              'error': {
                'code': 'INVALID_ANONYMOUS_SUBJECT',
                'message': 'invalid',
                'retryable': false,
              },
            }, 401);
          }
          return _jsonResponse(_batchJson(), 200);
        }),
        await SharedPreferences.getInstance(),
      );

      await client.recommend(history: const [], library: const []);

      expect(issueCalls, 1);
      expect(personalizedCalls, 2);
    },
  );

  test('a second 401 is surfaced without another reissue loop', () async {
    SharedPreferences.setMockInitialValues({
      'jive_anonymous_subject_v1': 'v1.expired',
    });
    var personalizedCalls = 0;
    var issueCalls = 0;
    final client = _client(
      MockClient((request) async {
        if (request.url.path.endsWith('anonymous-subject')) {
          issueCalls++;
          return _jsonResponse({'anonymousSubjectId': 'v1.fresh'}, 201);
        }
        personalizedCalls++;
        return _jsonResponse({
          'error': {
            'code': 'INVALID_ANONYMOUS_SUBJECT',
            'message': 'invalid',
            'retryable': false,
          },
        }, 401);
      }),
      await SharedPreferences.getInstance(),
    );

    await expectLater(
      client.recommend(history: const [], library: const []),
      throwsA(isA<RecommendationApiException>()),
    );

    expect(personalizedCalls, 2);
    expect(issueCalls, 1);
  });

  test('preserves structured error and prefers Retry-After header', () async {
    SharedPreferences.setMockInitialValues({
      'jive_anonymous_subject_v1': 'v1.stored',
    });
    final client = _client(
      MockClient(
        (_) async => _jsonResponse(
          {
            'error': {
              'code': 'RECOMMENDATION_RATE_LIMITED',
              'message': '稍后重试',
              'requestId': 'req-429',
              'retryable': true,
              'retryAfterSeconds': 3,
            },
          },
          429,
          headers: {'retry-after': '10'},
        ),
      ),
      await SharedPreferences.getInstance(),
    );

    await expectLater(
      client.recommend(history: const [], library: const []),
      throwsA(
        isA<RecommendationApiException>()
            .having((error) => error.statusCode, 'status', 429)
            .having(
              (error) => error.code,
              'code',
              'RECOMMENDATION_RATE_LIMITED',
            )
            .having((error) => error.retryAfterSeconds, 'retry after', 10),
      ),
    );
  });

  test('accepts cold-start response without generatedAt or items', () async {
    SharedPreferences.setMockInitialValues({
      'jive_anonymous_subject_v1': 'v1.stored',
    });
    final client = _client(
      MockClient(
        (_) async => _jsonResponse({
          'requestId': 'req-cold',
          'clientRequestId': 'client-cold',
          'servedAt': '2026-09-14T02:28:01Z',
          'source': 'none',
          'mode': 'cold_start',
          'items': [],
          'page': {
            'index': 1,
            'pageSize': 24,
            'hasMore': false,
            'nextCursor': null,
          },
          'meta': {
            'reason': 'insufficient_preference_signals',
            'llmCalled': false,
          },
        }, 200),
      ),
      await SharedPreferences.getInstance(),
    );

    final result = await client.recommend(history: const [], library: const []);

    expect(result.isColdStart, isTrue);
    expect(result.items, isEmpty);
  });

  test('streams NDJSON items before the authoritative done result', () async {
    SharedPreferences.setMockInitialValues({
      'jive_anonymous_subject_v1': 'v1.stored',
    });
    late http.Request captured;
    final client = _client(
      MockClient((request) async {
        captured = request;
        final requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        final clientRequestId = requestBody['clientRequestId'] as String;
        final result = _batchJson()..['clientRequestId'] = clientRequestId;
        final candidate = (result['items'] as List).single;
        return http.Response(
          [
            jsonEncode({
              'type': 'start',
              'requestId': 'req-stream',
              'clientRequestId': clientRequestId,
              'mode': 'personalized',
              'source': 'llm',
            }),
            jsonEncode({'type': 'item', 'index': 1, 'item': candidate}),
            jsonEncode({'type': 'done', 'result': result}),
            '',
          ].join('\n'),
          200,
          headers: {'content-type': 'application/x-ndjson; charset=utf-8'},
        );
      }),
      await SharedPreferences.getInstance(),
    );

    final events = await client
        .recommendStream(history: const [], library: const [])
        .events
        .toList();

    expect(captured.headers['accept'], 'application/x-ndjson');
    expect(events, [
      isA<RecommendationStreamStart>(),
      isA<RecommendationStreamItem>().having(
        (event) => event.index,
        'index',
        1,
      ),
      isA<RecommendationStreamDone>().having(
        (event) => event.result.items.single.title,
        'title',
        '银翼杀手2049',
      ),
    ]);
  });
}

BackendRecommendationClient _client(
  http.Client transport,
  SharedPreferences preferences,
) => BackendRecommendationClient(
  httpClient: JsonHttpClient(
    client: transport,
    baseUri: Uri.parse('https://api.example.com'),
  ),
  subjectStore: AnonymousSubjectStore(preferences: preferences),
  logSink: (_) {},
);

http.Response _jsonResponse(
  Object body,
  int statusCode, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  statusCode,
  headers: {'content-type': 'application/json; charset=utf-8', ...headers},
);

Map<String, dynamic> _batchJson({int page = 1}) => {
  'requestId': 'req-1',
  'clientRequestId': 'client-1',
  'generatedAt': '2026-09-14T02:28:01Z',
  'servedAt': '2026-09-14T02:28:01Z',
  'expiresAt': '2026-09-14T02:58:01Z',
  'sessionId': 'session-1',
  'source': 'llm',
  'mode': 'personalized',
  'items': [
    {
      'title': '银翼杀手2049',
      'originalTitle': 'Blade Runner 2049',
      'aliases': ['银翼杀手 2049'],
      'year': '2017',
      'mediaType': 'movie',
      'category': 'movie',
      'latestSeasonNumber': null,
      'modelConfidence': 0.91,
      'reason': '偏好科幻悬疑',
    },
  ],
  'page': {
    'index': page,
    'pageSize': 24,
    'hasMore': page == 1,
    'nextCursor': page == 1 ? 'cursor-2' : null,
  },
  'meta': {'cache': 'miss'},
};
