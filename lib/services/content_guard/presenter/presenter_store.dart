/// In-memory presenter state for the rows currently on screen.
///
/// ## Why this is not a GetxController
///
/// The intended shape was a `GetxController` with an `RxMap`. It cannot be one
/// here: every entry point of `package:get/get.dart` (including `GetxController`)
/// transitively imports `package:flutter/widgets.dart`, and *that* imports
/// `dart:ui`. A plain-Dart check script cannot run with `dart:ui`, so a
/// GetxController store would be unverifiable in this environment — and the
/// fallback was declared up front for exactly this case.
///
/// What replaces it is the same observable contract without the Flutter
/// dependency: a plain class with a listener list, so a page can wrap it in
/// whatever reactive primitive it uses (`Obx`, `ValueListenableBuilder`, a
/// rebuild callback) and the decision layer stays UI-free.
///
/// ## Write-back guard
///
/// A stored row is not just a [ContentPresentation]. It is a presentation *and*
/// the identity it was accepted under: the payload revision (`contentVersion`),
/// the account scope and the surface. Keeping the revision beside the row is what
/// makes "this verdict judged the text on screen" answerable at all — the
/// presentation itself does not carry it, and inferring it from the caller's
/// current list is exactly how an old verdict gets relabelled with a new
/// revision.
///
/// [put] therefore refuses:
///
/// * a candidate whose generation is *not* the store's current generation —
///   older rows describe a list the user has replaced, and newer rows would
///   describe a list that does not exist yet and would survive the next bump;
/// * a candidate whose account scope or surface contradicts the identity already
///   stored for that row, so two accounts can never share one row;
/// * a byte-identical rewrite, which is a no-op rather than a change.
///
/// A row written without a revision is stored as *unversioned*. It is kept (a
/// caller that only holds a [ContentPresentation] still gets the old write-back
/// behaviour) but it can never be read as a current verdict, because nothing
/// proves which revision it judged — see [StoredPresentation.isCurrent].
library;

import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';

/// One stored row plus the identity it was accepted under.
///
/// The identity fields are nullable because a caller may legitimately hold only a
/// [ContentPresentation]. `null` means "not carried", never "matches anything":
/// [isCurrent] answers false for an unversioned row, so the presenter layer reads
/// it as *pending* rather than as a verdict about the current payload.
final class StoredPresentation {
  const StoredPresentation({
    required this.presentation,
    this.contentVersion,
    this.accountScopeId,
    this.surface,
  });

  /// The row a list renders.
  final ContentPresentation presentation;

  /// Revision of the payload the verdict was computed from, when carried.
  final String? contentVersion;

  /// Account scope the row was written for, when carried.
  final String? accountScopeId;

  /// Surface the row was written for, when carried.
  final ContentSurface? surface;

  /// Content id the row belongs to.
  String get contentId => presentation.contentId;

  /// List revision the row was written for.
  int get generation => presentation.generation;

  /// Whether this row may be read as the verdict for a row at
  /// [contentVersion] in list revision [generation].
  ///
  /// Both axes must match exactly. A row that judged an older edit of the same
  /// comment is not the current verdict even though the id and the revision
  /// number agree, which is why the payload revision is compared here and not
  /// only in the writer.
  bool isCurrent({required String contentVersion, required int generation}) =>
      this.contentVersion == contentVersion && this.generation == generation;

  /// Two stored rows are equal only when the presentation *and* the identity it
  /// was accepted under agree.
  ///
  /// The identity is part of the record: re-writing the same presentation under a
  /// correct revision is a genuine change (it turns an unreadable row into a
  /// readable one), so it must not be swallowed as a no-op.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoredPresentation &&
          presentation == other.presentation &&
          contentVersion == other.contentVersion &&
          accountScopeId == other.accountScopeId &&
          surface == other.surface;

  @override
  int get hashCode =>
      Object.hash(presentation, contentVersion, accountScopeId, surface);

  @override
  String toString() =>
      'StoredPresentation(${presentation.contentId}@'
      '${contentVersion ?? 'unversioned'}, generation: ${generation})';
}

/// Reactive map of content id to presentation state.
final class PresenterStore {
  PresenterStore({int generation = 0}) : _generation = generation;

  final Map<String, StoredPresentation> _entries =
      <String, StoredPresentation>{};

  final List<void Function()> _listeners = <void Function()>[];

  int _generation;

  /// Current list revision.
  ///
  /// Only moves forward through [bumpGeneration]. A candidate stamped with any
  /// other revision is refused, so results computed for a list the user has
  /// already replaced are dropped.
  int get generation => _generation;

  /// Number of rows held.
  int get length => _entries.length;

  /// Whether no row is held.
  bool get isEmpty => _entries.isEmpty;

  /// Whether any row is held.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// Immutable view of the current rows.
  Map<String, ContentPresentation> get snapshot =>
      Map<String, ContentPresentation>.unmodifiable(
        <String, ContentPresentation>{
          for (final entry in _entries.entries)
            entry.key: entry.value.presentation,
        },
      );

  /// Presentation stored for [contentId], or null when the row has none yet.
  ContentPresentation? operator [](String contentId) =>
      _entries[contentId]?.presentation;

  /// Presentation stored for [contentId], or null when the row has none yet.
  ContentPresentation? find(String contentId) =>
      _entries[contentId]?.presentation;

  /// Row stored for [contentId] with the identity it was accepted under.
  ///
  /// The identity-carrying read: a consumer that has to decide whether a verdict
  /// is still about the payload on screen must use this and not [find], because
  /// the presentation alone cannot answer it.
  StoredPresentation? entryFor(String contentId) => _entries[contentId];

  /// Payload revision stored for [contentId], or null when the row is absent or
  /// was written without one.
  String? versionOf(String contentId) => _entries[contentId]?.contentVersion;

  /// Stores [candidate], unless it is a late write or an identity mismatch.
  ///
  /// Returns true when the store changed. The guard is the monotonic one this
  /// store has always had: a candidate older than the current revision is
  /// refused, so a late async result never overwrites the row the user is looking
  /// at. It is *not* the exact-revision guard — use [putCurrent] whenever the
  /// caller holds the result of a pipeline run, because a candidate from a future
  /// revision passes here and would then outlive the next [bumpGeneration].
  bool put(
    ContentPresentation candidate, {
    String? contentVersion,
    String? accountScopeId,
    ContentSurface? surface,
  }) => _write(
    StoredPresentation(
      presentation: candidate,
      contentVersion: contentVersion,
      accountScopeId: accountScopeId,
      surface: surface,
    ),
    exact: false,
  );

  /// Stores [candidate] only when it belongs to the revision in force now.
  ///
  /// This is the write-back path for a pipeline result: the row must carry
  /// exactly [generation], never an older or a newer one. An older revision
  /// describes a list the user replaced; a newer one describes a list that does
  /// not exist yet, and admitting it would let a single stray result survive
  /// every subsequent bump — the stale-write defect this guard closes.
  ///
  /// The optional identity arguments are stored with the row, so a later read can
  /// tell whether the verdict is still about the payload on screen
  /// ([StoredPresentation.isCurrent]).
  bool putCurrent(
    ContentPresentation candidate, {
    required String contentVersion,
    String? accountScopeId,
    ContentSurface? surface,
  }) => _write(
    StoredPresentation(
      presentation: candidate,
      contentVersion: contentVersion,
      accountScopeId: accountScopeId,
      surface: surface,
    ),
    exact: true,
  );

  /// Stores every candidate, skipping the stale ones.
  ///
  /// Returns the number of rows actually written. One bulk notifier call is
  /// issued for the whole batch, so a list rebuild happens once. The candidates
  /// are unversioned: use [put] whenever the revision the verdict judged is
  /// known, which is the only form that can be read back as a current verdict.
  int putAll(Iterable<ContentPresentation> candidates) {
    var written = 0;
    for (final candidate in candidates) {
      final stored = _entries[candidate.contentId];
      final next = StoredPresentation(presentation: candidate);
      if (!_accepts(stored, next, exact: false)) continue;
      if (stored == next) continue;
      _entries[candidate.contentId] = next;
      written++;
    }
    if (written > 0) _notify();
    return written;
  }

  /// Drops the row for [contentId]. Returns whether anything was removed.
  bool remove(String contentId) {
    final removed = _entries.remove(contentId);
    if (removed == null) return false;
    _notify();
    return true;
  }

  /// Drops every row and notifies once.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _notify();
  }

  /// Starts a new list revision and returns it.
  ///
  /// Rows stamped for another revision are dropped rather than kept: they
  /// describe a list that no longer exists. The generation is monotonic, so a
  /// candidate produced before this call can never be written afterwards.
  int bumpGeneration() {
    _generation++;
    var changed = false;
    _entries.removeWhere((_, value) {
      final stale = value.generation < _generation;
      if (stale) changed = true;
      return stale;
    });
    if (changed) _notify();
    return _generation;
  }

  /// Registers [listener]; call it whenever a row changes.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Unregisters [listener].
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Whether [next] may replace [stored].
  ///
  /// With [exact] the generation must be the store's current one exactly.
  /// Without it the historical floor applies: the candidate may not be older than
  /// the store's revision, and it may not be older than the row it would replace.
  /// The second half is what keeps completion order from becoming write order, and
  /// it also admits a candidate from a newer revision — which is what lets a
  /// caller that owns its own counter write rows ahead of this store (a check that
  /// starts the store at 0 and stamps a row with revision 5 must keep working).
  bool _accepts(
    StoredPresentation? stored,
    StoredPresentation next, {
    required bool exact,
  }) {
    if (exact
        ? next.generation != _generation
        : next.generation < _generation) {
      return false;
    }
    if (stored == null) return true;
    if (!exact && next.generation < stored.generation) return false;
    // Two accounts, or two surfaces, never share one row. A null on either side
    // is "not carried" and is not a contradiction, but the bridge always carries
    // them, so a cross-account write cannot be produced through it.
    final storedAccount = stored.accountScopeId;
    final nextAccount = next.accountScopeId;
    if (storedAccount != null &&
        nextAccount != null &&
        storedAccount != nextAccount) {
      return false;
    }
    final storedSurface = stored.surface;
    final nextSurface = next.surface;
    if (storedSurface != null &&
        nextSurface != null &&
        storedSurface != nextSurface) {
      return false;
    }
    return true;
  }

  /// Shared body of [put] and [putCurrent].
  bool _write(StoredPresentation next, {required bool exact}) {
    final stored = _entries[next.contentId];
    if (!_accepts(stored, next, exact: exact)) return false;
    if (stored == next) return false;
    _entries[next.contentId] = next;
    _notify();
    return true;
  }

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  @override
  String toString() =>
      'PresenterStore(rows: ' +
      _entries.length.toString() +
      ', generation: ' +
      _generation.toString() +
      ')';
}
