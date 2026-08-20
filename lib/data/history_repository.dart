import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/watch_record.dart';

class HistoryRepository {
  static const _key = 'watch_history_v1';
  Future<void> _writeQueue = Future<void>.value();

  Future<List<WatchRecord>> load() async {
    // A page can start reloading immediately after the player route pops.
    // Wait for any save already queued by the player's pop/dispose callbacks
    // so callers never observe the previous progress snapshot.
    await _writeQueue;
    return _readSnapshot();
  }

  Future<List<WatchRecord>> _readSnapshot() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null || raw.isEmpty) return <WatchRecord>[];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final records = <WatchRecord>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          records.add(WatchRecord.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          // 单条损坏或未知版本的记录跳过，不拖垮整份历史。
        }
      }
      records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return records;
    } catch (_) {
      return <WatchRecord>[];
    }
  }

  Future<void> save(WatchRecord record) async {
    final operation = _writeQueue.then<void>((_) async {
      final records = await _readSnapshot();
      records.removeWhere(
        (item) => item.video.globalId == record.video.globalId,
      );
      records.insert(0, record);
      if (records.length > 50) records.removeRange(50, records.length);
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(records.map((item) => item.toJson()).toList()),
      );
    });
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
  }

  Future<void> clear() async {
    final operation = _writeQueue.then<void>(
      (_) async => (await SharedPreferences.getInstance()).remove(_key),
    );
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
  }
}

final historyRepositoryProvider = Provider<HistoryRepository>(
  (_) => HistoryRepository(),
);
