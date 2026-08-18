import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'cache_index.dart';
import 'cache_manager.dart';
import 'cache_ttl_policy.dart';
import 'platform_disk_space.dart';

final cacheRootDirectoryProvider = FutureProvider<Directory>((ref) async {
  // Explicit downloads must survive app restarts and must not be constrained
  // by Android's temporary-cache quota (often exposed as ~2.5 GB).
  final base = await getApplicationSupportDirectory();
  final persistent = Directory('${base.path}/jive_cache');
  final legacy = Directory(
    '${(await getTemporaryDirectory()).path}/jive_cache',
  );
  if (!await persistent.exists() && await legacy.exists()) {
    try {
      await legacy.rename(persistent.path);
    } catch (_) {
      // A failed migration is non-fatal; the new directory will be created
      // and future downloads will use persistent storage.
    }
  }
  return persistent;
});

final diskSpaceProvider = Provider<DiskSpaceProvider>(
  (_) => PlatformDiskSpaceProvider(),
);

final cacheManagerProvider = FutureProvider<CacheManager>((ref) async {
  final root = await ref.watch(cacheRootDirectoryProvider.future);
  final ttl = await ref.read(cacheTtlProvider.future);
  final manager = CacheManager(
    store: CacheIndexStore(root),
    diskSpace: ref.watch(diskSpaceProvider),
    maxAge: ttl.maxAge,
  );
  await manager.initialize();
  ref.listen(cacheTtlProvider, (_, next) {
    final option = next.value;
    if (option != null) manager.setMaxAge(option.maxAge);
  });
  ref.onDispose(() {
    unawaited(manager.flush());
  });
  return manager;
});
