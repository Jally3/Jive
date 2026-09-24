import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/features/settings/playback_trace/playback_trace_report.dart';
import 'package:jive/features/settings/playback_trace/playback_trace_viewer_page.dart';

Map<String, Object?> _log(String id, double totalMs) => {
  'tag': 'JIVE_PLAYBACK_TRACE',
  'traceId': id,
  'result': 'success',
  'totalStartupMs': totalMs,
  'video': {'title': '测试视频', 'sourceId': 'source'},
  'episode': {'name': '第 1 集'},
  'playback': {'format': 'hls', 'mode': 'streamingAndCaching'},
  'stages': [
    {
      'name': 'playbackSourceResolve',
      'durationMs': 1200.5,
      'result': 'success',
    },
    {
      'name': 'controllerInitializeProxy',
      'durationMs': 800,
      'result': 'success',
    },
  ],
};

void main() {
  test('parses one structured playback trace and ranks its stages', () {
    final reports = parsePlaybackTraceLogs(jsonEncode(_log('one', 2500)));

    expect(reports, hasLength(1));
    expect(reports.single.videoTitle, '测试视频');
    expect(reports.single.totalStartupMs, 2500);
    expect(reports.single.ranking.first.name, 'playbackSourceResolve');
    expect(reports.single.ranking.first.durationMs, 1200.5);
  });

  test('parses JSONL with console prefixes and ignores unrelated lines', () {
    final input = [
      'unrelated flutter output',
      '[log] ${jsonEncode(_log('one', 2500))}',
      'JIVE_PLAYBACK_TRACE ${jsonEncode(_log('two', 1900))}',
    ].join('\n');

    final reports = parsePlaybackTraceLogs(input);

    expect(reports.map((report) => report.traceId), ['one', 'two']);
  });

  test('reassembles chunked terminal output', () {
    final payload = base64Encode(
      utf8.encode(jsonEncode(_log('chunked', 3100))),
    );
    final midpoint = payload.length ~/ 2;
    final input = [
      'flutter: JIVE_PLAYBACK_TRACE_CHUNK chunked 1/2 ${payload.substring(0, midpoint)}',
      'flutter: JIVE_PLAYBACK_TRACE_CHUNK chunked 2/2 ${payload.substring(midpoint)}',
      'flutter: JIVE_PLAYBACK_TRACE_SUMMARY traceId=chunked result=success',
    ].join('\n');

    final reports = parsePlaybackTraceLogs(input);

    expect(reports, hasLength(1));
    expect(reports.single.traceId, 'chunked');
    expect(reports.single.totalStartupMs, 3100);
  });

  test('rejects unrelated JSON', () {
    expect(
      () => parsePlaybackTraceLogs('{"tag":"OTHER"}'),
      throwsFormatException,
    );
  });

  testWidgets('viewer imports a trace and shows the stage ranking', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PlaybackTraceViewerPage()));
    await tester.enterText(
      find.byKey(const ValueKey('playback-trace-input')),
      jsonEncode(_log('viewer', 2500)),
    );
    await tester.tap(find.text('解析日志'));
    await tester.pump();

    expect(find.text('测试视频 · 第 1 集'), findsOneWidget);
    expect(find.text('真实播放地址解析'), findsOneWidget);
    expect(find.text('代理播放器初始化'), findsOneWidget);
    expect(find.textContaining('2.50s'), findsOneWidget);
  });

  testWidgets('viewer compares the latest two imported traces', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlaybackTraceViewerPage()));
    await tester.enterText(
      find.byKey(const ValueKey('playback-trace-input')),
      [
        jsonEncode(_log('before', 2500)),
        jsonEncode(_log('after', 1900)),
      ].join('\n'),
    );
    await tester.tap(find.text('解析日志'));
    await tester.pump();

    expect(find.text('最近两次对比'), findsOneWidget);
    expect(find.text('启动总耗时'), findsWidgets);
    expect(find.text('-24.0%'), findsOneWidget);
  });
}
