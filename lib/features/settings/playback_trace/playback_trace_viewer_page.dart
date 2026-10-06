import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import 'playback_trace_report.dart';

class PlaybackTraceViewerPage extends StatefulWidget {
  const PlaybackTraceViewerPage({super.key});

  @override
  State<PlaybackTraceViewerPage> createState() =>
      _PlaybackTraceViewerPageState();
}

class _PlaybackTraceViewerPageState extends State<PlaybackTraceViewerPage> {
  final TextEditingController _inputController = TextEditingController();
  List<PlaybackTraceReport> _reports = const [];
  String? _error;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null) return;
    _inputController.text = data!.text!;
    _parse();
  }

  void _parse() {
    try {
      final reports = parsePlaybackTraceLogs(_inputController.text);
      setState(() {
        _reports = reports;
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() {
        _reports = const [];
        _error = error.message;
      });
    } catch (_) {
      setState(() {
        _reports = const [];
        _error = '日志解析失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放耗时分析')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Text(
          '粘贴控制台中的 JIVE_PLAYBACK_TRACE JSON；支持 JSON、JSONL 和控制台日志。标记 ↳ 的子阶段已包含在父阶段中，耗时不能重复相加。',
          style: TextStyle(color: context.appColors.secondary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('playback-trace-input'),
          controller: _inputController,
          minLines: 5,
          maxLines: 10,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '{"tag":"JIVE_PLAYBACK_TRACE", ...}',
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _parse,
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('解析日志'),
            ),
            OutlinedButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste_outlined),
              label: const Text('从剪贴板导入'),
            ),
            TextButton(
              onPressed: () {
                _inputController.clear();
                setState(() {
                  _reports = const [];
                  _error = null;
                });
              },
              child: const Text('清空'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: context.appColors.error)),
        ],
        if (_reports.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            '已导入 ${_reports.length} 次启动记录',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_reports.length >= 2) ...[
            const SizedBox(height: 10),
            _TraceComparisonCard(
              previous: _reports[_reports.length - 2],
              current: _reports.last,
            ),
          ],
          const SizedBox(height: 10),
          for (final report in _reports.reversed) ...[
            _TraceReportCard(report: report),
            const SizedBox(height: 12),
          ],
        ],
      ],
    ),
  );
}

class _TraceComparisonCard extends StatelessWidget {
  const _TraceComparisonCard({required this.previous, required this.current});

  final PlaybackTraceReport previous;
  final PlaybackTraceReport current;

  @override
  Widget build(BuildContext context) {
    final previousStages = _stageDurations(previous);
    final currentStages = _stageDurations(current);
    final names =
        <String>{...previousStages.keys, ...currentStages.keys}.toList()
          ..sort((a, b) {
            final aDuration = currentStages[a] ?? previousStages[a] ?? 0;
            final bDuration = currentStages[b] ?? previousStages[b] ?? 0;
            return bDuration.compareTo(aDuration);
          });
    final rows = <({String name, double? previousMs, double? currentMs})>[
      (
        name: 'startupTotal',
        previousMs: previous.totalStartupMs,
        currentMs: current.totalStartupMs,
      ),
      for (final name in names)
        (
          name: name,
          previousMs: previousStages[name],
          currentMs: currentStages[name],
        ),
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最近两次对比', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${previous.episodeName} → ${current.episodeName}',
              style: TextStyle(
                color: context.appColors.secondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 22,
                horizontalMargin: 0,
                columns: const [
                  DataColumn(label: Text('阶段')),
                  DataColumn(label: Text('上次'), numeric: true),
                  DataColumn(label: Text('本次'), numeric: true),
                  DataColumn(label: Text('变化'), numeric: true),
                ],
                rows: [
                  for (final row in rows)
                    DataRow(
                      cells: [
                        DataCell(Text(_stageLabel(row.name))),
                        DataCell(Text(_optionalDuration(row.previousMs))),
                        DataCell(Text(_optionalDuration(row.currentMs))),
                        DataCell(
                          _DeltaLabel(
                            previousMs: row.previousMs,
                            currentMs: row.currentMs,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeltaLabel extends StatelessWidget {
  const _DeltaLabel({required this.previousMs, required this.currentMs});

  final double? previousMs;
  final double? currentMs;

  @override
  Widget build(BuildContext context) {
    final previous = previousMs;
    final current = currentMs;
    if (previous == null || current == null || previous == 0) {
      return const Text('—');
    }
    final percent = (current - previous) / previous * 100;
    final faster = percent < 0;
    final unchanged = percent.abs() < 0.05;
    return Text(
      '${percent >= 0 ? '+' : ''}${percent.toStringAsFixed(1)}%',
      style: TextStyle(
        color: unchanged
            ? context.appColors.secondary
            : faster
            ? context.appColors.success
            : context.appColors.error,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

Map<String, double> _stageDurations(PlaybackTraceReport report) {
  final result = <String, double>{};
  for (final stage in report.stages) {
    result.update(
      stage.name,
      (duration) => duration + stage.durationMs,
      ifAbsent: () => stage.durationMs,
    );
  }
  return result;
}

String _optionalDuration(double? milliseconds) =>
    milliseconds == null ? '—' : _durationLabel(milliseconds);

class _TraceReportCard extends StatelessWidget {
  const _TraceReportCard({required this.report});

  final PlaybackTraceReport report;

  @override
  Widget build(BuildContext context) {
    final ranking = report.ranking;
    final maxMs = ranking.isEmpty ? 1.0 : ranking.first.durationMs;
    final success = report.result == 'success';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${report.videoTitle} · ${report.episodeName}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _ResultChip(success: success, result: report.result),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [report.sourceId, report.format, report.mode]
                  .where((value) => value.isNotEmpty && value != 'unknown')
                  .join(' · '),
              style: TextStyle(color: context.appColors.secondary),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                _Metric(
                  label: '启动总耗时',
                  value: _durationLabel(report.totalStartupMs),
                ),
                if (ranking.isNotEmpty)
                  _Metric(
                    label: '最慢阶段',
                    value:
                        '${_stageLabel(ranking.first.name)} ${_durationLabel(ranking.first.durationMs)}',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            for (final stage in ranking)
              Padding(
                padding: const EdgeInsets.only(bottom: 11),
                child: _StageBar(
                  stage: stage,
                  fraction: (stage.durationMs / maxMs).clamp(0.02, 1),
                ),
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看原始 JSON'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(report.raw),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(color: context.appColors.secondary, fontSize: 12),
      ),
      const SizedBox(height: 2),
      Text(value, style: Theme.of(context).textTheme.titleSmall),
    ],
  );
}

class _StageBar extends StatelessWidget {
  const _StageBar({required this.stage, required this.fraction});

  final PlaybackTraceStageReport stage;
  final double fraction;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '${stage.parent == null ? '' : '↳ '}${_stageLabel(stage.name)}',
            ),
          ),
          Text(
            _durationLabel(stage.durationMs),
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      const SizedBox(height: 5),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ColoredBox(
          color: context.appColors.divider,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction,
              child: SizedBox(
                height: 8,
                child: ColoredBox(
                  color: stage.result == 'success'
                      ? context.appColors.accentForeground
                      : context.appColors.error,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _ResultChip extends StatelessWidget {
  const _ResultChip({required this.success, required this.result});

  final bool success;
  final String result;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color:
          (success
                  ? context.appColors.accentForeground
                  : context.appColors.error)
              .withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(success ? '成功' : result),
  );
}

String _durationLabel(double milliseconds) => milliseconds >= 1000
    ? '${(milliseconds / 1000).toStringAsFixed(2)}s'
    : '${milliseconds.toStringAsFixed(milliseconds >= 100 ? 0 : 1)}ms';

String _stageLabel(String stage) =>
    const {
      'startupTotal': '启动总耗时',
      'downloadSelectionLookup': '下载选集查询',
      'detailResolvePlayback': '详情播放信息解析',
      'favoriteSnapshotRefresh': '收藏快照更新',
      'playerRoutePush': '播放器页面打开',
      'skipPolicyLoad': '跳片头策略加载',
      'unknownCachePrecheck': '未知格式提前探测',
      'playbackSourceResolve': '真实播放地址解析',
      'contentTypeSniff': '媒体格式探测',
      'hlsSessionPrepare': 'HLS 清单与会话构建',
      'proxyServerStart': '本地代理启动',
      'cacheManagerLoad': '缓存管理器就绪',
      'sessionCacheLookup': '完整缓存查询',
      'hlsManifestFetch': 'HLS 清单网络请求',
      'hlsManifestParse': 'HLS 清单解析',
      'hlsAdFilter': 'HLS 广告过滤',
      'hlsProxyPlan': '代理清单改写',
      'sessionCacheEntry': '缓存条目初始化',
      'sessionCachePersist': '清单与时间轴落盘',
      'sessionCacheAcquire': '缓存引用获取',
      'proxyFallbackCleanup': '失败播放资源释放',
      'controllerInitializeProxy': '代理播放器初始化',
      'controllerInitializeDirect': '直连播放器初始化',
      'controllerConfigure': '播放器配置总计',
      'resumeSeek': '恢复续播位置',
      'controllerSetSpeed': '设置播放速度',
      'controllerSetVolume': '设置播放音量',
      'controllerPlay': '启动播放',
    }[stage] ??
    stage;
