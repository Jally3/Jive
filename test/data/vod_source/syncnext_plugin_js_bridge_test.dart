import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jive/data/vod_source/adapters/syncnext_plugin_models.dart';
import 'package:jive/data/vod_source/adapters/syncnext_plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'js http fetch delivers html without going through Promise evaluate',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'www.youknow.tv');
        return http.Response.bytes(
          utf8.encode(
            '<a class="module-poster-item module-item" href="/d/1/" title="男生女生向前冲">'
            '<img data-original="https://cdn.example.com/a.jpg">'
            '</a>',
          ),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });

      final session = await JsPluginSession.fromBundle(
        client: client,
        bundle: SyncnextPluginBundle(
          config: SyncnextPluginConfig.fromJson({
            'name': 'YouKnowTV',
            'host': 'https://www.youknow.tv',
            'files': ['app.js'],
            'pages': [
              {
                'key': 'index',
                'title': '今日更新',
                'url': 'https://www.youknow.tv/label/new/',
                'javascript': 'buildMedias',
              },
            ],
            'episodes': {'javascript': 'Episodes'},
            'player': {'javascript': 'Player'},
          }),
          scripts: [
            (
              name: 'app.js',
              source: r'''
function buildMedias(inputURL) {
  $http.fetch({ url: inputURL, method: "GET" }).then(function (res) {
    var ok = res && res.statusCode === 200 && String(res.body).indexOf("module-poster-item") >= 0;
    $next.toMedias(JSON.stringify([{
      id: "https://www.youknow.tv/d/1/",
      title: ok ? "男生女生向前冲" : "missing",
      coverURLString: "https://cdn.example.com/a.jpg",
      descriptionText: String(res.statusCode),
      detailURLString: "https://www.youknow.tv/d/1/"
    }]));
  }).catch(function (error) {
    $next.emptyView(String(error || "fetch failed"));
  });
}
''',
            ),
          ],
        ),
      );
      addTearDown(session.dispose);

      final result = await session
          .invoke(
            'buildMedias',
            url: 'https://www.youknow.tv/label/new/',
            timeout: const Duration(seconds: 8),
          )
          .timeout(const Duration(seconds: 10));

      expect(result.isEmptyView, isFalse, reason: '${result.payload}');
      expect(result.isMedias, isTrue);
      final decoded = decodePluginJson(result.payload);
      expect(decoded, isA<List>());
      expect((decoded as List).first['title'], '男生女生向前冲');
    },
    skip: !(Platform.isMacOS || Platform.isIOS),
  );
}
