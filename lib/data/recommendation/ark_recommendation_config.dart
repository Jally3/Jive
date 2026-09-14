class ArkRecommendationConfig {
  const ArkRecommendationConfig({
    required this.enabled,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  factory ArkRecommendationConfig.fromEnvironment() =>
      const ArkRecommendationConfig(
        enabled: bool.fromEnvironment(
          'ENABLE_DIRECT_LLM_RECOMMENDATION',
          defaultValue: false,
        ),
        apiKey: String.fromEnvironment('ARK_API_KEY'),
        baseUrl: String.fromEnvironment(
          'ARK_BASE_URL',
          defaultValue: 'https://ark.cn-beijing.volces.com/api/coding/v3',
        ),
        model: String.fromEnvironment(
          'ARK_MODEL',
          defaultValue: 'ark-code-latest',
        ),
      );

  final bool enabled;
  final String apiKey;
  final String baseUrl;
  final String model;

  bool get available =>
      enabled &&
      apiKey.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;
}
