import 'package:shared_preferences/shared_preferences.dart';

/// Persists the opaque backend-issued subject. This is intentionally isolated
/// so it can later be replaced by Keychain/Keystore without changing clients.
/// TODO(security): migrate this value to platform secure storage.
class AnonymousSubjectStore {
  AnonymousSubjectStore({SharedPreferences? preferences})
    : _preferences = preferences;

  static const _key = 'jive_anonymous_subject_v1';
  final SharedPreferences? _preferences;

  Future<String?> read() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final value = prefs.getString(_key)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> write(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) throw ArgumentError.value(value, 'value');
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.setString(_key, normalized);
  }

  Future<void> clear() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
