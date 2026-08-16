const Set<String> _defaultTimeLimitedQueryParams = {
  'sign',
  'signature',
  'token',
  't',
  'expires',
  'e',
  'timestamp',
  'ts',
  'sig',
};

class UrlNormalizer {
  const UrlNormalizer({Set<String>? timeLimitedQueryParams})
    : timeLimitedQueryParams =
          timeLimitedQueryParams ?? _defaultTimeLimitedQueryParams;

  /// 只删除来源明确的时效参数白名单字段，未知查询参数必须保留。
  final Set<String> timeLimitedQueryParams;

  Uri normalize(Uri url) {
    final params = url.queryParameters;
    if (params.isEmpty) {
      return Uri(scheme: url.scheme, host: url.host, path: url.path);
    }
    final kept = <String, String>{};
    params.forEach((key, value) {
      if (!timeLimitedQueryParams.contains(key.toLowerCase())) {
        kept[key] = value;
      }
    });
    return Uri(
      scheme: url.scheme,
      host: url.host,
      path: url.path,
      queryParameters: kept.isEmpty ? null : kept,
    );
  }

  String normalizeToString(Uri url) => normalize(url).toString();
}

const UrlNormalizer urlNormalizer = UrlNormalizer();
