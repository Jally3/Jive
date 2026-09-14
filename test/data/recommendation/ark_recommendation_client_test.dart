import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/recommendation/ark_recommendation_client.dart';
import 'package:jive/data/recommendation/ark_recommendation_config.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/watch_record.dart';

const _config = ArkRecommendationConfig(
  enabled: true,
  apiKey: 'test-secret',
  baseUrl: 'https://ark.cn-beijing.volces.com/api/coding/v3/',
  model: 'ark-code-latest',
);

void main() {
  test(
    'posts Coding Plan request and parses strict recommendation JSON',
    () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'items': [
                      {
                        'title': '银翼杀手2049',
                        'originalTitle': 'Blade Runner 2049',
                        'aliases': ['银翼杀手 2049'],
                        'year': '2017',
                        'mediaType': 'movie',
                        'category': 'movie',
                        'confidence': 0.91,
                        'reason': '偏好科幻悬疑',
                      },
                    ],
                  }),
                },
              },
            ],
            'usage': {
              'prompt_tokens': 100,
              'completion_tokens': 50,
              'total_tokens': 150,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final subject = ArkRecommendationClient(client: client, config: _config);
      final now = DateTime(2026, 9, 13);

      final result = await subject.recommend(
        history: [
          WatchRecord(
            video: const Video(id: '1', title: '降临', category: '电影片'),
            episodeId: '1',
            episodeName: '正片',
            positionMs: 90,
            durationMs: 100,
            updatedAt: now,
            completed: true,
          ),
        ],
        library: const [],
      );

      expect(
        captured.url.toString(),
        'https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions',
      );
      expect(captured.headers['authorization'], 'Bearer test-secret');
      final requestJson = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(requestJson['model'], 'ark-code-latest');
      expect(requestJson['response_format'], {'type': 'json_object'});
      expect(result.items.single.title, '银翼杀手2049');
      expect(result.items.single.year, '2017');
      expect(result.usage.totalTokens, 150);
    },
  );

  test('does not leak response body when authorization fails', () async {
    final logs = <String>[];
    final client = MockClient(
      (_) async => http.Response(
        'server leaked credential details',
        401,
        headers: {'x-request-id': 'request-401'},
      ),
    );
    final subject = ArkRecommendationClient(
      client: client,
      config: _config,
      logSink: logs.add,
    );

    await expectLater(
      subject.recommend(history: const [], library: const []),
      throwsA(
        isA<RecommendationRequestException>().having(
          (error) => '$error',
          'message',
          '方舟密钥或套餐权限无效',
        ),
      ),
    );
    expect(logs, hasLength(1));
    expect(logs.single, contains('stage=http'));
    expect(logs.single, contains('status=401'));
    expect(logs.single, contains('requestId=request-401'));
    expect(logs.single, isNot(contains('test-secret')));
    expect(logs.single, isNot(contains('server leaked credential details')));
  });

  test('rejects a successful response without usable items', () async {
    final logs = <String>[];
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"items":[]}'},
            },
          ],
        }),
        200,
      ),
    );
    final subject = ArkRecommendationClient(
      client: client,
      config: _config,
      logSink: logs.add,
    );

    await expectLater(
      subject.recommend(history: const [], library: const []),
      throwsA(
        isA<RecommendationRequestException>().having(
          (error) => '$error',
          'message',
          '方舟返回的推荐 JSON 无法解析',
        ),
      ),
    );
    expect(logs.single, contains('stage=parse'));
    expect(logs.single, contains('responseBytes='));
  });

  test('logs timeout metadata without request payload or key', () async {
    final logs = <String>[];
    final client = MockClient((_) => Completer<http.Response>().future);
    final subject = ArkRecommendationClient(
      client: client,
      config: _config,
      timeout: const Duration(milliseconds: 1),
      logSink: logs.add,
    );

    await expectLater(
      subject.recommend(history: const [], library: const []),
      throwsA(
        isA<RecommendationRequestException>().having(
          (error) => '$error',
          'message',
          '方舟推荐请求超时',
        ),
      ),
    );
    expect(logs.single, contains('stage=timeout'));
    expect(logs.single, contains('elapsedMs='));
    expect(logs.single, isNot(contains('test-secret')));
    expect(logs.single, isNot(contains('user_data')));
  });
}
