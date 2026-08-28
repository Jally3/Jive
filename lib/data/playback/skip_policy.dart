import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按影片缓存跳过片头/片尾时长。未设置时默认关闭。
const skipPolicyStoreKey = 'skip_policy_by_video_v1';

/// 片头/片尾跳过预设（秒）。0 表示关闭。
const skipDurationPresets = [30, 60, 90];
const skipDurationMin = 1;
const skipDurationMax = 600;
const skipPolicyMaxEntries = 200;

class SkipPolicy {
  const SkipPolicy({this.introSeconds = 0, this.outroSeconds = 0});

  final int introSeconds;
  final int outroSeconds;

  bool get introEnabled => introSeconds > 0;
  bool get outroEnabled => outroSeconds > 0;
  bool get isOff => !introEnabled && !outroEnabled;

  Map<String, int> toJson() => {
    'introSeconds': introSeconds,
    'outroSeconds': outroSeconds,
  };

  factory SkipPolicy.fromJson(Object? raw) {
    if (raw is! Map) return const SkipPolicy();
    return SkipPolicy(
      introSeconds: clampSkipSeconds(_int(raw['introSeconds'])),
      outroSeconds: clampSkipSeconds(_int(raw['outroSeconds'])),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkipPolicy &&
          introSeconds == other.introSeconds &&
          outroSeconds == other.outroSeconds;

  @override
  int get hashCode => Object.hash(introSeconds, outroSeconds);
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

int clampSkipSeconds(int seconds) {
  if (seconds <= 0) return 0;
  if (seconds < skipDurationMin) return skipDurationMin;
  if (seconds > skipDurationMax) return skipDurationMax;
  return seconds;
}

bool isSkipPreset(int seconds) => skipDurationPresets.contains(seconds);

String skipDurationLabel(int seconds) {
  if (seconds <= 0) return '关闭';
  if (isSkipPreset(seconds)) return '$seconds 秒';
  return '自定义 · $seconds 秒';
}

/// 当前位置仍在片头窗口内，起播或续播时应跳到片头结束点。
bool shouldSkipIntro({
  required int introSeconds,
  required Duration position,
  required Duration duration,
}) {
  if (introSeconds <= 0 || duration <= Duration.zero) return false;
  final intro = Duration(seconds: introSeconds);
  if (duration <= intro) return false;
  return position < intro - const Duration(seconds: 1);
}

/// 片头判断用续播锚点，避免起播瞬间 native position 仍为 0 而误跳。
Duration skipIntroDecisionPosition({
  required Duration resumePosition,
  required Duration playerPosition,
}) => resumePosition > playerPosition ? resumePosition : playerPosition;

/// 剩余时长落入片尾窗口，应跳到片尾结束或下一集。
bool shouldSkipOutro({
  required int outroSeconds,
  required Duration position,
  required Duration duration,
}) {
  if (outroSeconds <= 0 || duration <= Duration.zero) return false;
  final outro = Duration(seconds: outroSeconds);
  if (duration <= outro) return false;
  final remaining = duration - position;
  return remaining <= outro && remaining > const Duration(seconds: 2);
}

abstract final class SkipPolicyStore {
  static Future<Map<String, dynamic>> _loadMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(skipPolicyStoreKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  static Future<SkipPolicy> load(String videoGlobalId) async {
    if (videoGlobalId.isEmpty) return const SkipPolicy();
    final map = await _loadMap();
    return SkipPolicy.fromJson(map[videoGlobalId]);
  }

  static Future<void> save(String videoGlobalId, SkipPolicy policy) async {
    if (videoGlobalId.isEmpty) return;
    final map = await _loadMap();
    map.remove(videoGlobalId);
    if (!policy.isOff) {
      map[videoGlobalId] = policy.toJson();
      while (map.length > skipPolicyMaxEntries) {
        map.remove(map.keys.first);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (map.isEmpty) {
      await prefs.remove(skipPolicyStoreKey);
    } else {
      await prefs.setString(skipPolicyStoreKey, jsonEncode(map));
    }
  }
}

final skipPolicyProvider =
    AsyncNotifierProvider.family<SkipPolicyNotifier, SkipPolicy, String>(
      SkipPolicyNotifier.new,
    );

class SkipPolicyNotifier extends AsyncNotifier<SkipPolicy> {
  SkipPolicyNotifier(this.videoGlobalId);

  final String videoGlobalId;

  @override
  Future<SkipPolicy> build() => SkipPolicyStore.load(videoGlobalId);

  Future<void> setIntroSeconds(int seconds) => _save(
    SkipPolicy(
      introSeconds: clampSkipSeconds(seconds),
      outroSeconds: (state.value ?? const SkipPolicy()).outroSeconds,
    ),
  );

  Future<void> setOutroSeconds(int seconds) => _save(
    SkipPolicy(
      introSeconds: (state.value ?? const SkipPolicy()).introSeconds,
      outroSeconds: clampSkipSeconds(seconds),
    ),
  );

  Future<void> _save(SkipPolicy policy) async {
    state = AsyncData(policy);
    await SkipPolicyStore.save(videoGlobalId, policy);
  }
}
