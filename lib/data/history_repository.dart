import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/watch_record.dart';

class HistoryRepository {
  static const _key = 'watch_history_v1';
  Future<void> _writeQueue = Future<void>.value();
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

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
      _notify();
    });
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
  }

  Future<void> remove(String globalId) async {
    if (globalId.isEmpty) return;
    final operation = _writeQueue.then<void>((_) async {
      final records = await _readSnapshot();
      final before = records.length;
      records.removeWhere((item) => item.video.globalId == globalId);
      if (records.length == before) return;
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(records.map((item) => item.toJson()).toList()),
      );
      _notify();
    });
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
  }

  Future<void> clear() async {
    final operation = _writeQueue.then<void>((_) async {
      await (await SharedPreferences.getInstance()).remove(_key);
      _notify();
    });
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

class WatchHistoryController extends AsyncNotifier<List<WatchRecord>> {
  @override
  Future<List<WatchRecord>> build() async {
    final repository = ref.read(historyRepositoryProvider);
    var disposed = false;
    void onChange() {
      Future<void>.microtask(() {
        if (!disposed) ref.invalidateSelf();
      });
    }

    repository.addListener(onChange);
    ref.onDispose(() {
      disposed = true;
      repository.removeListener(onChange);
    });
    return repository.load();
  }

  Future<void> remove(String globalId) =>
      ref.read(historyRepositoryProvider).remove(globalId);

  Future<void> clear() => ref.read(historyRepositoryProvider).clear();
}

final watchHistoryProvider =
    AsyncNotifierProvider<WatchHistoryController, List<WatchRecord>>(
      WatchHistoryController.new,
    );

/// 电影进度达到该比例后不再出现在首页续播条。剧集不看此阈值。
const movieContinueWatchingMaxProgress = 2 / 3;

final _seriesCategory = RegExp(r'剧|电视|连续|动漫|综艺');
final _episodeName = RegExp(r'第\s*\d+\s*集');

/// 历史快照没有剧集列表，用分类名和集名判断电影。
/// 含「剧/电视/连续/动漫/综艺」或「第 N 集」视为剧；含「电影」或「正片」视为电影；
/// 无法判断时按剧处理，避免把连载内容误藏。
bool isMovieWatchRecord(WatchRecord record) {
  final category = record.video.category;
  if (_seriesCategory.hasMatch(category)) return false;
  if (category.contains('电影')) return true;
  final name = record.episodeName;
  if (_episodeName.hasMatch(name)) return false;
  if (name.contains('正片')) return true;
  return false;
}

bool _isHomeContinueWatchingCandidate(WatchRecord record) {
  if (isMovieWatchRecord(record)) {
    return record.positionMs > 0 &&
        !record.completed &&
        record.progress < movieContinueWatchingMaxProgress;
  }
  return record.positionMs > 0 || record.completed;
}

/// 首页续播条：按最近观看取第一条合格记录。
WatchRecord? homeContinueWatchingRecord(List<WatchRecord> records) {
  for (final record in records) {
    if (_isHomeContinueWatchingCandidate(record)) return record;
  }
  return null;
}
