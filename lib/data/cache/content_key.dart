import 'dart:convert';
import 'package:crypto/crypto.dart';

const int contentKeyVersion = 1;

class ContentKeyParts {
  const ContentKeyParts({
    required this.sourceId,
    required this.sourceVideoId,
    required this.playbackLineIdentity,
    required this.episodeIdentity,
  });

  final String sourceId;
  final String sourceVideoId;
  final String playbackLineIdentity;
  final String episodeIdentity;

  String encode() {
    final buffer = StringBuffer();
    buffer
      ..write(_field(sourceId))
      ..write(_field(sourceVideoId))
      ..write(_field(playbackLineIdentity))
      ..write(_field(episodeIdentity));
    return buffer.toString();
  }

  static String _field(String value) {
    final bytes = utf8.encode(value);
    return '${bytes.length.toString().padLeft(8, '0')}:$value';
  }
}

class ContentKey {
  const ContentKey._({
    required this.version,
    required this.parts,
    required this.hash,
  });

  final int version;
  final ContentKeyParts parts;
  final String hash;

  static ContentKey build(ContentKeyParts parts) {
    final digest = sha256.convert(utf8.encode(parts.encode()));
    return ContentKey._(
      version: contentKeyVersion,
      parts: parts,
      hash: 'sha256:$digest',
    );
  }
}

final contentKeyBuilderProvider = ContentKeyBuilder();

class ContentKeyBuilder {
  const ContentKeyBuilder();

  ContentKey build(ContentKeyParts parts) => ContentKey.build(parts);
}
