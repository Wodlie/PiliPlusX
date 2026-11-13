/// List-revision state machine for a guarded comment list.
///
/// Pure Dart on purpose: the controller mixes this logic in, and the probe
/// drives *this* class rather than a re-implementation of it.
///
/// ## Replace vs append is an identity test, not a caller flag
///
/// The controller's fetch paths disagree about the `isRefresh` flag: one
/// rewrites `false` to `true` internally when the account changed
/// (RootReplyController.queryData), another calls `super.queryData(true)`
/// directly for cursor continuation (RootReplyController.onReload), and the
/// restart loop calls `super.onRefresh()`. A guard trusting the flag would miss
/// every one of those.
///
/// The commit points do not disagree: a replacement assigns a **new** list
/// instance, an append mutates the **existing** instance. [commit] therefore
/// takes the list identity and treats "different instance" as a replacement.
///
/// * replacement -> [ReplyGuardBridge.beginList], so every verdict in flight for
///   the previous list is refused instead of landing on a new row;
/// * append -> same revision, because the rows the user is reading are
///   unchanged and their verdicts are still correct.
///
/// Registration is always the complete accumulated snapshot: the bridge replaces
/// its registry, so a partial list would make every already-loaded row look
/// removed and refuse its late verdicts.
library;

import 'package:PiliPlus/services/content_guard/presenter/reply_guard_bridge.dart';

/// One guarded list: the bridge plus the revision bookkeeping around it.
final class ReplyGuardListState<T> {
  ReplyGuardListState({required this.bridge, required this.inputOf});

  /// The bridge every row is registered with and every result applied to.
  final ReplyGuardBridge bridge;

  /// Maps a platform row onto its bridge input.
  final CommentInput Function(T row) inputOf;

  /// Projection of the last committed snapshot, or null before the first one.
  ReplyGuardProjection? projection;

  /// Identity of the list instance the current revision was built for.
  Object? _identity;

  /// Last committed rows, kept so [apply] can rebuild without the caller
  /// re-passing the list.
  List<T>? _rows;

  /// Revision the projection currently describes.
  int get generation => bridge.generation;

  /// Last committed rows, or null before the first commit.
  List<T>? get rows => _rows;

  /// Whether [contentId] already carries a verdict for [contentVersion].
  ///
  /// The dedup key for evaluation: re-evaluating a row whose verdict is still
  /// current would write the same row again and, worse, run the rule pass on every
  /// redraw of a long list.
  bool isDecided(String contentId, String contentVersion) {
    final view = projection;
    if (view == null) return false;
    if (!view.decidedContentIds.contains(contentId)) return false;
    final presentation = view.forContentId(contentId);
    return presentation != null &&
        presentation.contentVersion == contentVersion;
  }

  /// Registers the list already on screen when a pipeline is bound late.
  ///
  /// Binding after the first page loaded must not leave those rows unregistered
  /// until the next fetch, and must not advance the revision: nothing was
  /// invalidated, there is simply no earlier projection to invalidate.
  ReplyGuardProjection? bindLoaded(List<T>? rows, {Object? identity}) {
    if (rows == null) return projection;
    _rows = rows;
    _identity = identity ?? rows;
    projection = bridge.projectionFor(rows.map(inputOf));
    return projection;
  }

  /// Observes a commit of [rows] and returns whether the revision advanced.
  ///
  /// A null [rows] means the list is loading or errored. The previous projection
  /// is deliberately kept: the rows it describes are still registered, and
  /// blanking it would make a no-op busy cycle erase guard state for content
  /// that has not changed.
  bool commit(List<T>? rows, {Object? identity}) {
    if (rows == null) return false;
    final nextIdentity = identity ?? rows;
    final replaced = !identical(nextIdentity, _identity);
    if (replaced) {
      // Advance before registering, so a result stamped with the previous
      // revision cannot be attributed to a row of the new list.
      bridge.beginList();
      _identity = nextIdentity;
    }
    _rows = rows;
    projection = bridge.projectionFor(rows.map(inputOf));
    return replaced;
  }

  /// Applies results and rebuilds the projection.
  ///
  /// The bridge refuses a result whose surface, account, content id, generation
  /// or payload revision no longer matches, so a late result for a removed row
  /// never reaches a row. Returns the report; the caller decides whether to
  /// notify its views.
  ReplyApplyReport apply(Iterable<ReplyDecision> decisions) {
    final report = bridge.applyDecisions(decisions);
    final rows = _rows;
    if (rows != null) projection = bridge.projectionFor(rows.map(inputOf));
    return report;
  }

  /// Drops list-scoped state. Used when the guard is unbound.
  void reset() {
    projection = null;
    _identity = null;
    _rows = null;
  }
}
