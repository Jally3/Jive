import 'package:characters/characters.dart';

enum VodContentTag {
  movie('电影'),
  series('剧集'),
  animation('动漫'),
  variety('综艺');

  const VodContentTag(this.label);
  final String label;
}

/// Private annotations, independent of remote connection configuration.
class VodSourceCustomization {
  VodSourceCustomization({
    String displayName = '',
    Set<VodContentTag> tags = const {},
    String note = '',
  }) : displayName = _bounded(displayName, 30),
       tags = Set.unmodifiable(tags),
       note = _bounded(note, 80);

  factory VodSourceCustomization.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    return VodSourceCustomization(
      displayName: json['displayName'] is String
          ? json['displayName'] as String
          : '',
      note: json['note'] is String ? json['note'] as String : '',
      tags: {
        for (final tag in VodContentTag.values)
          if (rawTags is List && rawTags.contains(tag.name)) tag,
      },
    );
  }

  final String displayName;
  final Set<VodContentTag> tags;
  final String note;

  bool get isEmpty => displayName.isEmpty && tags.isEmpty && note.isEmpty;

  Map<String, dynamic> toJson() => {
    if (displayName.isNotEmpty) 'displayName': displayName,
    if (tags.isNotEmpty)
      'tags': [
        for (final tag in VodContentTag.values)
          if (tags.contains(tag)) tag.name,
      ],
    if (note.isNotEmpty) 'note': note,
  };
}

class VodSourceCustomizations {
  VodSourceCustomizations({
    Map<String, VodSourceCustomization> sources = const {},
    List<String> pinnedSourceIds = const [],
    List<String> demotedSourceIds = const [],
  }) : sources = Map.unmodifiable(sources),
       pinnedSourceIds = List.unmodifiable(
         pinnedSourceIds.where((id) => id.isNotEmpty).toSet(),
       ),
       demotedSourceIds = List.unmodifiable(
         demotedSourceIds
             .where((id) => id.isNotEmpty && !pinnedSourceIds.contains(id))
             .toSet(),
       );

  factory VodSourceCustomizations.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) return VodSourceCustomizations();
    final rawSources = json['sources'];
    final rawPins = json['pinnedSourceIds'];
    final rawDemoted = json['demotedSourceIds'];
    return VodSourceCustomizations(
      sources: {
        if (rawSources is Map)
          for (final entry in rawSources.entries)
            if (entry.key is String &&
                (entry.key as String).isNotEmpty &&
                entry.value is Map<String, dynamic>)
              entry.key as String: VodSourceCustomization.fromJson(
                entry.value as Map<String, dynamic>,
              ),
      },
      pinnedSourceIds: rawPins is List
          ? rawPins.whereType<String>().toList()
          : const [],
      demotedSourceIds: rawDemoted is List
          ? rawDemoted.whereType<String>().toList()
          : const [],
    );
  }

  final Map<String, VodSourceCustomization> sources;
  final List<String> pinnedSourceIds;
  final List<String> demotedSourceIds;

  VodSourceCustomization forSource(String id) =>
      sources[id] ?? VodSourceCustomization();
  bool isPinned(String id) => pinnedSourceIds.contains(id);
  bool isDemoted(String id) => demotedSourceIds.contains(id);

  VodSourceCustomizations update(String id, VodSourceCustomization value) {
    final next = {...sources};
    if (value.isEmpty) {
      next.remove(id);
    } else {
      next[id] = value;
    }
    return VodSourceCustomizations(
      sources: next,
      pinnedSourceIds: pinnedSourceIds,
      demotedSourceIds: demotedSourceIds,
    );
  }

  VodSourceCustomizations togglePinned(String id) => VodSourceCustomizations(
    sources: sources,
    pinnedSourceIds: isPinned(id)
        ? pinnedSourceIds.where((value) => value != id).toList()
        : [id, ...pinnedSourceIds],
    demotedSourceIds: demotedSourceIds,
  );

  VodSourceCustomizations reset(String id) => VodSourceCustomizations(
    sources: {...sources}..remove(id),
    pinnedSourceIds: pinnedSourceIds.where((value) => value != id).toList(),
    demotedSourceIds: demotedSourceIds.where((value) => value != id).toList(),
  );

  VodSourceCustomizations toggleDemoted(String id) => VodSourceCustomizations(
    sources: sources,
    pinnedSourceIds: pinnedSourceIds.where((value) => value != id).toList(),
    demotedSourceIds: isDemoted(id)
        ? demotedSourceIds.where((value) => value != id).toList()
        : [...demotedSourceIds, id],
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'sources': {
      for (final entry in sources.entries) entry.key: entry.value.toJson(),
    },
    'pinnedSourceIds': pinnedSourceIds,
    'demotedSourceIds': demotedSourceIds,
  };
}

String _bounded(String text, int limit) =>
    text.trim().characters.take(limit).toString();
