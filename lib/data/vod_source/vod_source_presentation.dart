import '../../domain/vod_source.dart';
import '../../domain/vod_source_customization.dart';

String vodSourceDisplayName(
  VodSource source,
  VodSourceCustomizations? settings,
) {
  final alias = settings?.forSource(source.id).displayName ?? '';
  return alias.isEmpty ? source.name : alias;
}

class VodSourcePresentation {
  const VodSourcePresentation(
    this.source,
    this.customization, {
    required this.pinned,
    this.demoted = false,
  });

  final VodSource source;
  final VodSourceCustomization customization;
  final bool pinned;
  final bool demoted;

  String get name => customization.displayName.isEmpty
      ? source.name
      : customization.displayName;
  String get subtitle => customization.note.isNotEmpty
      ? customization.note
      : source.notification.isNotEmpty
      ? source.notification
      : source.baseUri.host;
}

List<VodSourcePresentation> presentVodSources(
  Iterable<VodSource> sources,
  VodSourceCustomizations settings, {
  VodContentTag? tag,
}) {
  final pins = {
    for (var i = 0; i < settings.pinnedSourceIds.length; i++)
      settings.pinnedSourceIds[i]: i,
  };
  final demoted = {
    for (var i = 0; i < settings.demotedSourceIds.length; i++)
      settings.demotedSourceIds[i]: i,
  };
  final sorted = sources
      .where(
        (source) =>
            tag == null || settings.forSource(source.id).tags.contains(tag),
      )
      .toList();
  sorted.sort((a, b) {
    final pinA = pins[a.id];
    final pinB = pins[b.id];
    if (pinA != null && pinB != null) return pinA.compareTo(pinB);
    if (pinA != null) return -1;
    if (pinB != null) return 1;
    final bottomA = demoted[a.id];
    final bottomB = demoted[b.id];
    if (bottomA != null && bottomB != null) return bottomA.compareTo(bottomB);
    if (bottomA != null) return 1;
    if (bottomB != null) return -1;
    final priority = a.priority.compareTo(b.priority);
    return priority != 0 ? priority : a.id.compareTo(b.id);
  });
  return [
    for (final source in sorted)
      VodSourcePresentation(
        source,
        settings.forSource(source.id),
        pinned: settings.isPinned(source.id),
        demoted: settings.isDemoted(source.id),
      ),
  ];
}
