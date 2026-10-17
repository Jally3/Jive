import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/vod_source_customization.dart';

class VodSourceCustomizationStore {
  VodSourceCustomizationStore({SharedPreferences? preferences})
    : _preferences = preferences;

  static const storageKey = 'vod_source_customizations_v1';
  final SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ?? await SharedPreferences.getInstance();

  Future<VodSourceCustomizations> load() async {
    final prefs = await _prefs;
    try {
      final raw = prefs.getString(storageKey);
      if (raw == null) return VodSourceCustomizations();
      final json = jsonDecode(raw);
      return json is Map<String, dynamic>
          ? VodSourceCustomizations.fromJson(json)
          : VodSourceCustomizations();
    } on FormatException {
      return VodSourceCustomizations();
    } on TypeError {
      return VodSourceCustomizations();
    }
  }

  Future<void> save(VodSourceCustomizations value) async {
    final ok = await (await _prefs).setString(
      storageKey,
      jsonEncode(value.toJson()),
    );
    if (!ok) throw StateError('来源设置保存失败，请重试');
  }
}
