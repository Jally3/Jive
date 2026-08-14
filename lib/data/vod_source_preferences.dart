import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/vod_source.dart';
import 'vod_source_registry.dart';

const _selectedSourceKey = 'selected_vod_source_id';

class SelectedVodSourceNotifier extends Notifier<AsyncValue<VodSource>> {
  /// 用户是否在持久化初始化完成前已主动选择，避免 _init 用旧值覆盖新选择。
  var _userSelected = false;

  @override
  AsyncValue<VodSource> build() {
    final registry = ref
        .watch(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (registry == null) return const AsyncValue.loading();
    _init(registry);
    return const AsyncValue.loading();
  }

  Future<void> _init(VodSourceRegistry registry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_selectedSourceKey);
      var source = savedId != null ? registry.findById(savedId) : null;
      if (source != null && !source.enabled) source = null;
      source ??= registry.defaultSource;
      if (_userSelected) return;
      if (source != null) {
        state = AsyncValue.data(source);
      } else {
        state = const AsyncValue.error('没有可用的来源', StackTrace.empty);
      }
    } catch (error, stack) {
      if (_userSelected) return;
      state = AsyncValue.error(error, stack);
    }
  }

  Future<void> select(VodSource source) async {
    final registry = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    final known = registry?.findById(source.id);
    if (known == null) {
      throw ArgumentError('内容源不在内置白名单中：${source.id}');
    }
    if (!known.enabled || !known.isHttps) {
      throw ArgumentError('只能选择已启用的 HTTPS 内容源');
    }
    _userSelected = true;
    state = AsyncValue.data(known);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedSourceKey, known.id);
  }
}

final selectedVodSourceProvider =
    NotifierProvider<SelectedVodSourceNotifier, AsyncValue<VodSource>>(
      SelectedVodSourceNotifier.new,
    );
