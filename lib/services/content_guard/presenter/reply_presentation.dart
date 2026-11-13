/// The row a comment widget renders after a ContentGuard decision.
///
/// This is the bridge between "what the decision layer settled" and "what a
/// comment row draws". It is a value object: no widget, no `BuildContext`, no
/// colour, no callback and no localisation string. A widget receives one of
/// these and decides what to draw; nothing here knows how to draw it.
///
/// ## Why it is not [ContentPresentation]
///
/// [ContentPresentation] is the decision layer's own vocabulary and is shared by
/// every surface (video cards, dynamics, search results). A comment row needs two
/// things that surface does not carry:
///
/// * the [contentVersion] the row was judged at, so a late result can be matched
///   against the text the user is looking at instead of the text that was judged;
/// * whether a suggestion card renders *at this row*, which is an anchor
///   question, not a decision question.
///
/// Copying the two into a subclass or a mutable wrapper would let the two views
/// drift; carrying one decision inside an explicit translation is cheap and makes
/// the extra fields impossible to forget.
///
/// ## What it never says
///
/// * It never says "remove this row". A hidden comment is [isPlaceholder] with
///   [showsBody] false — the element stays so pagination, anchors and scroll
///   position are unaffected.
/// * It never carries content text. [explanation] is assembled from reason codes
///   by the decision layer and never quotes what the author wrote.
library;

import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';

/// Presentation of one comment row.
///
/// The const constructor does not copy its collections: callers must hand over
/// immutable sets, which is what both [ContentPresentation] and this class
/// already produce.
final class ReplyPresentation {
  const ReplyPresentation({
    required this.contentId,
    required this.contentVersion,
    required this.state,
    required this.isPlaceholder,
    required this.recoverable,
    required this.reasonCodes,
    required this.maskedMediaIds,
    required this.generation,
    this.explanation,
    this.suggestionId,
    this.showSuggestionCard = false,
  });

  /// Translates one [ContentPresentation] into a comment row.
  ///
  /// [contentVersion] must be the version of the comment the decision was
  /// computed from: it is the field the write-back guard compares, so passing the
  /// current version of a *different* revision would silently attach a verdict to
  /// text it never saw.
  factory ReplyPresentation.fromContentPresentation(
    ContentPresentation presentation, {
    required String contentVersion,
    String? suggestionId,
    bool showSuggestionCard = false,
  }) => ReplyPresentation(
    contentId: presentation.contentId,
    contentVersion: contentVersion,
    state: presentation.state,
    isPlaceholder: presentation.isPlaceholder,
    recoverable: presentation.recoverable,
    reasonCodes: presentation.reasonCodes,
    maskedMediaIds: presentation.maskedMediaIds,
    generation: presentation.generation,
    explanation: presentation.explanation,
    suggestionId: suggestionId ?? presentation.suggestionId,
    showSuggestionCard: showSuggestionCard,
  );

  /// The row that exists before any decision has landed.
  ///
  /// A pending row is a placeholder and is *not* recoverable: there is nothing to
  /// restore yet, and it never renders as [PresenterState.allowed].
  factory ReplyPresentation.pending({
    required String contentId,
    required String contentVersion,
    required int generation,
  }) => ReplyPresentation(
    contentId: contentId,
    contentVersion: contentVersion,
    state: PresenterState.pending,
    isPlaceholder: true,
    recoverable: false,
    reasonCodes: const <String>{},
    maskedMediaIds: const <String>{},
    generation: generation,
  );

  /// Platform id of the comment (rpid).
  final String contentId;

  /// Version of the comment payload the decision was computed from.
  final String contentVersion;

  final PresenterState state;

  /// Whether this row stands in for content instead of showing it.
  final bool isPlaceholder;

  /// Whether the user may lift the restriction (or undo a manual allow).
  final bool recoverable;

  /// Stable machine reason codes. Never content text.
  final Set<String> reasonCodes;

  /// [MediaRef.stableKey] values the mask covers. Empty unless [isMasked].
  final Set<String> maskedMediaIds;

  /// List revision this row belongs to.
  final int generation;

  /// Short explanation assembled from reason codes. Never content text.
  final String? explanation;

  /// Author-level suggestion anchor currently showing at this row, when any.
  final String? suggestionId;

  /// Whether a suggestion card renders at this row.
  final bool showSuggestionCard;

  /// Whether the comment body is drawn.
  ///
  /// [PresenterState.masked] keeps the body (only media is masked) and
  /// [PresenterState.uncertain] keeps it with a notice; [collapsed] and [hidden]
  /// replace it with a placeholder.
  bool get showsBody => state.showsBody;

  /// Whether no decision has landed yet.
  bool get isPending => state == PresenterState.pending;

  /// Whether the comment is hidden; the row stays as a placeholder.
  bool get isHidden => state == PresenterState.hidden;

  /// Whether the comment is replaced by a placeholder the user can expand.
  bool get isCollapsed => state == PresenterState.collapsed;

  /// Whether the row is shown with some media masked.
  bool get isMasked => state == PresenterState.masked;

  /// Whether the verdict could not be settled and the row carries a notice.
  bool get isUncertain => state == PresenterState.uncertain;

  /// Whether the row is shown normally.
  bool get isAllowed => state == PresenterState.allowed;

  /// Whether anything is being withheld from the reader.
  ///
  /// A pending row is not restricted: nothing has been decided about it, so it
  /// must not be announced as filtered.
  bool get isRestricted => !isAllowed && !isPending;

  /// Whether a collapsed/hidden placeholder banner is drawn instead of the body.
  bool get showsPlaceholderBanner => isCollapsed || isHidden;

  /// Whether any media identity is masked.
  bool get hasMaskedMedia => maskedMediaIds.isNotEmpty;

  /// Whether [mediaStableKey] ([MediaRef.stableKey]) is masked at this row.
  ///
  /// Only a [PresenterState.masked] row masks anything: a hidden or collapsed row
  /// has no visible media to mask, and answering "covered" there would let a
  /// future widget hide media out of a placeholder for no reason.
  bool masksMedia(String mediaStableKey) =>
      isMasked && maskedMediaIds.contains(mediaStableKey);

  /// Whether the media whose platform id is [mediaId] is masked at this row.
  ///
  /// A widget holding only a platform id — a comment picture, whose payload
  /// carries a URL and no fingerprint — cannot compute [MediaRef.stableKey]
  /// itself, because the key depends on whether a fingerprint was computed on the
  /// way in. This answers for both spellings instead of making every call site
  /// re-implement the prefix rules and drift from [MediaRef.stableKey].
  bool masksMediaId(String mediaId) {
    if (!isMasked) return false;
    return maskedMediaIds.contains('id:$mediaId') ||
        maskedMediaIds.contains('fp:$mediaId');
  }

  /// Whether the row can be expanded into its body.
  ///
  /// True for both placeholder spellings, because [ContentPresentation.recoverable]
  /// is true for every restricting state — the decision layer's own contract says
  /// a hidden row "must not be a dead end". Expanding is a local read of the row
  /// the user already received; it is not a policy decision, so the decision layer
  /// has nothing to add here.
  bool get canExpand => (isCollapsed || isHidden) && recoverable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReplyPresentation &&
          contentId == other.contentId &&
          contentVersion == other.contentVersion &&
          state == other.state &&
          isPlaceholder == other.isPlaceholder &&
          recoverable == other.recoverable &&
          generation == other.generation &&
          explanation == other.explanation &&
          suggestionId == other.suggestionId &&
          showSuggestionCard == other.showSuggestionCard &&
          _setEquals(reasonCodes, other.reasonCodes) &&
          _setEquals(maskedMediaIds, other.maskedMediaIds);

  @override
  int get hashCode => Object.hash(
    contentId,
    contentVersion,
    state,
    isPlaceholder,
    recoverable,
    generation,
    explanation,
    suggestionId,
    showSuggestionCard,
    Object.hashAllUnordered(reasonCodes),
    Object.hashAllUnordered(maskedMediaIds),
  );

  /// Omits [explanation] only; it is code-only by construction anyway.
  @override
  String toString() =>
      'ReplyPresentation($contentId, ${state.wireName}, '
      'version: $contentVersion, generation: $generation, '
      'placeholder: $isPlaceholder, cards: $showSuggestionCard, '
      'codes: $reasonCodes, masked: $maskedMediaIds)';
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final value in a) {
    if (!b.contains(value)) return false;
  }
  return true;
}
