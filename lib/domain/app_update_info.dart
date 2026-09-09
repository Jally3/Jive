class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.apkUrl,
    required this.updatePromptEnabled,
    this.releaseNotes = const [],
  });

  final String versionName;
  final Uri apkUrl;
  final bool updatePromptEnabled;
  final List<String> releaseNotes;

  static AppUpdateInfo? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final versionName =
        '${json['latestVersionName'] ?? json['versionName'] ?? ''}'.trim();
    final apkUrl = Uri.tryParse('${json['apkUrl'] ?? ''}'.trim());
    if (_parseVersion(versionName) == null ||
        apkUrl == null ||
        apkUrl.scheme != 'https' ||
        apkUrl.host.isEmpty) {
      return null;
    }

    final rawNotes = json['releaseNotes'];
    final updatePromptEnabled = json['updatePromptEnabled'] is bool
        ? json['updatePromptEnabled'] as bool
        : true;
    final releaseNotes = rawNotes is List
        ? rawNotes
              .whereType<String>()
              .map((note) => note.trim())
              .where((note) => note.isNotEmpty)
              .take(8)
              .toList(growable: false)
        : const <String>[];
    return AppUpdateInfo(
      versionName: versionName,
      apkUrl: apkUrl,
      updatePromptEnabled: updatePromptEnabled,
      releaseNotes: releaseNotes,
    );
  }
}

/// Compares dotted semantic-style version names without considering the APK
/// build number. Returns null when either value is not a valid version name.
int? compareVersionNames(String left, String right) {
  final parsedLeft = _parseVersion(left);
  final parsedRight = _parseVersion(right);
  if (parsedLeft == null || parsedRight == null) return null;

  final coreLength = parsedLeft.core.length > parsedRight.core.length
      ? parsedLeft.core.length
      : parsedRight.core.length;
  for (var index = 0; index < coreLength; index++) {
    final leftPart = index < parsedLeft.core.length
        ? parsedLeft.core[index]
        : BigInt.zero;
    final rightPart = index < parsedRight.core.length
        ? parsedRight.core[index]
        : BigInt.zero;
    final comparison = leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison.sign;
  }

  final leftPre = parsedLeft.preRelease;
  final rightPre = parsedRight.preRelease;
  if (leftPre.isEmpty && rightPre.isEmpty) return 0;
  if (leftPre.isEmpty) return 1;
  if (rightPre.isEmpty) return -1;
  final preLength = leftPre.length < rightPre.length
      ? leftPre.length
      : rightPre.length;
  for (var index = 0; index < preLength; index++) {
    final leftPart = leftPre[index];
    final rightPart = rightPre[index];
    final leftNumber = BigInt.tryParse(leftPart);
    final rightNumber = BigInt.tryParse(rightPart);
    if (leftNumber != null && rightNumber != null) {
      final comparison = leftNumber.compareTo(rightNumber);
      if (comparison != 0) return comparison.sign;
    } else if (leftNumber != null) {
      return -1;
    } else if (rightNumber != null) {
      return 1;
    } else {
      final comparison = leftPart.compareTo(rightPart);
      if (comparison != 0) return comparison.sign;
    }
  }
  return leftPre.length.compareTo(rightPre.length).sign;
}

_ParsedVersion? _parseVersion(String value) {
  var normalized = value.trim();
  if (normalized.startsWith('v') || normalized.startsWith('V')) {
    normalized = normalized.substring(1);
  }
  normalized = normalized.split('+').first;
  final dash = normalized.indexOf('-');
  final coreText = dash < 0 ? normalized : normalized.substring(0, dash);
  final preText = dash < 0 ? '' : normalized.substring(dash + 1);
  final coreParts = coreText.split('.');
  if (coreParts.isEmpty ||
      coreParts.any((part) => !RegExp(r'^\d+$').hasMatch(part))) {
    return null;
  }
  final preParts = preText.isEmpty ? const <String>[] : preText.split('.');
  if (dash >= 0 &&
      (preParts.isEmpty ||
          preParts.any((part) => !RegExp(r'^[0-9A-Za-z-]+$').hasMatch(part)))) {
    return null;
  }
  return _ParsedVersion(
    core: coreParts.map(BigInt.parse).toList(growable: false),
    preRelease: preParts,
  );
}

class _ParsedVersion {
  const _ParsedVersion({required this.core, required this.preRelease});

  final List<BigInt> core;
  final List<String> preRelease;
}
