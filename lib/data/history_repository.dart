import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/watch_record.dart';

class HistoryRepository {
  static const _key = 'watch_history_v1';
  Future<void> _writeQueue = Future<void>.value();

  Future<List<WatchRecord>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null || raw.isEmpty) return <WatchRecord>[];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final records = decoded
          .whereType<Map<String, dynamic>>()
          .map(WatchRecord.fromJson)
          .toList();
      records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return records;
    } catch (_) {
      return <WatchRecord>[];
    }
  }

  Future<void> save(WatchRecord record) async {
    _writeQueue = _writeQueue.then((_) async {
      final records = await load();
      records.removeWhere((item) => item.video.id == record.video.id);
      records.insert(0, record);
      if (records.length > 50) records.removeRange(50, records.length);
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(records.map((item) => item.toJson()).toList()),
      );
    });
    await _writeQueue;
  }

  Future<void> clear() async {
    _writeQueue = _writeQueue.then(
      (_) async => (await SharedPreferences.getInstance()).remove(_key),
    );
    await _writeQueue;
  }
}

final historyRepositoryProvider = Provider<HistoryRepository>(
  (_) => HistoryRepository(),
);
