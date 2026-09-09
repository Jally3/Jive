import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/library.dart';
import '../domain/video.dart';
import 'video_repository.dart';
import 'vod_source/vod_source_registry.dart';

class LibraryRepository {
  LibraryRepository({SharedPreferences? preferences})
    : _preferences = preferences;

  static const favoritesKey = 'favorite_videos_v1';
  static const libraryKey = 'content_library_v2';
  final SharedPreferences? _preferences;
  Future<void> _writeQueue = Future<void>.value();
  Future<SharedPreferences> get _prefs async =>
      _preferences ?? await SharedPreferences.getInstance();

  Future<List<FavoriteRecord>> loadFavorites() async {
    final prefs = await _prefs;
    final current = prefs.getString(libraryKey);
    if (current != null) {
      final decoded = _tryDecode(current, FavoriteRecord.tryFromJson);
      if (decoded != null) return decoded;
    }
    // Read-only migration: old favorites stay intact and are not followed.
    return _decode(prefs.getString(favoritesKey), FavoriteRecord.tryFromJson);
  }

  List<T>? _tryDecode<T>(String raw, T? Function(Object?) parser) {
    try {
      final value = jsonDecode(raw);
      return value is List ? value.map(parser).whereType<T>().toList() : null;
    } catch (_) {
      return null;
    }
  }

  List<T> _decode<T>(String? raw, T? Function(Object?) parser) {
    if (raw == null || raw.isEmpty) return [];
    return _tryDecode(raw, parser) ?? [];
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> saveAll(List<FavoriteRecord> records) =>
      _serialized(() => _save(records));

  Future<void> _save(List<FavoriteRecord> records) async {
    final value = records.map((item) => item.toJson()).toList();
    if (!await (await _prefs).setString(libraryKey, jsonEncode(value))) {
      throw StateError('本地保存失败');
    }
  }

  Future<void> saveFavorite(FavoriteRecord record) => _serialized(() async {
    final records = await loadFavorites();
    final index = records.indexWhere(
      (item) => item.video.globalId == record.video.globalId,
    );
    final snapshot = record.copyWith(
      video: _snapshot(record.video),
      createdAt: index < 0 ? record.createdAt : records[index].createdAt,
    );
    if (index < 0) {
      records.insert(0, snapshot);
    } else {
      records[index] = snapshot;
    }
    await _save(records);
  });

  Future<void> removeFavorite(String globalId) => _serialized(() async {
    final records = await loadFavorites()
      ..removeWhere((item) => item.video.globalId == globalId);
    await _save(records);
  });

  static Video _snapshot(Video video) =>
      video.copyWith(episodes: const [], playbackLines: const []);
}

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (_) => LibraryRepository(),
);

class FavoriteController extends AsyncNotifier<List<FavoriteRecord>> {
  static const automaticCheckInterval = Duration(minutes: 30);
  static const maximumChecksPerRun = 50;
  static const maximumConcurrentSources = 3;
  DateTime? _lastAutomaticCheck;
  bool _checking = false;

  @override
  Future<List<FavoriteRecord>> build() =>
      ref.watch(libraryRepositoryProvider).loadFavorites();

  Future<void> toggle(Video video) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final index = _indexOf(before, video.globalId);
    final next = [...before];
    final now = DateTime.now();
    if (index < 0) {
      next.insert(
        0,
        FavoriteRecord(video: _snapshot(video), createdAt: now, updatedAt: now),
      );
    } else {
      next.removeAt(index);
    }
    await _commit(before, next);
  }

  Future<void> follow(Video video) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final next = [...before];
    final index = _indexOf(next, video.globalId);
    final now = DateTime.now();
    final signature = episodeVersionSignature(video.episodes);
    final prior = index < 0
        ? FavoriteRecord(
            video: _snapshot(video),
            createdAt: now,
            updatedAt: now,
          )
        : next[index];
    final updated = prior.copyWith(
      video: _snapshot(video),
      updatedAt: now,
      isFavorite: true,
      isFollowing: true,
      followedAt: prior.followedAt ?? now,
      acknowledgedEpisodeSignature: signature,
      remoteEpisodeSignature: signature,
      viewedEpisodeSignature: signature,
      acknowledgedEpisodeCount: video.episodes.length,
      remoteEpisodeCount: video.episodes.length,
      latestEpisodeLabel: video.episodes.lastOrNull?.name ?? video.remarks,
      unreadAddedCount: 0,
      clearCheckError: true,
      sourceUnavailable: false,
    );
    if (index < 0) {
      next.insert(0, updated);
    } else {
      next[index] = updated;
    }
    await _commit(before, next);
  }

  Future<void> stopFollowing(
    String globalId, {
    required bool keepFavorite,
  }) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final next = [...before];
    final index = _indexOf(next, globalId);
    if (index < 0) return;
    if (!keepFavorite) {
      next.removeAt(index);
    } else {
      next[index] = next[index].copyWith(
        isFavorite: true,
        isFollowing: false,
        clearFollowedAt: true,
        unreadAddedCount: 0,
        updatedAt: DateTime.now(),
        clearCheckError: true,
        sourceUnavailable: false,
      );
    }
    await _commit(before, next);
  }

  Future<void> markViewed(String globalId) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final next = [...before];
    final index = _indexOf(next, globalId);
    if (index < 0 || !next[index].hasUnreadUpdate) return;
    final record = next[index];
    next[index] = record.copyWith(
      acknowledgedEpisodeSignature: record.remoteEpisodeSignature,
      acknowledgedEpisodeCount: record.remoteEpisodeCount,
      viewedEpisodeSignature: record.remoteEpisodeSignature,
      unreadAddedCount: 0,
      updatedAt: DateTime.now(),
    );
    await _commit(before, next);
  }

  Future<void> markAllViewed() async {
    final before = state.value ?? const <FavoriteRecord>[];
    if (!before.any((item) => item.hasUnreadUpdate)) return;
    final now = DateTime.now();
    final next = [
      for (final record in before)
        if (record.hasUnreadUpdate)
          record.copyWith(
            acknowledgedEpisodeSignature: record.remoteEpisodeSignature,
            acknowledgedEpisodeCount: record.remoteEpisodeCount,
            viewedEpisodeSignature: record.remoteEpisodeSignature,
            unreadAddedCount: 0,
            updatedAt: now,
          )
        else
          record,
    ];
    await _commit(before, next);
  }

  Future<void> refreshSnapshot(Video video) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final index = _indexOf(before, video.globalId);
    if (index < 0) return;
    final next = [...before]
      ..[index] = before[index].copyWith(
        video: _snapshot(video),
        updatedAt: DateTime.now(),
      );
    await _commit(before, next);
  }

  Future<void> checkForUpdates({bool force = false}) async {
    if (_checking) return;
    final now = DateTime.now();
    if (!force &&
        _lastAutomaticCheck != null &&
        now.difference(_lastAutomaticCheck!) < automaticCheckInterval) {
      return;
    }
    _checking = true;
    _lastAutomaticCheck = now;
    try {
      final records = state.value ?? await future;
      final followed = records
          .where((item) => item.isFollowing)
          .take(maximumChecksPerRun)
          .toList();
      if (followed.isEmpty) return;
      final registry = await ref.read(vodSourceRegistryProvider.future);
      final groups = <String, List<FavoriteRecord>>{};
      for (final record in followed) {
        groups.putIfAbsent(record.video.sourceId, () => []).add(record);
      }
      final pending = groups.entries.toList();
      var cursor = 0;
      Future<void> worker() async {
        while (cursor < pending.length) {
          final group = pending[cursor++];
          final source = registry.findById(group.key);
          if (source == null || !source.enabled) {
            for (final record in group.value) {
              await _recordCheckFailure(record.video.globalId, '原内容源不可用', true);
            }
            continue;
          }
          for (final record in group.value) {
            try {
              final remote = await ref
                  .read(videoRepositoryProvider)
                  .fetchDetail(source, record.video.ref, forceRefresh: true);
              await _recordCheckSuccess(record.video.globalId, remote);
            } catch (error) {
              await _recordCheckFailure(
                record.video.globalId,
                error.toString(),
                false,
              );
            }
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < maximumConcurrentSources && i < pending.length; i++)
          worker(),
      ]);
    } finally {
      _checking = false;
    }
  }

  Future<void> _recordCheckSuccess(String globalId, Video remote) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final index = _indexOf(before, globalId);
    if (index < 0 || !before[index].isFollowing) return;
    final record = before[index];
    if (remote.episodes.isEmpty && record.acknowledgedEpisodeCount > 0) {
      throw const VideoDataException('上游详情未返回剧集，保留上次检查结果');
    }
    final signature = episodeVersionSignature(remote.episodes);
    final hasBaseline =
        record.followedAt != null ||
        record.acknowledgedEpisodeSignature.isNotEmpty ||
        record.acknowledgedEpisodeCount > 0;
    final difference = remote.episodes.length - record.acknowledgedEpisodeCount;
    final added = hasBaseline && difference > 0 ? difference : 0;
    final acknowledgeRemote = !hasBaseline || added == 0;
    final next = [...before]
      ..[index] = record.copyWith(
        video: _snapshot(remote),
        updatedAt: DateTime.now(),
        lastCheckedAt: DateTime.now(),
        acknowledgedEpisodeSignature: acknowledgeRemote ? signature : null,
        // A temporary shortened upstream list must not lower the baseline and
        // trigger a false "+N episodes" reminder when the list recovers.
        acknowledgedEpisodeCount: acknowledgeRemote
            ? (remote.episodes.length > record.acknowledgedEpisodeCount
                  ? remote.episodes.length
                  : record.acknowledgedEpisodeCount)
            : null,
        remoteEpisodeSignature: signature,
        notifiedEpisodeSignature: added > 0
            ? signature
            : record.notifiedEpisodeSignature,
        remoteEpisodeCount: remote.episodes.length,
        latestEpisodeLabel: remote.episodes.lastOrNull?.name ?? remote.remarks,
        unreadAddedCount: added,
        clearCheckError: true,
        sourceUnavailable: false,
      );
    await _commit(before, next);
  }

  Future<void> _recordCheckFailure(
    String globalId,
    String message,
    bool sourceUnavailable,
  ) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final index = _indexOf(before, globalId);
    if (index < 0 || !before[index].isFollowing) return;
    final next = [...before]
      ..[index] = before[index].copyWith(
        lastCheckedAt: DateTime.now(),
        checkError: message,
        sourceUnavailable: sourceUnavailable,
      );
    await _commit(before, next);
  }

  Future<void> _commit(
    List<FavoriteRecord> before,
    List<FavoriteRecord> next,
  ) async {
    state = AsyncData(next);
    try {
      await ref.read(libraryRepositoryProvider).saveAll(next);
    } catch (error, stack) {
      state = AsyncData(before);
      Error.throwWithStackTrace(error, stack);
    }
  }

  static int _indexOf(List<FavoriteRecord> records, String globalId) =>
      records.indexWhere((item) => item.video.globalId == globalId);

  static Video _snapshot(Video video) =>
      video.copyWith(episodes: const [], playbackLines: const []);
}

final favoriteControllerProvider =
    AsyncNotifierProvider<FavoriteController, List<FavoriteRecord>>(
      FavoriteController.new,
    );

final unreadFollowUpdateCountProvider = Provider<int>((ref) {
  final records = ref.watch(favoriteControllerProvider).value ?? const [];
  return records.where((item) => item.hasUnreadUpdate).length;
});

final unreadFollowUpdatesByGlobalIdProvider = Provider<Map<String, int>>((ref) {
  final records = ref.watch(favoriteControllerProvider).value ?? const [];
  return {
    for (final record in records)
      if (record.hasUnreadUpdate)
        record.video.globalId: record.unreadAddedCount,
  };
});
