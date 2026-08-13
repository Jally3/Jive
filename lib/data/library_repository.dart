import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/library.dart';
import '../domain/video.dart';

class LibraryRepository {
  LibraryRepository({SharedPreferences? preferences})
    : _preferences = preferences;
  static const favoritesKey = 'favorite_videos_v1';
  final SharedPreferences? _preferences;
  Future<void> _writeQueue = Future<void>.value();
  Future<SharedPreferences> get _prefs async =>
      _preferences ?? await SharedPreferences.getInstance();

  Future<List<FavoriteRecord>> loadFavorites() async => _decode(
    (await _prefs).getString(favoritesKey),
    FavoriteRecord.tryFromJson,
  );
  List<T> _decode<T>(String? raw, T? Function(Object?) parser) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final value = jsonDecode(raw);
      return value is List ? value.map(parser).whereType<T>().toList() : [];
    } catch (_) {
      return [];
    }
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

  Future<void> _save(String key, List<Map<String, dynamic>> value) async {
    if (!await (await _prefs).setString(key, jsonEncode(value))) {
      throw StateError('本地保存失败');
    }
  }

  Future<void> saveFavorite(FavoriteRecord record) => _serialized(() async {
    final records = await loadFavorites();
    final index = records.indexWhere(
      (item) => item.video.id == record.video.id,
    );
    final snapshot = FavoriteRecord(
      video: record.video.copyWith(episodes: const []),
      createdAt: index < 0 ? record.createdAt : records[index].createdAt,
      updatedAt: record.updatedAt,
    );
    if (index < 0) {
      records.insert(0, snapshot);
    } else {
      records[index] = snapshot;
    }
    await _save(favoritesKey, records.map((item) => item.toJson()).toList());
  });
  Future<void> removeFavorite(String videoId) => _serialized(() async {
    final records = await loadFavorites()
      ..removeWhere((item) => item.video.id == videoId);
    await _save(favoritesKey, records.map((item) => item.toJson()).toList());
  });
}

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (_) => LibraryRepository(),
);

class FavoriteController extends AsyncNotifier<List<FavoriteRecord>> {
  @override
  Future<List<FavoriteRecord>> build() =>
      ref.watch(libraryRepositoryProvider).loadFavorites();
  Future<void> toggle(Video video) async {
    final before = state.value ?? const <FavoriteRecord>[];
    final index = before.indexWhere((item) => item.video.id == video.id);
    final next = [...before];
    final now = DateTime.now();
    if (index < 0) {
      next.insert(
        0,
        FavoriteRecord(
          video: video.copyWith(episodes: const []),
          createdAt: now,
          updatedAt: now,
        ),
      );
    } else {
      next.removeAt(index);
    }
    state = AsyncData(next);
    try {
      if (index < 0) {
        await ref.read(libraryRepositoryProvider).saveFavorite(next.first);
      } else {
        await ref.read(libraryRepositoryProvider).removeFavorite(video.id);
      }
    } catch (error, stack) {
      state = AsyncData(before);
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> refreshSnapshot(Video video) async {
    final records = state.value ?? const <FavoriteRecord>[];
    final index = records.indexWhere((item) => item.video.id == video.id);
    if (index < 0) return;
    final updated = FavoriteRecord(
      video: video.copyWith(episodes: const []),
      createdAt: records[index].createdAt,
      updatedAt: DateTime.now(),
    );
    await ref.read(libraryRepositoryProvider).saveFavorite(updated);
    state = AsyncData([...records]..[index] = updated);
  }
}

final favoriteControllerProvider =
    AsyncNotifierProvider<FavoriteController, List<FavoriteRecord>>(
      FavoriteController.new,
    );
