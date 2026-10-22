import 'dart:convert';
import 'dart:io';

const String downloadTaskFileName = 'download_tasks.json';

/// Reads the cache entries referenced by persisted download tasks.
///
/// This deliberately parses only the two cache identity fields so a newer
/// task schema cannot make an older offline download eligible for cleanup.
Future<Set<String>> loadProtectedDownloadEntryKeys(Directory root) async {
  try {
    final file = File('${root.path}/$downloadTaskFileName');
    if (!await file.exists()) return const <String>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['tasks'] is! List) {
      return const <String>{};
    }
    final keys = <String>{};
    for (final item in decoded['tasks'] as List) {
      if (item is! Map) continue;
      final contentKeyHash = '${item['contentKeyHash'] ?? ''}';
      final revisionKeyHash = '${item['revisionKeyHash'] ?? ''}';
      if (contentKeyHash.isEmpty || revisionKeyHash.isEmpty) continue;
      keys.add('$contentKeyHash|$revisionKeyHash');
    }
    return keys;
  } catch (_) {
    // Failure to read the task index must never make known downloads less
    // protected through a partial parse. Cache state protection remains active.
    return const <String>{};
  }
}
