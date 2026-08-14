class VodSource {
  const VodSource({
    required this.id,
    required this.name,
    required this.baseUri,
    required this.adapterType,
    this.search = true,
    this.enabled = true,
    this.priority = 999,
    this.featuredCategoryIds = const {},
  });

  factory VodSource.fromJson(Map<String, dynamic> json) {
    final rawCategoryIds = json['featuredCategoryIds'];
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
      featuredCategoryIds: rawCategoryIds is List
          ? rawCategoryIds
                .map((e) => int.tryParse('$e'))
                .whereType<int>()
                .toSet()
          : const {},
    );
  }

  final String id;
  final String name;
  final Uri baseUri;
  final String adapterType;
  final bool search;
  final bool enabled;
  final int priority;
  final Set<int> featuredCategoryIds;

  bool get isHttps => baseUri.scheme == 'https';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUri': '$baseUri',
    'adapterType': adapterType,
    'search': search,
    'enabled': enabled,
    'priority': priority,
    if (featuredCategoryIds.isNotEmpty)
      'featuredCategoryIds': featuredCategoryIds.toList()..sort(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VodSource && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'VodSource($id: $name)';
}
