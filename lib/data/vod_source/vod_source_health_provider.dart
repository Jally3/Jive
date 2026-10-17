import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/vod_source.dart';
import '../video_repository.dart';

const _healthKeyPrefix = 'source_health_';

class SourceHealth {
  SourceHealth({
    required this.ok,
    required this.latencyMs,
    required this.checkedAt,
    this.message,
  });

  factory SourceHealth.fromJson(Map<String, dynamic> json) => SourceHealth(
    ok: json['ok'] == true,
    latencyMs: json['latencyMs'] is int ? json['latencyMs'] as int : 0,
    checkedAt:
        DateTime.tryParse('${json['checkedAt'] ?? ''}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    message: json['message'] is String ? json['message'] as String : null,
  );

  final bool ok;
  final int latencyMs;
  final DateTime checkedAt;
  final String? message;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'latencyMs': latencyMs,
    'checkedAt': checkedAt.toIso8601String(),
    if (message != null) 'message': message,
  };
}

class SourceHealthState {
  SourceHealthState({
    Map<String, SourceHealth> results = const {},
    Set<String> checking = const {},
  }) : results = Map.unmodifiable(results),
       checking = Set.unmodifiable(checking);
  final Map<String, SourceHealth> results;
  final Set<String> checking;
}

final vodSourceHealthProvider =
    AsyncNotifierProvider<VodSourceHealthNotifier, SourceHealthState>(
      VodSourceHealthNotifier.new,
    );

final vodSourceHealthPreferencesProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

/// Shared by page and sheet; reading historical results never probes a source.
class VodSourceHealthNotifier extends AsyncNotifier<SourceHealthState> {
  @override
  Future<SourceHealthState> build() async {
    final prefs = await ref.watch(vodSourceHealthPreferencesProvider.future);
    final results = <String, SourceHealth>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_healthKeyPrefix)) continue;
      try {
        final raw = prefs.getString(key);
        if (raw == null) continue;
        results[key.substring(_healthKeyPrefix.length)] = SourceHealth.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        // One damaged record must not hide healthy neighbors.
      }
    }
    return SourceHealthState(results: results);
  }

  Future<void> check(VodSource source) async {
    await future;
    if (!ref.mounted || state.requireValue.checking.contains(source.id)) return;
    final current = state.requireValue;
    state = AsyncData(
      SourceHealthState(
        results: current.results,
        checking: {...current.checking, source.id},
      ),
    );
    final repository = ref.read(videoRepositoryProvider);
    final stopwatch = Stopwatch()..start();
    SourceHealth health;
    try {
      await repository.fetchPage(source).timeout(const Duration(seconds: 8));
      health = SourceHealth(
        ok: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
      );
    } catch (error) {
      health = SourceHealth(
        ok: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        checkedAt: DateTime.now(),
        message: '$error',
      );
    }
    var persisted = false;
    try {
      final prefs = await ref.read(vodSourceHealthPreferencesProvider.future);
      final saved = await prefs.setString(
        '$_healthKeyPrefix${source.id}',
        jsonEncode(health.toJson()),
      );
      if (!saved) throw StateError('Health persistence failed');
      persisted = true;
    } finally {
      if (ref.mounted) {
        final latest = state.requireValue;
        state = AsyncData(
          SourceHealthState(
            results: persisted
                ? {...latest.results, source.id: health}
                : latest.results,
            checking: {...latest.checking}..remove(source.id),
          ),
        );
      }
    }
  }

  Future<void> checkAll(Iterable<VodSource> sources) =>
      Future.wait(sources.map(check));
}
