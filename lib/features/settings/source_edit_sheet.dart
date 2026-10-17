import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/vod_source/vod_source_customization_provider.dart';
import '../../domain/vod_source.dart';
import '../../domain/vod_source_customization.dart';

class SourceEditSheet extends ConsumerStatefulWidget {
  const SourceEditSheet({
    super.key,
    required this.source,
    required this.initial,
  });

  final VodSource source;
  final VodSourceCustomization initial;

  static Future<void> show(
    BuildContext context,
    VodSource source,
    VodSourceCustomization initial,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (_) => SourceEditSheet(source: source, initial: initial),
  );

  @override
  ConsumerState<SourceEditSheet> createState() => _SourceEditSheetState();
}

class _SourceEditSheetState extends ConsumerState<SourceEditSheet> {
  late final _name = TextEditingController(text: widget.initial.displayName);
  late final _note = TextEditingController(text: widget.initial.note);
  late final _tags = {...widget.initial.tags};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final route = ModalRoute.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(vodSourceCustomizationsProvider.notifier)
          .save(
            widget.source.id,
            VodSourceCustomization(
              displayName: _name.text,
              tags: _tags,
              note: _note.text,
            ),
          );
      if (mounted && route?.isCurrent == true) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，输入已保留，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '编辑来源',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.source.name} · 仅保存在本机',
              style: TextStyle(
                fontSize: 13,
                color: context.appColors.secondary,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('source-display-name'),
              controller: _name,
              enabled: !_saving,
              maxLength: 30,
              decoration: InputDecoration(
                labelText: '显示名（可选）',
                hintText: widget.source.name,
                helperText: '留空使用原名',
              ),
            ),
            const SizedBox(height: 12),
            const Text('我的内容标签', style: TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final tag in VodContentTag.values)
                  FilterChip(
                    label: Text(
                      tag.label,
                      style: TextStyle(
                        color: _tags.contains(tag)
                            ? context.appColors.onAccent
                            : context.appColors.secondary,
                      ),
                    ),
                    selected: _tags.contains(tag),
                    onSelected: _saving
                        ? null
                        : (selected) => setState(() {
                            if (selected) {
                              _tags.add(tag);
                            } else {
                              _tags.remove(tag);
                            }
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('source-note'),
              controller: _note,
              enabled: !_saving,
              maxLength: 80,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '私人备注（可选）',
                hintText: '例如：综艺全、更新快',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.appColors.error),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '保存中…' : '保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
