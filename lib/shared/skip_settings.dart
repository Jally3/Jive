import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../data/playback/skip_policy.dart';
import 'app_anchored_menu.dart';
import 'app_toast.dart';

/// Compact, shared intro/outro settings for details and portrait player info.
class SkipSettingsBlock extends ConsumerWidget {
  const SkipSettingsBlock({super.key, required this.videoGlobalId});

  final String videoGlobalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(skipPolicyProvider(videoGlobalId)).value ??
        const SkipPolicy();
    return Row(
      children: [
        Expanded(
          child: _SkipStatusButton(
            key: const ValueKey('skip-intro-button'),
            label: '片头',
            current: policy.introSeconds,
            onPressed: (anchorContext) => _openPicker(
              anchorContext,
              ref,
              isIntro: true,
              current: policy.introSeconds,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SkipStatusButton(
            key: const ValueKey('skip-outro-button'),
            label: '片尾',
            current: policy.outroSeconds,
            onPressed: (anchorContext) => _openPicker(
              anchorContext,
              ref,
              isIntro: false,
              current: policy.outroSeconds,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openPicker(
    BuildContext context,
    WidgetRef ref, {
    required bool isIntro,
    required int current,
  }) async {
    Future<void> save(int seconds) async {
      final notifier = ref.read(skipPolicyProvider(videoGlobalId).notifier);
      if (isIntro) {
        await notifier.setIntroSeconds(seconds);
      } else {
        await notifier.setOutroSeconds(seconds);
      }
    }

    final picker = _SkipPicker(
      isIntro: isIntro,
      current: current,
      onSave: save,
    );
    if (!context.mounted) return;
    final saved = await showAppAnchoredMenu<int>(
      anchorContext: context,
      width: 200,
      builder: (_) => picker,
    );
    if (saved != null && context.mounted) {
      final part = isIntro ? '片头' : '片尾';
      showAppToast(context, saved == 0 ? '已关闭跳过$part' : '已设置跳过$part $saved 秒');
    }
  }
}

class _SkipStatusButton extends StatelessWidget {
  const _SkipStatusButton({
    super.key,
    required this.label,
    required this.current,
    required this.onPressed,
  });

  final String label;
  final int current;
  final ValueChanged<BuildContext> onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 46,
    child: Builder(
      builder: (anchorContext) => OutlinedButton(
        onPressed: () => onPressed(anchorContext),
        style: OutlinedButton.styleFrom(
          foregroundColor: anchorContext.appColors.text,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: Text('$label · ')),
            Flexible(
              child: Text(
                current <= 0 ? '关闭' : '$current秒',
                style: TextStyle(
                  color: current <= 0
                      ? anchorContext.appColors.secondary
                      : anchorContext.appColors.accentForeground,
                  fontWeight: current <= 0 ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down, size: 18),
          ],
        ),
      ),
    ),
  );
}

class _SkipPicker extends StatefulWidget {
  const _SkipPicker({
    required this.isIntro,
    required this.current,
    required this.onSave,
  });

  final bool isIntro;
  final int current;
  final Future<void> Function(int seconds) onSave;

  @override
  State<_SkipPicker> createState() => _SkipPickerState();
}

class _SkipPickerState extends State<_SkipPicker> {
  bool custom = false;
  bool saving = false;
  late final TextEditingController editor = TextEditingController(
    text: widget.current > 0 && !isSkipPreset(widget.current)
        ? '${widget.current}'
        : '',
  );
  String? error;

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  Future<void> _save(int seconds) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await widget.onSave(seconds);
      if (mounted) Navigator.pop(context, seconds);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '保存失败，请重试';
        });
      }
    }
  }

  void _saveCustom() {
    final seconds = int.tryParse(editor.text.trim());
    if (seconds == null ||
        seconds < skipDurationMin ||
        seconds > skipDurationMax) {
      setState(() => error = '请输入 $skipDurationMin–$skipDurationMax 秒');
      return;
    }
    _save(seconds);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      16,
      12,
      16,
      12 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: custom ? _customEditor() : _presets(),
  );

  Widget _presets() {
    final title = widget.isIntro ? '跳过片头' : '跳过片尾';
    const customValue = -1;
    final selectedValue = widget.current > 0 && !isSkipPreset(widget.current)
        ? customValue
        : widget.current;
    return RadioGroup<int>(
      groupValue: selectedValue,
      onChanged: (value) {
        if (saving || value == null) return;
        if (value == customValue) {
          setState(() => custom = true);
        } else {
          _save(value);
        }
      },
      child: ListTileTheme(
        data: const ListTileThemeData(
          contentPadding: EdgeInsets.zero,
          horizontalTitleGap: 8,
          minLeadingWidth: 20,
          minVerticalPadding: 0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final seconds in [0, ...skipDurationPresets])
              RadioListTile<int>(
                key: ValueKey(
                  'skip-${widget.isIntro ? 'intro' : 'outro'}-$seconds',
                ),
                value: seconds,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(seconds == 0 ? '关闭' : '$seconds 秒'),
              ),
            RadioListTile<int>(
              key: ValueKey(
                'skip-${widget.isIntro ? 'intro' : 'outro'}-custom',
              ),
              value: customValue,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('自定义'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.isIntro ? '播放开始时自动跳过所选时长' : '剩余所选时长时自动结束或播放下一集',
                style: TextStyle(
                  color: context.appColors.secondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customEditor() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '自定义${widget.isIntro ? '片头' : '片尾'}时长',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: editor,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          hintText: '$skipDurationMin–$skipDurationMax',
          suffixText: '秒',
          errorText: error,
        ),
        onSubmitted: (_) => _saveCustom(),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          TextButton(
            onPressed: saving ? null : () => setState(() => custom = false),
            child: const Text('取消'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: saving ? null : _saveCustom,
            child: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    ],
  );
}
