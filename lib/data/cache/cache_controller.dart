import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'cache_index.dart';
import 'cache_manager.dart';
import 'cache_providers.dart';
import 'cache_repository.dart';

class CacheController extends AsyncNotifier<CacheStats> {
  CacheRepository? _repo;

  Future<CacheRepository> _repository() async {
    final cached = _repo;
    if (cached != null) return cached;
    final manager = await ref.watch(cacheManagerProvider.future);
    final repo = CacheRepository(manager);
    _repo = repo;
    return repo;
  }

  @override
  Future<CacheStats> build() async {
    final repo = await _repository();
    await repo.refreshQuota();
    return repo.stats();
  }

  Future<void> refresh() async => ref.invalidateSelf();

  Future<ClearAllResult> clearAll() async {
    final repo = await _repository();
    final result = await repo.clearAll();
    state = AsyncData(await repo.stats());
    return result;
  }

  Future<DeleteResult> deleteEntry(String entryKey) async {
    final repo = await _repository();
    final result = await repo.deleteEntry(entryKey);
    state = AsyncData(await repo.stats());
    return result;
  }
}

final cacheControllerProvider =
    AsyncNotifierProvider<CacheController, CacheStats>(CacheController.new);
