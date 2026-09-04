import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../domain/playback_selection.dart';
import '../../../domain/video.dart';
import '../../../shared/skip_settings.dart';

/// 竖屏（非全屏）状态下播放器下方的信息面板：整部简介 + 选集列表。
class PlayerInfoPanel extends StatefulWidget {
  const PlayerInfoPanel({
    super.key,
    required this.video,
    required this.current,
    required this.onEpisodeTap,
  });

  final Video video;
  final Episode current;
  final ValueChanged<Episode> onEpisodeTap;

  @override
  State<PlayerInfoPanel> createState() => _PlayerInfoPanelState();
}

class _PlayerInfoPanelState extends State<PlayerInfoPanel> {
  /// 剧集超过该数量时按每组 100 集折叠展示，与详情页一致。
  static const int _epsGroupSize = 100;

  bool expanded = false;
  late Set<int> _expandedEpsGroups;

  int get _currentIndex =>
      indexOfEpisode(widget.video.episodes, widget.current) ?? 0;

  @override
  void initState() {
    super.initState();
    _expandedEpsGroups = {_groupOf(_currentIndex)};
  }

  @override
  void didUpdateWidget(PlayerInfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current.identity != widget.current.identity ||
        oldWidget.current.id != widget.current.id ||
        oldWidget.current.name != widget.current.name ||
        oldWidget.video.episodes.length != widget.video.episodes.length) {
      _expandedEpsGroups.add(_groupOf(_currentIndex));
    }
  }

  int _groupOf(int index) {
    final last = math.max(widget.video.episodes.length - 1, 0);
    return index.clamp(0, last) ~/ _epsGroupSize;
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final colors = context.appColors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SkipSettingsBlock(videoGlobalId: video.globalId),
        const SizedBox(height: 20),
        Text(
          '简介',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          video.description.isEmpty ? '暂无简介' : video.description,
          maxLines: expanded ? null : 4,
          overflow: expanded ? null : TextOverflow.ellipsis,
          style: TextStyle(color: colors.secondary, fontSize: 14, height: 1.55),
        ),
        if (video.description.length > 100)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => expanded = !expanded),
              child: Text(expanded ? '收起' : '展开'),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          '选集（${video.episodes.length}）',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        if (video.episodes.length <= _epsGroupSize)
          _epsWrap(video.episodes, 0, video.episodes.length)
        else
          _epsGroups(video.episodes),
      ],
    );
  }

  Widget _epsGroups(List<Episode> episodes) {
    final total = episodes.length;
    final groupCount = (total + _epsGroupSize - 1) ~/ _epsGroupSize;
    return Column(
      children: [
        for (var g = 0; g < groupCount; g++) ...[
          _epsGroupHeader(total, g),
          if (_expandedEpsGroups.contains(g))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _epsWrap(
                episodes,
                g * _epsGroupSize,
                math.min((g + 1) * _epsGroupSize, total),
              ),
            ),
        ],
      ],
    );
  }

  Widget _epsGroupHeader(int total, int group) {
    final colors = context.appColors;
    final start = group * _epsGroupSize;
    final end = math.min(start + _epsGroupSize, total);
    final isExpanded = _expandedEpsGroups.contains(group);
    return InkWell(
      onTap: () => setState(() {
        if (isExpanded) {
          _expandedEpsGroups.remove(group);
        } else {
          _expandedEpsGroups.add(group);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '第 ${start + 1}–$end 集',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.secondary,
                ),
              ),
            ),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: colors.secondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _epsWrap(List<Episode> episodes, int start, int end) {
    final colors = context.appColors;
    final selectedIndex = _currentIndex;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var idx = start; idx < end; idx++)
          ChoiceChip(
            label: Text(episodes[idx].name),
            selected: idx == selectedIndex,
            selectedColor: colors.accent,
            labelStyle: TextStyle(
              color: idx == selectedIndex ? colors.onAccent : colors.secondary,
            ),
            showCheckmark: false,
            onSelected: (_) => widget.onEpisodeTap(episodes[idx]),
          ),
      ],
    );
  }
}
