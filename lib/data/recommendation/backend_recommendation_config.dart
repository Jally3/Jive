class BackendRecommendationConfig {
  const BackendRecommendationConfig({
    this.baseUrl = 'https://hey-rickytse.com',
    this.timeout = const Duration(seconds: 28),
  });

  factory BackendRecommendationConfig.fromEnvironment() =>
      const BackendRecommendationConfig(
        baseUrl: String.fromEnvironment(
          'JIVE_API_BASE_URL',
          defaultValue: 'https://hey-rickytse.com',
        ),
      );

  final String baseUrl;
  final Duration timeout;

  Uri get baseUri {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Jive API Base URL 配置无效');
    }
    return uri;
  }
}
