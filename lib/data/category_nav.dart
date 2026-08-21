import 'dart:async';

import '../domain/video.dart';

class CategoryNav {
  const CategoryNav({required this.roots, required this.children});

  final List<VideoCategory> roots;
  final Map<int, List<VideoCategory>> children;
}

/// Builds the two-level home category tree. [featuredIds] keeps only matching
/// roots when at least one featured root exists.
CategoryNav buildCategoryNav(
  List<VideoCategory> all, {
  Set<int> featuredIds = const {},
}) {
  final byId = {for (final item in all) item.id: item};
  bool isRoot(VideoCategory item) =>
      item.parentId == 0 || !byId.containsKey(item.parentId);
  var roots = all.where(isRoot).toList();
  final children = <int, List<VideoCategory>>{};
  for (final item in all) {
    if (!isRoot(item)) {
      children.putIfAbsent(item.parentId, () => []).add(item);
    }
  }
  if (featuredIds.isNotEmpty) {
    final filtered = roots
        .where((item) => featuredIds.contains(item.id))
        .toList();
    if (filtered.isNotEmpty) roots = filtered;
  }
  return CategoryNav(roots: roots, children: children);
}

/// Category ids that the home chips can query: childless roots and all leaves.
List<int> categoryIdsToProbe(CategoryNav nav) => [
  for (final root in nav.roots)
    if (!nav.children.containsKey(root.id)) root.id,
  for (final kids in nav.children.values)
    for (final child in kids) child.id,
];

/// Drops empty leaves and empty childless roots. A parent whose children are
/// all empty is also dropped, instead of falling back to querying the parent.
CategoryNav hideEmptyCategories(CategoryNav nav, Set<int> emptyIds) {
  if (emptyIds.isEmpty) return nav;
  final children = <int, List<VideoCategory>>{};
  for (final entry in nav.children.entries) {
    final kept = [
      for (final child in entry.value)
        if (!emptyIds.contains(child.id)) child,
    ];
    if (kept.isNotEmpty) children[entry.key] = kept;
  }
  final roots = [
    for (final root in nav.roots)
      if (children.containsKey(root.id) ||
          (!nav.children.containsKey(root.id) && !emptyIds.contains(root.id)))
        root,
  ];
  return CategoryNav(roots: roots, children: children);
}

/// Probes first pages in parallel. Empty lists are returned; failures/timeouts
/// keep the category so a flaky request does not hide a working tab.
Future<Set<int>> findEmptyCategoryIds({
  required Future<VideoPage> Function(int categoryId) fetchPage,
  required Iterable<int> ids,
  int concurrency = 8,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final pending = ids.toList();
  if (pending.isEmpty) return {};
  final empty = <int>{};
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next;
      next += 1;
      if (index >= pending.length) return;
      final id = pending[index];
      try {
        final page = await fetchPage(id).timeout(timeout);
        if (page.items.isEmpty) empty.add(id);
      } catch (_) {}
    }
  }

  final workers = concurrency.clamp(1, pending.length);
  await Future.wait(List.generate(workers, (_) => worker()));
  return empty;
}
