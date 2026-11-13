/// The blacklist suggestion state machine (spec sections 7.4 and 7.5).
///
/// ## What it owns
///
/// One [BlacklistSuggestion] per author, and its lifecycle:
///
/// ```
///   (no record) --count >= threshold--> candidate --present--> visible
/// visible --user accepts--> accepted   (terminal; never auto-revoked)
/// visible --user rejects--> rejected   (persists across restart; suppresses)
/// visible --user snoozes--> snoozed    (cooldown; NOT a rejection)
/// pending --counts fell --> invalidated
/// ```
///
/// ## The three rules that are easy to get wrong
///
/// 1. **Broadcast is structural, not a loop.** Every anchor of one author carries
///    the same [SuggestionAnchor.authorSuggestionId], and the state is stored once
///    per that id. Accepting any card therefore changes what every other card of
///    the same author renders — there is no list of anchored instances to keep in
///    sync, so there is nothing that can fall out of sync.
/// 2. **accepted is not the machine's to undo.** New AI verdicts, recollected
///    counts and corrections never move an accepted suggestion; only
///    [unaccept] does. A manual blacklist stays until the user removes it.
/// 3. **rejected is durable and quiet.** It is written to the store like any other
///    state, so a fresh machine instance over the same store reads it back and
///    keeps suppressing.
///
/// ## Storage
///
/// Through [JsonRepository] under [ContentGuardStorageKeys.suggestions], one entry
/// per author suggestion id, namespaced by the account's **durable** identity
/// ([AccountScope.durableId]) — not by the credential-generation request id.
/// Rejecting/accepting/snoozing an author while logged in as one account does not
/// decide it for another (different mids never share a namespace), but a re-login,
/// an access-key rotation or a device change of the *same* account keeps the
/// decision. That is the point: a "never suggest this author again" that a cookie
/// refresh could silently undo is worse than no promise at all.
///
/// [authorSuggestionId] is minted from the same durable id, so the anchors a
/// rotated credential produces still address the record the user already decided.
///
/// ## Two instances over one store
///
/// The cache is a read accelerator, never the authority. A machine is built
/// once per service, but a page that was opened before the user rejected an
/// author, or a second service over the same box, still holds an older reading.
/// Writing that reading back is what turns a durable rejection into a fresh
/// candidate, so every mutation does two things before it writes:
///
/// * it re-reads the **persisted** record and makes that reading the base of the
///   transition, so a state the user set on another instance is never lost to a
///   stale cache; and
/// * it merges with [BlacklistSuggestion.resolveAgainst] instead of overwriting.
///
/// Every write stamps a monotonic [BlacklistSuggestion.revision], so "which of
/// these two readings is current" is answered by the record itself rather than by
/// wall-clock ties or by which write happened to land last. That is exactly the
/// question the merge rule asks: **the higher revision wins**, and at equal
/// revision a terminal user decision ([SuggestionState.accepted] /
/// [SuggestionState.rejected]) wins, which protects records written before the
/// field existed. A reconcile computed from pre-rejection counts carries the
/// older revision and therefore loses — it can refresh the count but never the
/// state — while a genuinely later transition ([unaccept], or a reset followed by
/// a new evaluation) carries a higher one and does take effect.
///
/// Reads merge the same way, so a card stops rendering as soon as any instance
/// rejects the author, without waiting for this machine to reload.
///
/// Mutations of one author suggestion id are additionally queued behind each
/// other **in this process** — keyed by account scope plus id and shared by all
/// machine instances — because read-then-write over an interface with
/// synchronous reads and asynchronous writes would otherwise interleave. That
/// queue is the honest limit of [KeyValueStore]: two isolates or two processes
/// over one box are not serialized here, so a cross-process write that lands
/// between this machine read and this machine write can still lose. The merge
/// rule is what keeps that loss non-destructive: it can only ever lose a count
/// refresh, never a user decision.
library;

import 'dart:async';

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/storage/content_guard_storage_keys.dart';
import 'package:PiliPlus/services/content_guard/storage/json_repository.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_anchor.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_policy.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_repository.dart';

/// What the machine says about one anchor after applying stored state.
final class SuggestionRenderDecision {
  const SuggestionRenderDecision({
    required this.anchor,
    required this.state,
    required this.shouldRender,
    this.suggestion,
    this.reasonCode,
  });

  final SuggestionAnchor anchor;

  /// State in force for this anchor's author-level suggestion.
  final SuggestionState state;

  /// Whether the card may render at [anchor].
  final bool shouldRender;

  /// The author-level suggestion, when one has been recorded.
  final BlacklistSuggestion? suggestion;

  /// Stable machine reason when [shouldRender] is false.
  final String? reasonCode;

  @override
  String toString() =>
      'SuggestionRenderDecision(${anchor.nodeId}, ${state.wireName}, '
      'render: $shouldRender)';
}

/// One persisted lifecycle for one author, under one account scope.
final class BlacklistSuggestionMachine {
  BlacklistSuggestionMachine(
    KeyValueStore store, {
    required AccountScope account,
    SuggestionPolicy policy = const SuggestionPolicy(),
    int schemaVersion = 1,
    int Function()? nowMs,
  }) : durableScopeId = account.durableId,
       requestScopeId = account.id,
       _policy = policy,
       _nowMs = nowMs ?? _systemNowMs,
       _repository = JsonRepository(
         store,
         domain: ContentGuardStorageKeys.suggestions,
         accountScopeId: account.durableId,
         schemaVersion: schemaVersion,
         nowMs: nowMs,
       );

  /// Storage domain this machine owns.
  static const String domain = ContentGuardStorageKeys.suggestions;

  /// Value of [BlacklistSuggestion.decidedBy] for every user-driven transition.
  static const String decidedByUser = 'user';

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Process-wide queue tail per stored suggestion id, shared by every machine.
  ///
  /// Static on purpose: serializing only helps if two machines over the same
  /// store share the queue, which is exactly the two-instance case. That the
  /// queue is in-process is the limit of the generic [KeyValueStore] contract —
  /// see the library doc.
  static final Map<String, Future<void>> _queues = <String, Future<void>>{};

  /// Durable namespace of every record, queue entry and author suggestion id of
  /// this machine.
  ///
  /// Stable across credential/device/platform rotation of one account; equal to
  /// the request scope id for a guest, which keeps anonymous sessions isolated.
  final String durableScopeId;

  /// Credential-generation scope this machine was built under. Provenance only —
  /// it takes no part in any key.
  final String requestScopeId;

  /// Alias of [durableScopeId] — the namespace a stored suggestion carries.
  String get accountScopeId => durableScopeId;

  final int Function() _nowMs;
  final JsonRepository _repository;

  SuggestionPolicy _policy;

  /// Warm copy of the stored lifecycles, keyed by author suggestion id.
  ///
  /// Reads are synchronous because the UI asks "may I render this anchor" on
  /// every build. This map is an accelerator, not the authority: [load] fills it
  /// and every read still merges the stored record, so an instance that hydrated
  /// before a decision cannot keep rendering the pre-decision state.
  final Map<String, BlacklistSuggestion> _cache =
      <String, BlacklistSuggestion>{};

  /// Policy currently in force.
  SuggestionPolicy get policy => _policy;

  /// Replaces [policy]; already-stored suggestions keep the values they settled
  /// under, so a policy change cannot rewrite the past.
  void configure(SuggestionPolicy policy) => _policy = policy;

  /// Author-level suggestion id for [authorUid] under this account.
  ///
  /// Derived from the **durable** namespace, so an anchor built after a cookie
  /// rotation still names the record the user accepted or rejected under the old
  /// credential — that is what keeps request-scope matching of anchors intact
  /// while the persistence identity stays put.
  String suggestionIdFor(String authorUid) =>
      SuggestionRunKey.authorSuggestionIdOf(durableScopeId, authorUid);

  /// The durable author suggestion id [anchor] addresses.
  ///
  /// An anchor is built by the transient layer and therefore carries the
  /// **request** scope id inside its own [SuggestionAnchor.authorSuggestionId].
  /// That is correct for rendering — a credential rotation should re-render — but
  /// it must not address storage. Anchors name their author explicitly, so the
  /// durable id is re-derived from [SuggestionAnchor.authorUid] rather than
  /// parsed out of the anchor's id. Every anchor-facing read and mutation goes
  /// through here; nothing in the anchor's own id is treated as a store key.
  String anchorSuggestionId(SuggestionAnchor anchor) =>
      suggestionIdFor(anchor.authorUid);

  /// Hydrates the cache from storage. Rejected, snoozed and accepted states all
  /// survive a restart through this call.
  ///
  /// Hydration is a warm-up, not the source of truth: every read merges the
  /// stored record anyway, so a suggestion another instance decides after this
  /// call is still seen.
  Future<void> load() async {
    _cache.clear();
    for (final storageId in _repository.ids()) {
      switch (_readPersisted(StorageIdCodec.decode(storageId))) {
        case Ok<BlacklistSuggestion>(:final value):
          _cache[value.authorSuggestionId] = value;
        case Miss<BlacklistSuggestion>():
        case Corrupt<BlacklistSuggestion>():
          // A corrupt entry is skipped, not repaired into a default: silently
          // turning a rejected suggestion into a fresh candidate is exactly the
          // re-suggestion the user asked never to see again.
          continue;
      }
    }
  }

  /// Every suggestion known to this machine, most recently updated first.
  ///
  /// Read through the store rather than out of the cache, so a suggestion
  /// another instance decided is reflected here without a reload.
  List<BlacklistSuggestion> allSuggestions() {
    final list = <BlacklistSuggestion>[];
    for (final storageId in _repository.ids()) {
      final suggestion = _baseOf(StorageIdCodec.decode(storageId)).value;
      if (suggestion != null) {
        list.add(suggestion);
      }
    }
    list.sort((a, b) {
      final byTime = b.updatedAtMs.compareTo(a.updatedAtMs);
      return byTime != 0
          ? byTime
          : a.authorSuggestionId.compareTo(b.authorSuggestionId);
    });
    return List<BlacklistSuggestion>.unmodifiable(list);
  }

  /// The suggestion of [authorUid], or null when none exists yet.
  BlacklistSuggestion? forAuthor(String authorUid) {
    final author = authorUid.trim();
    if (author.isEmpty) {
      return null;
    }
    return byId(suggestionIdFor(author));
  }

  /// The suggestion with [authorSuggestionId], or null.
  ///
  /// This is the read the UI makes on every build, so it merges the cached
  /// reading with the stored one: a rejection written by another machine shows
  /// up here immediately instead of after the next mutation.
  BlacklistSuggestion? byId(String authorSuggestionId) =>
      _baseOf(authorSuggestionId).value;

  /// State in force for [authorSuggestionId]; [SuggestionState.candidate] when
  /// nothing is stored, which is the "would be suggested" default.
  SuggestionState stateFor(String authorSuggestionId) =>
      byId(authorSuggestionId)?.state ?? SuggestionState.candidate;

  /// State in force for the author of [anchor] — the broadcast read.
  ///
  /// Addressed by the anchor's author, not by the request-scoped id the anchor
  /// carries, so the record the user already decided is found again after a
  /// credential rotation.
  SuggestionState stateForAnchor(SuggestionAnchor anchor) =>
      stateFor(anchorSuggestionId(anchor));

  /// Queues [action] behind every earlier mutation of the same suggestion id.
  ///
  /// A mutation is read persisted state, decide, write. The interface reads
  /// synchronously and writes asynchronously ([KeyValueStore]), so without this
  /// queue two machines over one store would both read the pre-rejection record
  /// and both write — one of them resurrecting the suggestion.
  Future<T> _serialized<T>(
    String authorSuggestionId,
    Future<T> Function() action,
  ) async {
    final queueKey = '$durableScopeId\u0000$authorSuggestionId';
    final previous = _queues[queueKey];
    final gate = Completer<void>();
    final mine = gate.future;
    _queues[queueKey] = mine;
    try {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed predecessor must not poison the queue: its caller already
          // saw the error, and this action re-reads the state it left behind.
        }
      }
      return await action();
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      if (identical(_queues[queueKey], mine)) {
        _queues.remove(queueKey);
      }
    }
  }

  /// Reads the persisted record of [authorSuggestionId].
  ///
  /// [Miss] means the store holds nothing — never "unreadable". [Corrupt] means
  /// something is stored that cannot be decoded, which is not the same answer
  /// and must not be repaired into a default: that default would be a fresh
  /// candidate for an author the user may already have rejected.
  RepositoryResult<BlacklistSuggestion> _readPersisted(String id) {
    final stored = _repository.read(StorageIdCodec.encode(id));
    switch (stored) {
      case Ok<Map<String, Object?>>(:final value):
        final decoded = BlacklistSuggestion.fromJson(
          JsonRepository.payloadOf(value),
        );
        return decoded == null
            ? const Corrupt<BlacklistSuggestion>(
                'stored suggestion payload is not decodable',
              )
            : Ok<BlacklistSuggestion>(decoded);
      case Miss<Map<String, Object?>>():
        return const Miss<BlacklistSuggestion>();
      case Corrupt<Map<String, Object?>>(:final reason):
        return Corrupt<BlacklistSuggestion>(reason);
    }
  }

  /// The record a transition must start from, plus whether it may be written.
  ///
  /// The persisted reading is the base, not the cache:
  ///
  /// * with a stored record, the persisted value and the cache are merged with
  ///   [BlacklistSuggestion.resolveAgainst], so a terminal user decision set on
  ///   any instance wins over a stale automatic state held here;
  /// * with nothing stored, the base is empty and the cached copy is dropped —
  ///   [reset] is the only delete path, so a cached record the store no longer
  ///   has was removed deliberately and must not be written back;
  /// * with an unreadable record, writable is false and automatic transitions
  ///   write nothing. The cached reading is still returned so the caller reports
  ///   something true rather than a clean pass.
  ({BlacklistSuggestion? value, bool writable}) _baseOf(String id) {
    final cached = _cache[id];
    switch (_readPersisted(id)) {
      case Ok<BlacklistSuggestion>(:final value):
        final merged = cached == null ? value : value.resolveAgainst(cached);
        _cache[merged.authorSuggestionId] = merged;
        return (value: merged, writable: true);
      case Miss<BlacklistSuggestion>():
        if (cached != null) {
          _cache.remove(id);
        }
        return (value: null, writable: true);
      case Corrupt<BlacklistSuggestion>():
        return (value: cached, writable: false);
    }
  }

  /// Persists [next] on top of [base], stamping the next write revision.
  ///
  /// The revision is one past the base, never the wall clock: it is what lets a
  /// second instance tell a newer automatic reading from an older one without
  /// needing a shared clock, and it keeps [BlacklistSuggestion.resolveAgainst] a
  /// pure function of the two records.
  Future<BlacklistSuggestion> _write(
    BlacklistSuggestion next, {
    BlacklistSuggestion? base,
  }) async {
    final stamped = next.copyWith(revision: (base?.revision ?? 0) + 1);
    _cache[stamped.authorSuggestionId] = stamped;
    await _repository.write(
      StorageIdCodec.encode(stamped.authorSuggestionId),
      stamped.toJson(),
    );
    return stamped;
  }

  /// Recomputes the lifecycle of [authorUid] from [violationCount].
  ///
  /// This is the correction path: after a revoke drops the count below the
  /// threshold, a pending suggestion becomes [SuggestionState.invalidated], while
  /// an accepted or rejected one is left exactly as it is.
  ///
  /// The transition starts from the **persisted** record, not from this
  /// instance cache, and a terminal user decision found there is never replaced
  /// by an automatic state — see the library doc.
  ///
  /// Returns the settled suggestion, or null when nothing is stored and nothing
  /// qualifies.
  Future<BlacklistSuggestion?> reconcile({
    required String authorUid,
    required int violationCount,
  }) {
    final author = authorUid.trim();
    if (author.isEmpty) {
      return Future<BlacklistSuggestion?>.value(null);
    }
    final id = suggestionIdFor(author);
    return _serialized(
      id,
      () => _reconcileLocked(
        author: author,
        id: id,
        violationCount: violationCount,
      ),
    );
  }

  Future<BlacklistSuggestion?> _reconcileLocked({
    required String author,
    required String id,
    required int violationCount,
  }) async {
    final base = _baseOf(id);
    if (!base.writable) {
      return base.value;
    }
    final nowMs = _nowMs();
    final existing = base.value;
    final meetsThreshold = violationCount >= _policy.threshold;

    if (existing == null) {
      if (!meetsThreshold) {
        return null;
      }
      final created = BlacklistSuggestion(
        authorSuggestionId: id,
        authorUid: author,
        state: SuggestionState.candidate,
        violationCount: violationCount,
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
        threshold: _policy.threshold,
        windowDays: _policy.windowDays,
        reasonCodes: const <String>{SuggestionReasonCodes.thresholdReached},
      );
      return _write(created);
    }

    switch (existing.state) {
      case SuggestionState.accepted:
      case SuggestionState.rejected:
        // User decisions are not the machine to revise. The stored count is
        // still refreshed so the record explains itself, but the state stays.
        if (existing.violationCount == violationCount) {
          return existing;
        }
        return _write(
          existing.copyWith(
            violationCount: violationCount,
            updatedAtMs: nowMs,
          ),
          base: existing,
        );

      case SuggestionState.snoozed:
        if (existing.isSnoozedAt(nowMs)) {
          return existing;
        }
        // Cooldown over: the author may be proposed again, but only if the
        // count still holds up.
        if (!meetsThreshold) {
          return _write(
            existing.copyWith(
              state: SuggestionState.invalidated,
              violationCount: violationCount,
              updatedAtMs: nowMs,
              clearSnooze: true,
              reasonCodes: const <String>{SuggestionReasonCodes.thresholdLost},
            ),
            base: existing,
          );
        }
        return _write(
          existing.copyWith(
            state: SuggestionState.visible,
            violationCount: violationCount,
            updatedAtMs: nowMs,
            clearSnooze: true,
            reasonCodes: const <String>{
              SuggestionReasonCodes.thresholdReached,
            },
          ),
          base: existing,
        );

      case SuggestionState.candidate:
      case SuggestionState.visible:
      case SuggestionState.invalidated:
        if (!meetsThreshold) {
          if (existing.state == SuggestionState.invalidated &&
              existing.violationCount == violationCount) {
            return existing;
          }
          return _write(
            existing.copyWith(
              state: SuggestionState.invalidated,
              violationCount: violationCount,
              updatedAtMs: nowMs,
              reasonCodes: const <String>{SuggestionReasonCodes.thresholdLost},
            ),
            base: existing,
          );
        }
        // Counts hold up. An invalidated suggestion is revived as a *candidate*
        // — recovery must not bypass the presentation step, or a suggestion the
        // user already dismissed would pop back on screen by itself.
        final revived = existing.state == SuggestionState.invalidated;
        final settled = existing.copyWith(
          state: revived ? SuggestionState.candidate : null,
          violationCount: violationCount,
          updatedAtMs: nowMs,
          threshold: _policy.threshold,
          windowDays: _policy.windowDays,
          reasonCodes: revived
              ? const <String>{SuggestionReasonCodes.thresholdReached}
              : existing.reasonCodes,
        );
        if (settled == existing) {
          return existing;
        }
        return _write(settled, base: existing);
    }
  }

  /// Reconciles every author in [counts] (author uid -> attributable count) in
  /// one pass. Used after a corrections batch.
  Future<List<BlacklistSuggestion>> reconcileAll(
    Map<String, int> counts,
  ) async {
    final settled = <BlacklistSuggestion>[];
    final authors = counts.keys.toList()..sort();
    for (final author in authors) {
      final suggestion = await reconcile(
        authorUid: author,
        violationCount: counts[author] ?? 0,
      );
      if (suggestion != null) {
        settled.add(suggestion);
      }
    }
    return List<BlacklistSuggestion>.unmodifiable(settled);
  }

  /// Moves a [SuggestionState.candidate] to [SuggestionState.visible].
  ///
  /// Candidate is "qualifies, not shown yet"; visible is "on screen". Keeping
  /// the two apart is what lets a caller decide *when* to interrupt the reader
  /// without re-deriving whether the suggestion is justified.
  Future<BlacklistSuggestion?> present(String authorSuggestionId) =>
      _serialized(authorSuggestionId, () => _presentLocked(authorSuggestionId));

  Future<BlacklistSuggestion?> _presentLocked(String authorSuggestionId) async {
    final base = _baseOf(authorSuggestionId);
    if (!base.writable) {
      return base.value;
    }
    final existing = base.value;
    if (existing == null || existing.state != SuggestionState.candidate) {
      return existing;
    }
    if (existing.violationCount < _policy.threshold) {
      return _reconcileLocked(
        author: existing.authorUid,
        id: authorSuggestionId,
        violationCount: existing.violationCount,
      );
    }
    return _write(
      existing.copyWith(
        state: SuggestionState.visible,
        updatedAtMs: _nowMs(),
      ),
      base: existing,
    );
  }

  /// Accepts the suggestion addressed by [authorSuggestionId].
  ///
  /// One call covers every anchor of that author: the state is stored once per
  /// author suggestion id, so all cards disappear together.
  Future<BlacklistSuggestion?> accept(
    String authorSuggestionId, {
    String decidedBy = decidedByUser,
  }) => _decide(
    authorSuggestionId,
    SuggestionState.accepted,
    decidedBy: decidedBy,
  );

  /// Accepts by anchor — the broadcast entry point a card actually calls.
  Future<BlacklistSuggestion?> acceptAnchor(
    SuggestionAnchor anchor, {
    String decidedBy = decidedByUser,
  }) => accept(anchorSuggestionId(anchor), decidedBy: decidedBy);

  /// Rejects ("never suggest this author again"). Persists across restart and
  /// suppresses new candidates until [reset].
  Future<BlacklistSuggestion?> reject(
    String authorSuggestionId, {
    String decidedBy = decidedByUser,
  }) => _decide(
    authorSuggestionId,
    SuggestionState.rejected,
    decidedBy: decidedBy,
    reasonCodes: const <String>{SuggestionReasonCodes.previouslyRejected},
  );

  /// Rejects by anchor — the broadcast entry point a card actually calls.
  Future<BlacklistSuggestion?> rejectAnchor(
    SuggestionAnchor anchor, {
    String decidedBy = decidedByUser,
  }) => reject(anchorSuggestionId(anchor), decidedBy: decidedBy);

  /// Snoozes [authorSuggestionId] for the configured cooldown.
  ///
  /// Semantically distinct from [reject]: it expires on its own, and the state
  /// stays [SuggestionState.snoozed] rather than [SuggestionState.rejected], so a
  /// caller can tell "not now" from "never".
  Future<BlacklistSuggestion?> snooze(
    String authorSuggestionId, {
    String decidedBy = decidedByUser,
  }) => _serialized(
    authorSuggestionId,
    () => _snoozeLocked(authorSuggestionId, decidedBy: decidedBy),
  );

  Future<BlacklistSuggestion?> _snoozeLocked(
    String authorSuggestionId, {
    required String decidedBy,
  }) async {
    final base = _baseOf(authorSuggestionId);
    if (!base.writable) {
      return base.value;
    }
    final existing = base.value;
    if (existing == null || existing.state.isTerminalDecision) {
      // Snoozing a decided suggestion would silently un-decide it where a stale
      // instance still believes it is on screen.
      return existing;
    }
    final nowMs = _nowMs();
    return _write(
      existing.copyWith(
        state: SuggestionState.snoozed,
        updatedAtMs: nowMs,
        snoozedUntilMs: nowMs + _policy.snoozeCooldownMs.inMilliseconds,
        snoozeCount: existing.snoozeCount + 1,
        decidedAtMs: nowMs,
        decidedBy: decidedBy,
        reasonCodes: <String>{
          ...existing.reasonCodes,
          SuggestionReasonCodes.snoozed,
        },
      ),
      base: existing,
    );
  }

  /// Snoozes by anchor.
  Future<BlacklistSuggestion?> snoozeAnchor(
    SuggestionAnchor anchor, {
    String decidedBy = decidedByUser,
  }) => snooze(anchorSuggestionId(anchor), decidedBy: decidedBy);

  /// Undoes an [SuggestionState.accepted] state — the only path that may.
  Future<BlacklistSuggestion?> unaccept(String authorSuggestionId) =>
      _serialized(
        authorSuggestionId,
        () => _unacceptLocked(authorSuggestionId),
      );

  Future<BlacklistSuggestion?> _unacceptLocked(
    String authorSuggestionId,
  ) async {
    final base = _baseOf(authorSuggestionId);
    if (!base.writable) {
      return base.value;
    }
    final existing = base.value;
    if (existing == null || existing.state != SuggestionState.accepted) {
      return existing;
    }
    return _write(
      existing.copyWith(
        state: SuggestionState.candidate,
        updatedAtMs: _nowMs(),
        clearDecidedAt: true,
        clearDecidedBy: true,
      ),
      base: existing,
    );
  }

  /// Clears a [SuggestionState.rejected] (or snoozed, or invalidated) record so
  /// the author can be suggested again.
  ///
  /// This is the only way out of rejection: nothing else in this subsystem
  /// removes it, and the ledger deliberately cannot. It also clears a record the
  /// machine cannot decode, which is the escape hatch for a damaged store — a
  /// corrupt entry otherwise blocks every future suggestion for that author.
  Future<bool> reset(String authorSuggestionId) => _serialized(
    authorSuggestionId,
    () async {
      final id = StorageIdCodec.encode(authorSuggestionId);
      final existed = _repository.read(id) is! Miss<Map<String, Object?>>;
      _cache.remove(authorSuggestionId);
      if (existed) {
        await _repository.delete(id);
      }
      return existed;
    },
  );

  /// Whether a suggestion for [authorUid] is suppressed right now.
  bool isSuppressed(String authorUid) {
    final suggestion = forAuthor(authorUid);
    if (suggestion == null) {
      return false;
    }
    if (suggestion.state == SuggestionState.snoozed) {
      return suggestion.isSnoozedAt(_nowMs());
    }
    return suggestion.state.isSuppressing;
  }

  /// Applies stored state to every anchor of [index].
  ///
  /// Returns one decision per anchor: an author with fifty anchors makes fifty
  /// decisions that all read the same single record, which is how accept/reject
  /// reaches all of them at once.
  List<SuggestionRenderDecision> applyTo(SuggestionAnchorIndex index) {
    final nowMs = _nowMs();
    final decisions = <SuggestionRenderDecision>[];
    final resolved = <String, BlacklistSuggestion?>{};
    for (final anchor in index.inListOrder) {
      // One durable store read per author, not one per anchor: a burst of forty
      // comments by one author is still one record. Keyed by the durable id, so
      // every anchor of that author — whichever credential generation built it —
      // resolves to the same stored decision.
      final key = anchorSuggestionId(anchor);
      final suggestion = resolved.putIfAbsent(key, () => byId(key));
      final state = suggestion?.state ?? SuggestionState.candidate;
      var shouldRender = state == SuggestionState.visible;
      String? reasonCode;
      if (state == SuggestionState.snoozed &&
          suggestion != null &&
          suggestion.isSnoozedAt(nowMs)) {
        shouldRender = false;
        reasonCode = SuggestionReasonCodes.snoozed;
      } else if (state == SuggestionState.rejected) {
        reasonCode = SuggestionReasonCodes.previouslyRejected;
      } else if (state == SuggestionState.accepted) {
        reasonCode = SuggestionReasonCodes.alreadyBlacklisted;
      } else if (state == SuggestionState.invalidated) {
        reasonCode = SuggestionReasonCodes.thresholdLost;
      } else if (state == SuggestionState.candidate) {
        reasonCode = SuggestionReasonCodes.thresholdReached;
      }
      decisions.add(
        SuggestionRenderDecision(
          anchor: anchor,
          state: state,
          shouldRender: shouldRender,
          suggestion: suggestion,
          reasonCode: reasonCode,
        ),
      );
    }
    return List<SuggestionRenderDecision>.unmodifiable(decisions);
  }

  Future<BlacklistSuggestion?> _decide(
    String authorSuggestionId,
    SuggestionState state, {
    required String decidedBy,
    Set<String> reasonCodes = const <String>{},
  }) => _serialized(
    authorSuggestionId,
    () => _decideLocked(
      authorSuggestionId,
      state,
      decidedBy: decidedBy,
      reasonCodes: reasonCodes,
    ),
  );

  Future<BlacklistSuggestion?> _decideLocked(
    String authorSuggestionId,
    SuggestionState state, {
    required String decidedBy,
    required Set<String> reasonCodes,
  }) async {
    final base = _baseOf(authorSuggestionId);
    final existing = base.value;
    if (existing == null) {
      return null;
    }
    if (existing.state == state) {
      return existing;
    }
    if (!base.writable) {
      // A record that cannot be decoded carries an author and a state, so a user
      // decision is still addressable and is written: the user is stating the
      // state they want now, which cannot resurrect anything. What must not be
      // written is an automatic transition, and those refuse above.
      _cache.remove(authorSuggestionId);
    }
    final nowMs = _nowMs();
    return _write(
      existing.copyWith(
        state: state,
        updatedAtMs: nowMs,
        decidedAtMs: nowMs,
        decidedBy: decidedBy,
        clearSnooze: true,
        reasonCodes: <String>{...existing.reasonCodes, ...reasonCodes},
      ),
      base: existing,
    );
  }
}
