import 'cache_index.dart';
import 'cache_manager.dart';

class CacheRepository {
  CacheRepository(this._manager);

  final CacheManager _manager;

  Future<CacheStats> stats() => _manager.stats();

  Future<void> refreshQuota() => _manager.refreshQuota();

  Future<DeleteResult> deleteEntry(String entryKey) =>
      _manager.deleteEntry(entryKey);

  Future<ClearAllResult> clearAll() => _manager.clearAll();
}
