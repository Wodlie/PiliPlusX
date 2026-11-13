/// How one content item is presented, derived from a composed decision.
///
/// The vocabulary is closed and maps one-to-one onto what a list can render: a
/// normal row, a collapsed row, an absent row, a row with masked media, or a row
/// whose decision could not be settled. Nothing here is UI — no widget, no
/// BuildContext, no colour and no animation — so the decision layer can import
/// it without reaching Flutter.
library;

/// Presentation state of one content item.
///
/// [pending] is not a decision: it is the state a row has between being listed
/// and its decision arriving, and it exists so a list never has to treat "not
/// decided yet" as [allowed].
enum PresenterState {
  /// No decision yet: an async pass is still in flight, or the store was just
  /// opened for a new list revision.
  pending,

  /// Shown normally.
  allowed,

  /// Replaced by a placeholder the user can expand.
  collapsed,

  /// Not shown at all; the row itself stays in the list as a placeholder.
  hidden,

  /// Shown with the media roles named by the decision masked.
  masked,

  /// A verdict could not be settled (capability missing, timeout, error).
  ///
  /// The body stays visible and the row is marked, so the item is never quietly
  /// treated as a pass (plan-core section 4, precedence rung 6/7).
  uncertain;

  /// Stable machine name for storage, logs and the UI. Frozen.
  String get wireName => name;

  /// Whether the body of the item is rendered.
  ///
  /// [masked] keeps the body (only media is masked) and [uncertain] keeps it
  /// with a notice; removing a body is what [hidden] and [collapsed] do.
  bool get showsBody => this == allowed || this == masked || this == uncertain;

  /// Whether a placeholder replaces the item.
  ///
  /// [pending] is a placeholder too — a skeleton row — because the element must
  /// exist before its decision does: hiding it would shift the list, and
  /// removing it would lose the anchor a late result needs (plan-core section 9).
  bool get isPlaceholder =>
      this == pending || this == collapsed || this == hidden;
}

/// One row of presenter state, ready to render.
///
/// The const constructor does not copy its collections: callers must pass
/// immutable sets. The composer and the presenter always hand over unmodifiable
/// values, so sharing them here costs no copy.
final class ContentPresentation {
  const ContentPresentation({
    required this.contentId,
    required this.state,
    required this.recoverable,
    required this.isPlaceholder,
    required this.reasonCodes,
    required this.tags,
    required this.maskedMediaIds,
    required this.generation,
    this.explanation,
    this.suggestionId,
  });

  /// The row a list renders before any decision has landed.
  const ContentPresentation.pending({
    required this.contentId,
    required this.generation,
  }) : state = PresenterState.pending,
       recoverable = false,
       isPlaceholder = true,
       reasonCodes = const <String>{},
       tags = const <String>{},
       maskedMediaIds = const <String>{},
       explanation = null,
       suggestionId = null;

  /// Platform id this row belongs to (rpid, aid, dynamic id, ...).
  final String contentId;

  final PresenterState state;

  /// Whether the restriction shown here can be lifted by a user action.
  ///
  /// True for every restricting state (collapsed, hidden, masked, uncertain) —
  /// an uncertain row must not be a dead end — and for a row allowed by a
  /// manual override, which the user may undo. False for a row allowed by
  /// policy, where there is no restriction to lift.
  final bool recoverable;

  /// Whether the row is a placeholder instead of the content itself.
  ///
  /// Hidden content still yields a row: the element is never deleted from the
  /// list, only replaced (plan-core section 5).
  final bool isPlaceholder;

  /// Stable machine reason codes behind this state. Never raw content text.
  final Set<String> reasonCodes;

  /// Tags the rule pass accumulated.
  final Set<String> tags;

  /// Media identities to mask: [MediaRef.stableKey] values, never URLs.
  ///
  /// Empty unless [state] is [PresenterState.masked].
  final Set<String> maskedMediaIds;

  /// List revision this presentation was computed for.
  ///
  /// The write-back guard: a candidate whose generation is older than the one
  /// already stored is discarded, so a late async result never overwrites a
  /// newer row (plan-core section 9).
  final int generation;

  /// Short explanation assembled from reason codes. Never content text.
  final String? explanation;

  /// Suggestion anchor this row is currently showing, when one is expanded.
  final String? suggestionId;

  /// Whether the body is visible in this state.
  bool get showsBody => state.showsBody;

  /// Whether this row is replaced by a placeholder.
  bool get isUncertain => state == PresenterState.uncertain;

  /// Whether any media identity is masked.
  bool get hasMaskedMedia => maskedMediaIds.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContentPresentation &&
          contentId == other.contentId &&
          state == other.state &&
          recoverable == other.recoverable &&
          isPlaceholder == other.isPlaceholder &&
          generation == other.generation &&
          explanation == other.explanation &&
          suggestionId == other.suggestionId &&
          _setEquals(reasonCodes, other.reasonCodes) &&
          _setEquals(tags, other.tags) &&
          _setEquals(maskedMediaIds, other.maskedMediaIds);

  @override
  int get hashCode => Object.hash(
    contentId,
    state,
    recoverable,
    isPlaceholder,
    generation,
    explanation,
    suggestionId,
    Object.hashAllUnordered(reasonCodes),
    Object.hashAllUnordered(tags),
    Object.hashAllUnordered(maskedMediaIds),
  );

  /// Omits [explanation] text only; it is already code-only by construction.
  @override
  String toString() {
    final wire = state.wireName;
    return 'ContentPresentation($contentId, $wire, generation: $generation, '
        'recoverable: $recoverable, placeholder: $isPlaceholder, '
        'codes: $reasonCodes, masked: $maskedMediaIds)';
  }
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final value in a) {
    if (!b.contains(value)) return false;
  }
  return true;
}
