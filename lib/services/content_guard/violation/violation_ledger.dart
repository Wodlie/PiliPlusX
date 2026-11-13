/// Idempotent violation accounting (spec section 7).
///
/// ## The invariant
///
/// One [ViolationKey] — account scope plus comment id — is **one** entry, so one
/// comment can raise its author's violation count **once**, no matter how many
/// operators matched it, how often `evaluate()` ran, how many times the decision
/// cache was read, or how many times the page was rebuilt. Repeat sightings
/// merge their reason codes, rule ids, operator ids and evidence into the
/// existing entry and are reported as [ViolationRecordOutcome.duplicate]; the
/// count cannot move because the count is *the number of entries*, not a tally.
///
/// ## What the ledger refuses to do
///
/// * It never derives an author. [ViolationAttribution.authorUid] is platform
///   data handed in by the caller; a null or blank uid is
///   [ViolationRecordOutcome.rejectedNoAuthor] and stores nothing.
/// * It never counts a filter hit as an author violation. When
///   [ViolationAttribution.attributeViolation] is false the sighting is stored as
///   evidence and counts for nothing (spec section 7.1: filtering is not
///   attribution).
/// * It never turns an unusable stored value into a clean pass. A correction
///   that cannot be decoded is [ViolationRecordOutcome.rejectedCorruptStorage]:
///   the ledger refuses to write rather than guess the comment was never
///   corrected.
/// * It knows nothing about blacklist suggestions. Whether a suggestion exists,
///   was rejected, is snoozed or was accepted manually belongs to the suggestion
///   machine; the ledger only answers "how many attributable violations does this
///   author have inside this window".
///
/// ## Corrections are durable, not deletions
///
/// [revoke] replaces the entry with a [ViolationCorrection] tombstone. The
/// corrected comment stays suppressed — for its own version and for any later
/// one — until [reset] lifts the correction deliberately. The version policy is
/// written down once, on [ViolationCorrection].
///
/// ## Windows follow the occurrence
///
/// Eligibility is measured from when the violation *happened*
/// ([ViolationRecord.occurredAtMs], stamped once). [ViolationRecord.lastSeenAtMs]
/// is audit metadata: re-reading a 31-day-old comment today must not renew it
/// into a 30-day window.
///
/// ## Concurrency
///
/// [record], [revoke], [revokeAuthor], [reset] and [resetAuthor] are
/// read-modify-write sequences over an interface whose reads are synchronous and
/// whose writes are asynchronous ([KeyValueStore]). Two callers of *different*
/// ledger instances — the common case, since a page builds one and a service
/// builds another — would otherwise interleave read/read/write/write and produce
/// two inserts for one comment, or lose a merge. Every mutation of a comment id
/// is therefore queued behind the previous mutation of the same id in this
/// process, through a queue keyed by comment id and shared by all instances.
///
/// ## Which identity owns a record
///
/// Everything persisted is namespaced by [durableScopeId] — the account's
/// persistence identity — because an accusation the user already corrected must
/// not reappear when they re-login or rotate a key. The **request** scope id
/// ([AccountScope.id]) stays out of storage entirely; it belongs to the
/// transient pipeline, bridge, presenter store and trace layers, where a
/// credential rotation genuinely must invalidate what was cached.
library;

import 'dart:async';

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/storage/json_repository.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_record.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_repository.dart';

/// One ledger operation, in the shape a caller can log without touching the
/// store again.
final class ViolationLedgerResult {
  const ViolationLedgerResult({
    required this.outcome,
    required this.commentId,
    this.record,
    this.currentCount,
    this.correction,
  });

  final ViolationRecordOutcome outcome;

  final String commentId;

  /// The stored entry after this operation; null when nothing was stored.
  final ViolationRecord? record;

  /// The author's attributable violation count inside the default window after
  /// this operation; null when no author was usable.
  final int? currentCount;

  /// The tombstone that refused this call, when [isSuppressed].
  final ViolationCorrection? correction;

  /// Whether this operation produced a counting entry.
  bool get counts => outcome.counts;

  /// Whether a stored correction refused this sighting.
  bool get isSuppressed => outcome.isSuppressed;

  @override
  String toString() =>
      'ViolationLedgerResult($commentId, ${outcome.wireName}, '
      'count: ${currentCount ?? 'n/a'})';
}

/// Account-scoped violation ledger.
///
/// Persistence goes through [ViolationRepository] and
/// [ViolationCorrectionRepository], so a ledger built on fresh repositories over
/// the same store sees exactly the same entries **and** the same corrections —
/// that is what makes "restart" and "second instance" meaningful in the checks.
final class ViolationLedger {
  /// Creates a ledger over [store], scoped to [account].
  ViolationLedger(
    KeyValueStore store, {
    required AccountScope account,
    int Function()? nowMs,
    this.defaultWindowDays = ViolationLedger.defaultWindowDaysValue,
  }) : durableScopeId = account.durableId,
       requestScopeId = account.id,
       _nowMs = nowMs ?? _systemNowMs,
       _repository = ViolationRepository(store, account: account, nowMs: nowMs),
       _corrections = ViolationCorrectionRepository(
         store,
         account: account,
         nowMs: nowMs,
       );

  /// Window [countFor] uses when the caller does not pass one.
  static const int defaultWindowDaysValue = 30;

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Process-wide queue tail per comment id, shared by every ledger instance.
  ///
  /// Static on purpose: serializing only helps if two ledgers over the same
  /// store share the queue. That the queue is in-process is the faithfulness
  /// limit of the generic [KeyValueStore] contract: two isolates, or two
  /// processes, over one box are not serialized here and the interface offers no
  /// primitive to do it.
  static final Map<String, Future<void>> _queues = <String, Future<void>>{};

  /// Durable namespace of every record, correction and queue entry of this
  /// ledger.
  ///
  /// Stable for one logged-in account across credential, device and platform
  /// rotation, and equal to the request scope id for a guest (which has no
  /// verifiable mid) so anonymous sessions stay isolated from each other.
  final String durableScopeId;

  /// Credential-generation scope this ledger was built under.
  ///
  /// Kept for provenance and for callers that report which account generation is
  /// live. It deliberately takes no part in any key: that is the whole fix.
  final String requestScopeId;

  /// Alias of [durableScopeId] — the namespace a stored [ViolationKey] carries.
  String get accountScopeId => durableScopeId;

  /// Window the per-record [ViolationLedgerResult] count is computed over.
  final int defaultWindowDays;

  final int Function() _nowMs;
  final ViolationRepository _repository;
  final ViolationCorrectionRepository _corrections;

  /// Queue key of [commentId] in this account's durable namespace.
  ///
  /// The namespace is part of the key because two accounts may hold the same
  /// comment id, and those two mutations are genuinely independent. It is the
  /// durable one so that a rotation does not open a second, unsynchronized queue
  /// for the same stored record.
  String _queueKeyOf(String commentId) => '$durableScopeId\u0000$commentId';

  /// Records one attribution.
  ///
  /// Idempotency is enforced by [ViolationKey] alone: a second call for the same
  /// comment merges and returns [ViolationRecordOutcome.duplicate], whatever the
  /// second call's verdicts, surface or timestamp were.
  ///
  /// A comment whose correction still stands is refused instead —
  /// [ViolationRecordOutcome.suppressedByCorrection] for the corrected version,
  /// [ViolationRecordOutcome.suppressedNewVersion] for a different one — until
  /// [reset] lifts the correction.
  Future<ViolationLedgerResult> record(ViolationAttribution attribution) {
    final authorUid = attribution.authorUid?.trim();
    if (!isUsableAuthorUid(authorUid)) {
      return Future<ViolationLedgerResult>.value(
        ViolationLedgerResult(
          outcome: ViolationRecordOutcome.rejectedNoAuthor,
          commentId: attribution.commentId,
        ),
      );
    }
    return _serialized(
      attribution.commentId,
      () => _recordLocked(attribution, authorUid!),
    );
  }

  Future<ViolationLedgerResult> _recordLocked(
    ViolationAttribution attribution,
    String authorUid,
  ) async {
    final nowMs = _nowMs();
    final commentId = attribution.commentId;
    final key = ViolationKey(
      accountScopeId: accountScopeId,
      commentId: commentId,
    );

    // A correction that cannot be decoded is not "no correction": writing then
    // would recreate the accusation the user already dismissed. Refuse instead.
    final correctionResult = _corrections.read(commentId);
    if (correctionResult is Corrupt<ViolationCorrection>) {
      return ViolationLedgerResult(
        outcome: ViolationRecordOutcome.rejectedCorruptStorage,
        commentId: commentId,
      );
    }
    final correction = correctionResult.valueOrNull;
    if (correction != null) {
      // The tombstone decides; see [ViolationCorrection] for the policy. An edit
      // is reported distinctly but never silently lifts a human correction.
      return ViolationLedgerResult(
        outcome: correction.correctsVersion(attribution.contentVersion)
            ? ViolationRecordOutcome.suppressedByCorrection
            : ViolationRecordOutcome.suppressedNewVersion,
        commentId: commentId,
        correction: correction,
        currentCount: countFor(authorUid, windowDays: defaultWindowDays),
      );
    }

    // A corrupt entry is not silently overwritten: dropping it would erase an
    // accusation the user may already have acted on. The caller gets a fresh
    // insert only when nothing usable is there, and a corrupt value is repaired
    // by that insert — which is the same single entry, not a second one.
    final existing = _repository.read(commentId).valueOrNull;

    if (existing == null) {
      final created = ViolationRecord(
        key: key,
        authorUid: authorUid,
        firstSeenAtMs: attribution.observedAtMs ?? nowMs,
        lastSeenAtMs: attribution.observedAtMs ?? nowMs,
        attributeEligible: attribution.attributeViolation,
        contentVersion: attribution.contentVersion,
        surface: attribution.surface,
        reasonCodes: Set<String>.unmodifiable(attribution.reasonCodes),
        ruleIds: Set<String>.unmodifiable(attribution.ruleIds),
        operatorIds: Set<String>.unmodifiable(attribution.operatorIds),
        evidence: dedupeEvidence(attribution.evidence),
      );
      await _repository.write(created);
      return ViolationLedgerResult(
        outcome: created.attributeEligible
            ? ViolationRecordOutcome.inserted
            : ViolationRecordOutcome.recordedAsEvidence,
        commentId: commentId,
        record: created,
        currentCount: countFor(authorUid, windowDays: defaultWindowDays),
      );
    }

    final merged = existing.mergedWith(attribution, nowMs: nowMs);
    if (merged != existing) {
      await _repository.write(merged);
    }
    return ViolationLedgerResult(
      outcome: merged.attributeEligible
          ? ViolationRecordOutcome.duplicate
          : ViolationRecordOutcome.duplicateEvidence,
      commentId: commentId,
      record: merged,
      currentCount: countFor(authorUid, windowDays: defaultWindowDays),
    );
  }

  /// Records several attributions, oldest-safe order irrelevant: each is
  /// idempotent on its own, so batching cannot double count either.
  Future<List<ViolationLedgerResult>> recordAll(
    Iterable<ViolationAttribution> attributions,
  ) async {
    final results = <ViolationLedgerResult>[];
    for (final attribution in attributions) {
      results.add(await record(attribution));
    }
    return results;
  }

  /// Corrects [commentId]: the entry stops counting and a [ViolationCorrection]
  /// tombstone takes its place.
  ///
  /// Returns whether an entry was there to revoke. Revoking an
  /// already-corrected comment refreshes the tombstone (keeping the original
  /// occurrence, version and author for audit) and returns false.
  ///
  /// The tombstone is written *before* the entry is deleted, so an interrupted
  /// revoke leaves "corrected but still listed" — a state the read path already
  /// suppresses — instead of "deleted and forgotten", which the next evaluate()
  /// would recreate.
  Future<bool> revoke(
    String commentId, {
    String? reasonCode,
    int? revokedAtMs,
  }) => _serialized(commentId, () async {
    final nowMs = _nowMs();
    final key = ViolationKey(
      accountScopeId: accountScopeId,
      commentId: commentId,
    );
    final correctionResult = _corrections.read(commentId);
    final priorCorrection = correctionResult is Corrupt<ViolationCorrection>
        ? null
        : correctionResult.valueOrNull;
    final existing = _repository.read(commentId).valueOrNull;
    if (existing == null &&
        priorCorrection == null &&
        correctionResult is! Corrupt<ViolationCorrection>) {
      return false;
    }
    final correction = (priorCorrection ?? ViolationCorrection(key: key))
        .mergedWith(
          ViolationCorrection(
            key: key,
            eventTimestampMs: existing?.occurredAtMs,
            revokedAtMs: revokedAtMs ?? nowMs,
            contentVersion: existing?.contentVersion,
            reasonCode: reasonCode,
            previousAuthorUid: existing?.authorUid,
            previousReasonCodes: existing?.reasonCodes ?? const <String>{},
          ),
        );
    await _corrections.write(correction);
    if (existing != null) {
      await _repository.delete(commentId);
    }
    return existing != null;
  });

  /// Lifts the correction of [commentId], so a deliberate re-evaluation may
  /// record it again.
  ///
  /// Returns whether a correction was lifted. This is the **only** way a
  /// tombstone goes away: no later sighting — not a different content version,
  /// not a higher-severity verdict, not a page rebuild — clears one on its own.
  /// The revoked entry itself was deleted by [revoke], so the next insertion
  /// stamps a fresh occurrence and cannot renew the old one into a window.
  Future<bool> reset(String commentId) => _serialized(commentId, () async {
    final stored = _corrections.read(commentId);
    if (stored is Miss<ViolationCorrection>) {
      return false;
    }
    // Ok or Corrupt: something is stored under this key, so there is a
    // correction to lift. A corrupt tombstone must be removable, otherwise a
    // damaged store would freeze a comment as corrected forever.
    await _corrections.delete(commentId);
    return true;
  });

  /// Corrects every entry of [authorUid] inside [windowDays], returning how many
  /// entries were revoked.
  Future<int> revokeAuthor(String authorUid, {int? windowDays}) async {
    final window = windowDays ?? defaultWindowDays;
    final nowMs = _nowMs();
    final removed = <String>[];
    for (final record in _storedRecords()) {
      if (record.authorUid != authorUid ||
          !record.isWithinWindow(nowMs: nowMs, windowDays: window)) {
        continue;
      }
      removed.add(record.commentId);
    }
    for (final commentId in removed) {
      await revoke(commentId);
    }
    return removed.length;
  }

  /// Lifts every correction recorded against [authorUid], returning how many
  /// were lifted.
  ///
  /// Keyed by the tombstone's own audit author, so a whole author can be
  /// re-evaluated deliberately as one batch.
  Future<int> resetAuthor(String authorUid) async {
    final targets = <String>[
      for (final correction in _corrections.list())
        if (correction.previousAuthorUid == authorUid) correction.commentId,
    ];
    var lifted = 0;
    for (final commentId in targets) {
      if (await reset(commentId)) {
        lifted++;
      }
    }
    return lifted;
  }

  /// How many *attributable* violations [authorUid] has inside [windowDays],
  /// measured from each entry's **occurrence** — never from when it was last
  /// read.
  ///
  /// Evidence-only entries never contribute, which is the whole point of keeping
  /// them: the user can still see "this author posted three flagged comments"
  /// without the count ever accusing anyone on media evidence alone.
  int countFor(String authorUid, {int? windowDays}) => _countFor(
    authorUid,
    windowDays: windowDays ?? defaultWindowDays,
    attributable: true,
  );

  /// How many *evidence-only* entries [authorUid] has inside [windowDays].
  ///
  /// Exposed separately so a caller never has to subtract one query from
  /// another to learn what was filtered without being attributed.
  int evidenceCountFor(String authorUid, {int? windowDays}) => _countFor(
    authorUid,
    windowDays: windowDays ?? defaultWindowDays,
    attributable: false,
  );

  int _countFor(
    String authorUid, {
    required int windowDays,
    required bool attributable,
  }) {
    final nowMs = _nowMs();
    var count = 0;
    for (final record in _storedRecords()) {
      if (record.authorUid != authorUid ||
          record.countsAsViolation != attributable) {
        continue;
      }
      if (!record.isWithinWindow(nowMs: nowMs, windowDays: windowDays)) {
        continue;
      }
      count++;
    }
    return count;
  }

  /// Every stored entry of [authorUid], newest sighting first.
  List<ViolationRecord> recordsFor(String authorUid) {
    final records = <ViolationRecord>[
      for (final record in _storedRecords())
        if (record.authorUid == authorUid) record,
    ];
    records.sort((a, b) {
      final byTime = b.lastSeenAtMs.compareTo(a.lastSeenAtMs);
      return byTime != 0 ? byTime : a.commentId.compareTo(b.commentId);
    });
    return List<ViolationRecord>.unmodifiable(records);
  }

  /// The stored entry of [commentId], or null — also null when the comment is
  /// corrected, because a corrected comment is not an entry any more.
  ViolationRecord? lookup(String commentId) => _liveRecordOf(commentId);

  /// The correction of [commentId], or null when it was never corrected.
  ViolationCorrection? correctionFor(String commentId) =>
      _corrections.read(commentId).valueOrNull;

  /// Every correction in this account scope, ordered by comment id.
  List<ViolationCorrection> corrections() => _corrections.list();

  /// Every stored entry in this account scope, ordered by comment id.
  List<ViolationRecord> allRecords() => _storedRecords();

  List<ViolationRecord> _storedRecords() {
    final records = <ViolationRecord>[];
    for (final commentId in _repository.commentIds()) {
      final record = _liveRecordOf(commentId);
      if (record != null) {
        records.add(record);
      }
    }
    return records;
  }

  /// The live entry of [commentId], correction first.
  ///
  /// Correction first is deliberate: [revoke] writes the tombstone before it
  /// deletes the entry, so an interrupted revoke leaves both on disk. Letting
  /// the tombstone win makes that state suppressed — the user's correction
  /// outranks the leftover entry — without a repair write on the read path.
  ///
  /// A tombstone that cannot be decoded also wins: read as "never corrected" it
  /// would put a dismissed accusation back into a count.
  ViolationRecord? _liveRecordOf(String commentId) {
    final correctionResult = _corrections.read(commentId);
    if (correctionResult.valueOrNull != null ||
        correctionResult is Corrupt<ViolationCorrection>) {
      return null;
    }
    return _repository.read(commentId).valueOrNull;
  }

  /// Runs [action] after every earlier mutation of [commentId] in this process
  /// has finished.
  ///
  /// See the library doc: without this, two ledger instances over one store can
  /// both read "absent" and both write, producing two inserted outcomes.
  Future<T> _serialized<T>(
    String commentId,
    Future<T> Function() action,
  ) async {
    final queueKey = _queueKeyOf(commentId);
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
}
