import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/watch_record.dart';
import 'download/download_task_manager.dart';

const int offlineProgressLimit = 100;

String offlineProgressKey({
  required String sourceId,
  required String sourceVideoId,
  required String playbackLineIdentity,
  required String episodeIdentity,
}) => '$sourceId|$sourceVideoId|$playbackLineIdentity|$episodeIdentity';

class OfflineEpisodeProgress {
  const OfflineEpisodeProgress({
    required this.key,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    required this.completed,
  });

  final String key;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  final bool completed;

  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
    'key': key,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toIso8601String(),
    'completed': completed,
  };

  factory OfflineEpisodeProgress.fromJson(Map<String, dynamic> json) {
    final duration = _int(json['durationMs']).clamp(0, 1 << 53);
    return OfflineEpisodeProgress(
      key: '${json['key'] ?? ''}',
      positionMs: _int(json['positionMs']).clamp(0, duration),
      durationMs: duration,
      updatedAt:
          DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime(1970),
      completed: json['completed'] == true,
    );
  }
}

class OfflineProgressRepository {
  static const _storageKey = 'offline_episode_progress_v1';
  Future<void> _writeQueue = Future.value();
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<List<OfflineEpisodeProgress>> load() async {
    await _writeQueue;
    return _read();
  }

  Future<List<OfflineEpisodeProgress>> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final byKey = <String, OfflineEpisodeProgress>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final progress = OfflineEpisodeProgress.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (progress.key.isEmpty) continue;
          final previous = byKey[progress.key];
          if (previous == null ||
              progress.updatedAt.isAfter(previous.updatedAt)) {
            byKey[progress.key] = progress;
          }
        } catch (_) {}
      }
      final records = byKey.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return records.take(offlineProgressLimit).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWatchRecord(WatchRecord record) async {
    if (record.playbackLineIdentity.isEmpty || record.episodeIdentity.isEmpty) {
      return;
    }
    final progress = OfflineEpisodeProgress(
      key: offlineProgressKey(
        sourceId: record.video.sourceId,
        sourceVideoId: record.video.sourceVideoId,
        playbackLineIdentity: record.playbackLineIdentity,
        episodeIdentity: record.episodeIdentity,
      ),
      positionMs: record.positionMs,
      durationMs: record.durationMs,
      updatedAt: record.updatedAt,
      completed: record.completed,
    );
    final operation = _writeQueue.then<void>((_) async {
      final records = await _read();
      records.removeWhere((item) => item.key == progress.key);
      records.insert(0, progress);
      if (records.length > offlineProgressLimit) {
        records.removeRange(offlineProgressLimit, records.length);
      }
      await (await SharedPreferences.getInstance()).setString(
        _storageKey,
        jsonEncode(records.map((item) => item.toJson()).toList()),
      );
      for (final listener in List<void Function()>.of(_listeners)) {
        listener();
      }
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

  Future<void> removeTask(DownloadTask task) async {
    final key = offlineProgressKeyForTask(task);
    final operation = _writeQueue.then<void>((_) async {
      final records = await _read();
      final before = records.length;
      records.removeWhere((item) => item.key == key);
      if (records.length == before) return;
      await (await SharedPreferences.getInstance()).setString(
        _storageKey,
        jsonEncode(records.map((item) => item.toJson()).toList()),
      );
      for (final listener in List<void Function()>.of(_listeners)) {
        listener();
      }
    });
    _writeQueue = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

final offlineProgressRepositoryProvider = Provider<OfflineProgressRepository>(
  (_) => OfflineProgressRepository(),
);

final offlineProgressProvider =
    FutureProvider<Map<String, OfflineEpisodeProgress>>((ref) async {
      final repository = ref.read(offlineProgressRepositoryProvider);
      void changed() => ref.invalidateSelf();
      repository.addListener(changed);
      ref.onDispose(() => repository.removeListener(changed));
      final records = await repository.load();
      return {for (final record in records) record.key: record};
    });

String offlineProgressKeyForTask(DownloadTask task) => offlineProgressKey(
  sourceId: task.sourceId,
  sourceVideoId: task.sourceVideoId,
  playbackLineIdentity: task.playbackLineIdentity,
  episodeIdentity: task.episodeIdentity,
);
