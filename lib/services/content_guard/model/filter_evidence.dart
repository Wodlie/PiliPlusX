/// What kind of input produced a piece of [FilterEvidence].
enum EvidenceKind { text, metadata, media, author, model, availability }

/// One redacted reason a decision was reached.
///
/// Evidence is what the user is shown and what is persisted with a violation
/// record, so it must never carry raw credentials: no cookie, no access key, no
/// API key, no signed media URL. [redactedExcerpt] is a shortened, masked
/// excerpt of the source text; [fingerprint]/[mediaId] reference media by
/// stable identity instead of by URL (plan-core §2.3, §6.2).
final class FilterEvidence {
  const FilterEvidence({
    required this.kind,
    required this.field,
    this.redactedExcerpt,
    this.fingerprint,
    this.mediaId,
  });

  final EvidenceKind kind;

  /// Which input field produced this evidence (for example `text`, `authorUid`,
  /// `avatar`). Stable machine value.
  final String field;

  /// Masked excerpt. Already redacted by the producing operator; core does not
  /// re-derive it and never stores the raw text here.
  final String? redactedExcerpt;

  /// Stable perceptual fingerprint for media evidence.
  final String? fingerprint;

  /// Platform media id for media evidence.
  final String? mediaId;

  /// Whether this evidence points at a media identity rather than text.
  bool get isMediaEvidence => kind == EvidenceKind.media;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FilterEvidence &&
          kind == other.kind &&
          field == other.field &&
          redactedExcerpt == other.redactedExcerpt &&
          fingerprint == other.fingerprint &&
          mediaId == other.mediaId;

  @override
  int get hashCode =>
      Object.hash(kind, field, redactedExcerpt, fingerprint, mediaId);

  @override
  String toString() =>
      'FilterEvidence(${kind.name}, field: $field, '
      'excerpt: ${redactedExcerpt == null ? 'none' : 'redacted'}, '
      'media: ${mediaId ?? fingerprint ?? 'none'})';
}
