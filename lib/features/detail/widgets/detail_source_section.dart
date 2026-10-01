import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../domain/video.dart';
import '../detail_source_controller.dart';

/// 详情页「播放来源」区块：来源芯片横滑栏 + 备用源入口。
/// 芯片点击后的分支处理（候选选择/切换/按需检测）由页面回调完成。
class DetailSourceSection extends StatelessWidget {
  const DetailSourceSection({
    super.key,
    required this.controller,
    required this.onChipTap,
    required this.onMoreSources,
  });

  final DetailSourceController controller;
  final void Function(DetailSourceState state) onChipTap;
  final VoidCallback onMoreSources;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '播放来源',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 8),
        _sourceBar(context),
      ],
    );
  }

  Widget _sourceBar(BuildContext context) {
    final states = controller.sourceStates;
    final hasBackup = states.any(
      (s) =>
          s.source.id != controller.activeSourceId &&
          s.status != DetailSourceStatus.notDetected,
    );
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in states) _chip(context, s),
          if (!hasBackup)
            Padding(
              padding: EdgeInsets.only(right: 6),
              child: ActionChip(
                label: Text('查找其他来源'),
                onPressed: controller.switching
                    ? null
                    : () => controller.detectOtherSources(),
              ),
            )
          else
            Padding(
              padding: EdgeInsets.only(right: 6),
              child: ActionChip(label: Text('更多 ▾'), onPressed: onMoreSources),
            ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, DetailSourceState s) {
    final active = s.source.id == controller.activeSourceId;
    final name = s.source.name;
    String label;
    switch (s.status) {
      case DetailSourceStatus.loaded:
        final c = s.episodeCount;
        label = c != null && c > 0
            ? (c == 1 ? '$name 正片' : '$name $c集')
            : '$name 有资源';
      case DetailSourceStatus.hasResource:
        label = '$name 有资源';
      case DetailSourceStatus.noResult:
        label = '$name 0';
      case DetailSourceStatus.detecting:
        label = '$name …';
      case DetailSourceStatus.failed:
        label = '$name !';
      case DetailSourceStatus.notDetected:
        label = '$name —';
    }
    return Padding(
      padding: EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active
                ? context.appColors.onAccent
                : context.appColors.secondary,
          ),
        ),
        selected: active,
        onSelected: (_) {
          if (active || controller.switching) return;
          onChipTap(s);
        },
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// 候选列表弹层：同一来源匹配到多部影片时让用户挑选。
void showDetailCandidatesSheet(
  BuildContext context, {
  required DetailSourceState s,
  required void Function(Video candidate) onSelect,
}) {
  showModalBottomSheet<void>(
    context: context,
    constraints: BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                '从 ${s.source.name} 选择',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: s.candidates.length,
                itemBuilder: (_, i) {
                  final c = s.candidates[i];
                  return ListTile(
                    leading: c.posterUrl.isEmpty
                        ? Icon(
                            Icons.movie_outlined,
                            color: sheetContext.appColors.tertiary,
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: CachedNetworkImage(
                              imageUrl: c.posterUrl,
                              width: 40,
                              height: 60,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Icon(
                                Icons.movie_outlined,
                                color: sheetContext.appColors.tertiary,
                              ),
                            ),
                          ),
                    title: Text(
                      c.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        c.year,
                        c.remarks,
                        c.area,
                        if (c.episodes.isNotEmpty)
                          c.episodes.length == 1
                              ? '正片'
                              : '${c.episodes.length}集',
                      ].where((e) => e.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: sheetContext.appColors.secondary,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onSelect(c);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 切换来源确认对话框。
Future<bool> confirmSourceSwitch(
  BuildContext context, {
  required String sourceName,
  required String videoTitle,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('确认切换来源'),
        content: Text('将从 $sourceName 加载「$videoTitle」的播放信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
