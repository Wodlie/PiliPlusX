import 'package:PiliPlus/services/content_guard/model/content_types.dart';

/// One media asset attached to a piece of content.
///
/// [type] is the media *role* (body image, avatar, video frame, ...), which is
/// what operators and rules scope on. [fingerprint] is the optional stable
/// perceptual identity produced by the image pipeline; it is the only identity
/// that survives URL rotation, so never use [url] as an author or content
/// identity (plan-core §12 risk 3).
final class MediaRef {
  const MediaRef({
    required this.id,
    required this.type,
    required this.url,
    this.width,
    this.height,
    this.fingerprint,
  });

  /// Platform media id (picture key, avatar seed, ...) inside its content.
  final String id;

  final MediaType type;

  /// Original media URL. It may be signed and may expire; treat it as a fetch
  /// address, not as an identity.
  final String url;

  final int? width;

  final int? height;

  /// Stable perceptual fingerprint, when the media pipeline has computed one.
  final String? fingerprint;

  /// Whether this reference carries an identity that survives URL rotation.
  bool get hasStableIdentity {
    final value = fingerprint;
    return value != null && value.isNotEmpty;
  }

  /// Cache/reference key: the fingerprint when present, the platform id
  /// otherwise. Never the URL.
  String get stableKey {
    final value = fingerprint;
    if (value != null && value.isNotEmpty) return 'fp:$value';
    return 'id:$id';
  }

  /// Returns a copy carrying [fingerprint]; used after the hash pipeline runs.
  MediaRef withFingerprint(String fingerprint) => MediaRef(
    id: id,
    type: type,
    url: url,
    width: width,
    height: height,
    fingerprint: fingerprint,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaRef &&
          id == other.id &&
          type == other.type &&
          url == other.url &&
          width == other.width &&
          height == other.height &&
          fingerprint == other.fingerprint;

  @override
  int get hashCode => Object.hash(id, type, url, width, height, fingerprint);

  /// Omits [url] on purpose: media URLs can carry signing parameters and must
  /// not be copied into logs or evidence by an incidental interpolation.
  @override
  String toString() =>
      'MediaRef(${type.name}, id: $id, $width x $height, '
      'fingerprint: ${hasStableIdentity ? 'present' : 'absent'})';
}
