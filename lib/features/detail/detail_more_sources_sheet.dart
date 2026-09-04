import 'package:flutter/material.dart';
import '../../app/theme.dart';
import '../../domain/vod_source.dart';
import './detail_source_controller.dart';

class DetailMoreSourcesSheet extends StatelessWidget {
  const DetailMoreSourcesSheet({
    super.key,
    required this.sources,
    required this.controller,
    required this.onSourceTap,
    required this.onDetectAll,
  });

  final List<VodSource> sources;
  final DetailSourceController controller;
  final ValueChanged<String> onSourceTap;
  final VoidCallback onDetectAll;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => SafeArea(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Text(
                    '全部来源',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  Spacer(),
                  TextButton.icon(
                    onPressed: onDetectAll,
                    icon: Icon(Icons.search, size: 18),
                    label: Text('查找全部来源'),
                  ),
                ],
              ),
            ),
            Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: sources.length,
                itemBuilder: (_, index) {
                  final source = sources[index];
                  final s = controller.stateFor(source.id);
                  final isActive = source.id == controller.activeSourceId;
                  return ListTile(
                    leading: Icon(
                      isActive ? Icons.check_circle : Icons.source_outlined,
                      color: isActive
                          ? context.appColors.accentForeground
                          : context.appColors.tertiary,
                    ),
                    title: Text(source.name),
                    subtitle: Text(
                      _statusText(s),
                      style: TextStyle(
                        fontSize: 13,
                        color: s?.error != null
                            ? context.appColors.error
                            : context.appColors.secondary,
                      ),
                    ),
                    trailing: s?.status == DetailSourceStatus.detecting
                        ? SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: () => onSourceTap(source.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );

  String _statusText(DetailSourceState? s) {
    if (s == null) return '未检测';
    switch (s.status) {
      case DetailSourceStatus.notDetected:
        return '未检测';
      case DetailSourceStatus.detecting:
        return '检测中…';
      case DetailSourceStatus.hasResource:
        return '有资源';
      case DetailSourceStatus.loaded:
        final count = s.episodeCount;
        return count != null && count > 0 ? '$count 集' : '有资源';
      case DetailSourceStatus.noResult:
        return '无结果';
      case DetailSourceStatus.failed:
        return '请求失败';
    }
  }
}
