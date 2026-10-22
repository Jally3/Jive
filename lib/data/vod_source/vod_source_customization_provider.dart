import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/vod_source_customization.dart';
import 'vod_source_customization_store.dart';

final vodSourceCustomizationStoreProvider =
    Provider<VodSourceCustomizationStore>(
      (ref) => VodSourceCustomizationStore(),
    );

final vodSourceCustomizationsProvider =
    AsyncNotifierProvider<
      VodSourceCustomizationsNotifier,
      VodSourceCustomizations
    >(VodSourceCustomizationsNotifier.new);

class VodSourceCustomizationsNotifier
    extends AsyncNotifier<VodSourceCustomizations> {
  late VodSourceCustomizationStore _store;
  Future<void> _pending = Future.value();

  @override
  Future<VodSourceCustomizations> build() {
    _store = ref.watch(vodSourceCustomizationStoreProvider);
    return _store.load();
  }

  Future<void> save(String id, VodSourceCustomization value) =>
      _update((current) => current.update(id, value));
  Future<void> togglePinned(String id) =>
      _update((current) => current.togglePinned(id));
  Future<void> toggleDemoted(String id) =>
      _update((current) => current.toggleDemoted(id));
  Future<void> reset(String id) => _update((current) => current.reset(id));

  Future<void> _update(
    VodSourceCustomizations Function(VodSourceCustomizations) change,
  ) {
    final operation = _pending.then((_) async {
      final current = await future;
      final next = change(current);
      await _store.save(next);
      if (ref.mounted) state = AsyncData(next);
    });
    // Release the queue after a failure, while returning the error to its caller.
    _pending = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }
}
