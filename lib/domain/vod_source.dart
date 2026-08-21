class VodSource {
  const VodSource({
    required this.id,
    required this.name,
    required this.baseUri,
    required this.adapterType,
    this.search = true,
    this.enabled = true,
    this.priority = 999,
    this.notification = '',
    this.featuredCategoryIds = const {},
    this.pluginConfigUri,
  });

  factory VodSource.fromJson(Map<String, dynamic> json) {
    final rawCategoryIds = json['featuredCategoryIds'];
    final rawPlugin =
        json['pluginConfigUri'] ?? json['pluginConfigUrl'] ?? json['plugin'];
    return VodSource(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['id'] ?? '未命名源'}',
      baseUri: Uri.parse('${json['baseUri'] ?? ''}'),
      adapterType: '${json['adapterType'] ?? 'mac_cms_v10'}',
      search: json['search'] != false,
      enabled: json['enabled'] != false,
      priority: json['priority'] is int
          ? json['priority'] as int
          : int.tryParse('${json['priority']}') ?? 999,
      notification: '${json['notification'] ?? ''}',
      featuredCategoryIds: rawCategoryIds is List
          ? rawCategoryIds
                .map((e) => int.tryParse('$e'))
                .whereType<int>()
                .toSet()
          : const {},
      pluginConfigUri: _tryUri(rawPlugin),
    );
  }

  final String id;
  final String name;
  final Uri baseUri;
  final String adapterType;
  final bool search;
  final bool enabled;
  final int priority;
  final String notification;
  final Set<int> featuredCategoryIds;
  final Uri? pluginConfigUri;

  bool get isHttps => baseUri.scheme == 'https';

  /// AGE resolver URLs and plugin `Player()` handles are not stable media.
  bool get disablesDownload =>
      adapterType == 'age_v2' || adapterType == 'syncnext_plugin';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUri': '$baseUri',
    'adapterType': adapterType,
    'search': search,
    'enabled': enabled,
    'priority': priority,
    if (notification.isNotEmpty) 'notification': notification,
    if (featuredCategoryIds.isNotEmpty)
      'featuredCategoryIds': featuredCategoryIds.toList()..sort(),
    if (pluginConfigUri != null) 'pluginConfigUri': '$pluginConfigUri',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VodSource && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'VodSource($id: $name)';
}

Uri? _tryUri(Object? raw) {
  final text = '$raw'.trim();
  if (text.isEmpty || text == 'null') return null;
  return Uri.tryParse(text);
}
