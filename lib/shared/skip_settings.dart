import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../data/playback/skip_policy.dart';
import 'app_toast.dart';

/// 详情页 / 非全屏播放器底部：按当前影片设置跳过片头、片尾时长。
class SkipSettingsBlock extends ConsumerWidget {
  const SkipSettingsBlock({super.key, required this.videoGlobalId});

  final String videoGlobalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(skipPolicyProvider(videoGlobalId)).value ??
        const SkipPolicy();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SkipChipRow(
          label: '跳过片头',
          current: policy.introSeconds,
          valueKeyPrefix: 'skip-intro',
          onChanged: (seconds) => ref
              .read(skipPolicyProvider(videoGlobalId).notifier)
              .setIntroSeconds(seconds),
        ),
        const SizedBox(height: 12),
        _SkipChipRow(
          label: '跳过片尾',
          current: policy.outroSeconds,
          valueKeyPrefix: 'skip-outro',
          onChanged: (seconds) => ref
              .read(skipPolicyProvider(videoGlobalId).notifier)
              .setOutroSeconds(seconds),
        ),
      ],
    );
  }
}

class _SkipChipRow extends StatelessWidget {
  const _SkipChipRow({
    required this.label,
    required this.current,
    required this.valueKeyPrefix,
    required this.onChanged,
  });

  final String label;
  final int current;
  final String valueKeyPrefix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final customSelected = current > 0 && !isSkipPreset(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(
              key: ValueKey('$valueKeyPrefix-off'),
              text: '关闭',
              selected: current <= 0,
              onSelected: () => onChanged(0),
            ),
            for (final seconds in skipDurationPresets)
              _chip(
                key: ValueKey('$valueKeyPrefix-$seconds'),
                text: '$seconds 秒',
                selected: current == seconds,
                onSelected: () => onChanged(seconds),
              ),
            _chip(
              key: ValueKey('$valueKeyPrefix-custom'),
              text: customSelected ? '$current 秒' : '自定义',
              selected: customSelected,
              onSelected: () async {
                final custom = await showCustomSkipSecondsDialog(
                  context,
                  current: current,
                );
                if (custom != null) onChanged(custom);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip({
    required Key key,
    required String text,
    required bool selected,
    required VoidCallback onSelected,
  }) => ChoiceChip(
    key: key,
    label: Text(text),
    selected: selected,
    showCheckmark: false,
    onSelected: (_) => onSelected(),
  );
}

Future<int?> showCustomSkipSecondsDialog(
  BuildContext context, {
  required int current,
}) async {
  final initial = current > 0 && !isSkipPreset(current) ? '$current' : '';
  final editor = TextEditingController(text: initial);
  final result = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('自定义跳过时长'),
      content: TextField(
        controller: editor,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(hintText: '1–600', suffixText: '秒'),
        onSubmitted: (value) {
          final seconds = int.tryParse(value.trim());
          Navigator.pop(dialogContext, seconds);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final seconds = int.tryParse(editor.text.trim());
            Navigator.pop(dialogContext, seconds);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
  editor.dispose();
  if (result == null) return null;
  if (result < skipDurationMin || result > skipDurationMax) {
    if (context.mounted) {
      showAppToast(context, '请输入 $skipDurationMin–$skipDurationMax 秒');
    }
    return null;
  }
  return result;
}
