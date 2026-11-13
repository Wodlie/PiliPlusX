/// Structural position of a piece of content.
///
/// Everything here is context the *caller* already knows (controller, bridge,
/// transport); it is never inferred from model output. All fields are optional
/// because no single surface populates all of them.
final class ContentContext {
  const ContentContext({
    this.videoId,
    this.threadId,
    this.parentContentId,
    this.replyType,
    this.sortKey,
    this.occurrenceKey,
  });

  /// Context for content that carries no structural information.
  static const ContentContext empty = ContentContext();

  /// Video (or dynamic/article subject) the content belongs to.
  final String? videoId;

  /// Comment thread / conversation the content belongs to. Root and nested
  /// replies live in different threads and must never merge into one scope.
  final String? threadId;

  /// Parent content id for a nested reply.
  ///
  /// Supplied by the bridge context, never guessed from a PB field whose name
  /// is still unverified (plan-core §0, §2.1).
  final String? parentContentId;

  /// Platform reply type discriminator (root / nested) when available.
  final int? replyType;

  /// Sort or ordering key in force when the content was listed. A sort change
  /// opens a new scope and must not reuse decisions from the previous one.
  final String? sortKey;

  /// Occurrence of this content inside the current list revision. Distinct
  /// occurrences of one content id keep independent presenter state.
  final String? occurrenceKey;

  /// Whether no structural information is present.
  bool get isEmpty =>
      videoId == null &&
      threadId == null &&
      parentContentId == null &&
      replyType == null &&
      sortKey == null &&
      occurrenceKey == null;

  /// Copies this context, keeping every field whose argument is `null`.
  ContentContext copyWith({
    String? videoId,
    String? threadId,
    String? parentContentId,
    int? replyType,
    String? sortKey,
    String? occurrenceKey,
  }) => ContentContext(
    videoId: videoId ?? this.videoId,
    threadId: threadId ?? this.threadId,
    parentContentId: parentContentId ?? this.parentContentId,
    replyType: replyType ?? this.replyType,
    sortKey: sortKey ?? this.sortKey,
    occurrenceKey: occurrenceKey ?? this.occurrenceKey,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContentContext &&
          videoId == other.videoId &&
          threadId == other.threadId &&
          parentContentId == other.parentContentId &&
          replyType == other.replyType &&
          sortKey == other.sortKey &&
          occurrenceKey == other.occurrenceKey;

  @override
  int get hashCode => Object.hash(
    videoId,
    threadId,
    parentContentId,
    replyType,
    sortKey,
    occurrenceKey,
  );

  @override
  String toString() =>
      'ContentContext(video: $videoId, thread: $threadId, '
      'parent: $parentContentId, replyType: $replyType, sort: $sortKey, '
      'occurrence: $occurrenceKey)';
}
