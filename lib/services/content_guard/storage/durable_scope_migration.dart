/// One-shot, idempotent migration of credential-scoped ContentGuard state into
/// the durable per-account namespace.
///
/// ## Why this exists
///
/// Before request identity and persistence identity were split, every stored
/// artifact was namespaced by `AccountScope.id` — a digest of mid **plus** access
/// key, cookie digest, device digest, buvid and mobiApp. Rotating any of those
/// produced a new namespace and left the previous one unreachable: accepted or
/// rejected suggestions, corrections, violations and local manual choices looked
/// as if they had been reset.
///
/// Durable state now lives under `AccountScope.durableId` (a digest of the mid
/// alone). This file moves what the **current** account can prove is its own out
/// of the old credential namespaces and into that one.
///
/// ## What may be migrated (ownership proof)
///
/// Only namespaces whose ownership is established without guessing:
///
/// * the current request scope id ([AccountScope.id]) — the credential
///   generation in force right now, which by construction belongs to the account
///   holding it; and
/// * namespaces the caller explicitly passes in `trustedLegacyScopeIds` (a
///   restored local record, or a scope id recovered from another trusted source).
///
/// Everything else is **reported, never touched**. A legacy `cgs1_*` digest of
/// an unknown older credential generation cannot be reversed into a mid, and
/// enumerating every such namespace in the box would be exactly the "guess who
/// owns this" step that merges two users' state. Those ids are listed in
/// [DurableScopeMigrationReport.unrecoverableScopeIds] and left alone. A
/// `cgd1_*` namespace belonging to a *different* account is listed in
/// [DurableScopeMigrationReport.refusedScopeIds] and refused in both directions.
///
/// ## Ordering, merging and failure behaviour
///
/// For every migrated key, in this order:
///
/// 1. **Read** the legacy value. A value that is not a decodable payload of the
///    expected domain/version is skipped and left in place — a damaged source may
///    not erase a valid destination.
/// 2. **Adopt** it: the embedded account scope id is rewritten to the durable
///    identity, and a suggestion's author suggestion id is re-minted under that
///    scope so the anchors of its author can find it again.
/// 3. **Merge** into whatever the destination already holds, per domain:
///    * violations keep the **earliest** occurrence, the latest sighting, the
///      union of reason/rule/operator ids and evidence, and stay attributable if
///      either side was — so a migrated record can never renew an old sighting
///      into a fresh window, and can never lose an accusation;
///    * corrections merge through [ViolationCorrection.mergedWith], which keeps
///      the earliest occurrence and the latest revoke;
///    * suggestions merge through [BlacklistSuggestion.resolveAgainst], the same
///      rule the machine uses everywhere else: the higher revision wins, and at
///      equal revision a terminal user decision wins. A migrated rejection or
///      acceptance therefore cannot be replaced by an older automatic reading,
///      and no revision ever moves backwards.
/// 4. **Write** the destination and *await it*. Nothing is deleted before that
///    await returns; a failed write leaves the source intact, so a retry — or the
///    next app start — simply tries again.
/// 5. **Delete** the source key, and only then.
///
/// Because every step is a merge of the legacy reading with the durable one,
/// running this twice is the same as running it once: the second pass finds no
/// legacy keys left, and a pass interrupted halfway leaves a source the next pass
/// merges again with an identical result. Corrections are migrated before the
/// records they suppress, so an interrupted pass reads as "corrected" rather than
/// "accusing".
///
/// ## What this cannot do
///
/// [KeyValueStore] offers no compare-and-swap, so two isolates running this
/// migration at the same instant are not serialized against each other. The merge
/// rules make the outcome identical either way, but that is convergence, not
/// atomicity, and this file does not claim atomicity.
library;

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/storage/content_guard_storage_keys.dart';
import 'package:PiliPlus/services/content_guard/storage/json_repository.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_anchor.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_record.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_repository.dart';

/// What one [DurableScopeMigration.run] did, and what it refused to do.
final class DurableScopeMigrationReport {
  const DurableScopeMigrationReport({
    required this.durableScopeId,
    required this.isApplicable,
    required this.legacyScopeIds,
    required this.unrecoverableScopeIds,
    required this.refusedScopeIds,
    required this.skippedUnreadable,
    required this.staleSources,
    required this.failures,
    required this.inserted,
    required this.merged,
    required this.deletedSourceKeys,
  });

  /// Namespace the migration wrote into.
  final String durableScopeId;

  /// Whether the account had a real durable identity to migrate into.
  ///
  /// False for a guest or a hand-built scope, where the durable identity *is* the
  /// request identity and there is nothing to move.
  final bool isApplicable;

  /// Proven legacy namespaces that were visited.
  final List<String> legacyScopeIds;

  /// Credential-scoped namespaces found in the box that cannot be proved to
  /// belong to this account.
  ///
  /// **These are not migrated and never guessed at.** A `cgs1_*` digest of an
  /// older credential generation is one-way; matching it to a mid would require
  /// reversing SHA-256 or enumerating every account's namespaces. The state
  /// inside is therefore reported as unrecoverable rather than attributed.
  final List<String> unrecoverableScopeIds;

  /// Durable namespaces in the box that belong to a *different* account, so
  /// migrating them would move another user's state. Refused in both directions.
  final List<String> refusedScopeIds;

  /// Legacy keys that exist but could not be decoded; left untouched.
  final List<String> skippedUnreadable;

  /// Legacy keys whose destination write succeeded but whose source delete
  /// failed. The state is safe in the durable namespace; the leftover source is
  /// re-merged identically on the next pass.
  final List<String> staleSources;

  /// Keys whose destination write threw. Their source is still present.
  final List<String> failures;

  /// Per-domain counts, keyed by storage domain.
  final Map<String, int> inserted;
  final Map<String, int> merged;

  /// Number of legacy keys removed after a successful destination write.
  final int deletedSourceKeys;

  /// Whether every visited legacy key was either migrated or deliberately
  /// skipped as unreadable, with no write failure and no leftover source.
  bool get isClean => failures.isEmpty && staleSources.isEmpty;

  /// One-line summary safe for a diagnostic surface: no key bodies, no
  /// credentials.
  @override
  String toString() =>
      'DurableScopeMigrationReport(durable: $durableScopeId, '
      'applicable: $isApplicable, legacy: ${legacyScopeIds.length}, '
      'unrecoverable: ${unrecoverableScopeIds.length}, '
      'refused: ${refusedScopeIds.length}, '
      'inserted: ${inserted.values.fold<int>(0, (a, b) => a + b)}, '
      'merged: ${merged.values.fold<int>(0, (a, b) => a + b)}, '
      'deleted: $deletedSourceKeys, skipped: ${skippedUnreadable.length}, '
      'stale: ${staleSources.length}, failures: ${failures.length})';
}

/// Merges proven credential-scoped state into the durable account namespace.
final class DurableScopeMigration {
  DurableScopeMigration(
    KeyValueStore store, {
    required AccountScope account,
    Iterable<String> trustedLegacyScopeIds = const <String>[],
    int Function()? nowMs,
    this.schemaVersion = 1,
  }) : _store = store,
       _account = account,
       _trustedLegacyScopeIds = List<String>.unmodifiable(
         trustedLegacyScopeIds,
       ),
       _nowMs = nowMs;

  /// Domains that hold durable per-account state, in migration order.
  ///
  /// Corrections come before records so a corrected comment's tombstone exists
  /// before the entry it suppresses is moved; an interrupted pass then reads as
  /// "corrected" rather than "accusing".
  static const List<String> domains = <String>[
    ViolationCorrectionRepository.domain,
    ContentGuardStorageKeys.violations,
    ContentGuardStorageKeys.suggestions,
  ];

  final KeyValueStore _store;
  final AccountScope _account;
  final List<String> _trustedLegacyScopeIds;
  final int Function()? _nowMs;

  /// Schema version new writes carry; a legacy payload of another version is a
  /// [Miss] rather than something to resurrect, exactly as [JsonRepository]
  /// treats it.
  final int schemaVersion;

  /// Durable namespace this migration targets.
  String get durableScopeId => _account.durableId;

  /// Runs the migration. Safe to call on every start: a box with nothing left to
  /// move returns a report with zero work.
  Future<DurableScopeMigrationReport> run() async {
    if (!_account.hasStableDurableId) {
      // Guests and hand-built scopes keep the credential namespace: there is no
      // stable owner to move anything to, and merging guests together would
      // attach one anonymous session's decisions to another's.
      return DurableScopeMigrationReport(
        durableScopeId: durableScopeId,
        isApplicable: false,
        legacyScopeIds: const <String>[],
        unrecoverableScopeIds: const <String>[],
        refusedScopeIds: const <String>[],
        skippedUnreadable: const <String>[],
        staleSources: const <String>[],
        failures: const <String>[],
        inserted: const <String, int>{},
        merged: const <String, int>{},
        deletedSourceKeys: 0,
      );
    }

    final inserted = <String, int>{};
    final merged = <String, int>{};
    final skippedUnreadable = <String>[];
    final staleSources = <String>[];
    final failures = <String>[];
    var deleted = 0;

    final proven = _provenLegacyScopes();
    final foreign = _foreignDurableScopes();

    for (final domain in domains) {
      for (final sourceScope in proven) {
        if (sourceScope == durableScopeId) {
          continue; // already the destination
        }
        final source = JsonRepository(
          _store,
          domain: domain,
          accountScopeId: sourceScope,
          schemaVersion: schemaVersion,
          nowMs: _nowMs,
        );
        final target = JsonRepository(
          _store,
          domain: domain,
          accountScopeId: durableScopeId,
          schemaVersion: schemaVersion,
          nowMs: _nowMs,
        );
        for (final id in source.ids()) {
          final result = await _migrateOne(
            domain: domain,
            sourceId: id,
            source: source,
            target: target,
          );
          switch (result.outcome) {
            case _MigrateOutcome.inserted:
              inserted[domain] = (inserted[domain] ?? 0) + 1;
              deleted++;
            case _MigrateOutcome.merged:
              merged[domain] = (merged[domain] ?? 0) + 1;
              deleted++;
            case _MigrateOutcome.skipped:
              skippedUnreadable.add('$domain/$id');
            case _MigrateOutcome.failed:
              failures.add('$domain/$id');
            case _MigrateOutcome.nothingToDo:
              break;
          }
          if (result.sourceDeleteFailed) {
            staleSources.add('$domain/$id');
          }
        }
      }
    }

    return DurableScopeMigrationReport(
      durableScopeId: durableScopeId,
      isApplicable: true,
      legacyScopeIds: proven,
      unrecoverableScopeIds: _unrecoverableScopes(proven, foreign),
      refusedScopeIds: foreign,
      skippedUnreadable: List<String>.unmodifiable(skippedUnreadable),
      staleSources: List<String>.unmodifiable(staleSources),
      failures: List<String>.unmodifiable(failures),
      inserted: Map<String, int>.unmodifiable(inserted),
      merged: Map<String, int>.unmodifiable(merged),
      deletedSourceKeys: deleted,
    );
  }

  /// Legacy namespaces this account can prove are its own.
  List<String> _provenLegacyScopes() {
    final result = <String>[];
    void add(String? value) {
      if (value == null || value.isEmpty || result.contains(value)) {
        return;
      }
      result.add(value);
    }

    // The credential generation in force right now is this account's own scope by
    // construction; it is the only legacy id that needs no external assertion.
    add(_account.requestScopeId);
    for (final scope in _trustedLegacyScopeIds) {
      add(scope);
    }
    return List<String>.unmodifiable(result);
  }

  /// Durable namespaces present in the box that belong to other accounts.
  List<String> _foreignDurableScopes() {
    final result = <String>[
      for (final scope in _scopesPresent())
        if (scope != durableScopeId &&
            scope.startsWith(AccountScope.durableIdPrefix))
          scope,
    ]..sort();
    return List<String>.unmodifiable(result);
  }

  /// Credential-scoped namespaces that are neither the durable one nor a proven
  /// source — reported, never attributed.
  List<String> _unrecoverableScopes(
    List<String> proven,
    List<String> foreign,
  ) {
    final result = <String>[
      for (final scope in _scopesPresent())
        if (scope != durableScopeId &&
            !proven.contains(scope) &&
            !foreign.contains(scope))
          scope,
    ]..sort();
    return List<String>.unmodifiable(result);
  }

  /// Every account-scope segment that appears under a migrated domain.
  Set<String> _scopesPresent() {
    final scopes = <String>{};
    for (final key in _store.keys()) {
      final scope = _scopeOfKey(key);
      if (scope != null) {
        scopes.add(scope);
      }
    }
    return scopes;
  }

  /// Scope segment of a key in a migrated domain, or null when [key] is not one.
  String? _scopeOfKey(String key) {
    for (final domain in domains) {
      final head =
          '${ContentGuardStorageKeys.root}'
          '${ContentGuardStorageKeys.separator}$domain'
          '${ContentGuardStorageKeys.separator}';
      if (!key.startsWith(head)) continue;
      final rest = key.substring(head.length);
      final dot = rest.indexOf(ContentGuardStorageKeys.separator);
      if (dot <= 0) continue;
      return rest.substring(0, dot);
    }
    return null;
  }

  /// Moves one legacy entry into the durable namespace.
  ///
  /// The ordering rules — read, adopt, merge, await the write, then delete — are
  /// documented once on the library.
  Future<({_MigrateOutcome outcome, bool sourceDeleteFailed})> _migrateOne({
    required String domain,
    required String sourceId,
    required JsonRepository source,
    required JsonRepository target,
  }) async {
    const done = (
      outcome: _MigrateOutcome.nothingToDo,
      sourceDeleteFailed: false,
    );

    final read = source.read(sourceId);
    if (read is Miss<Map<String, Object?>>) {
      return done;
    }
    if (read is! Ok<Map<String, Object?>>) {
      // Unreadable legacy value: leave it exactly where it is. Erasing it here
      // would trade "recoverable by a future build" for "gone".
      return (outcome: _MigrateOutcome.skipped, sourceDeleteFailed: false);
    }

    final candidate = _adopt(
      domain: domain,
      payload: JsonRepository.payloadOf(read.value),
      fromScope: source.accountScopeId,
    );
    if (candidate == null) {
      return (outcome: _MigrateOutcome.skipped, sourceDeleteFailed: false);
    }

    // The destination key is derived from the *adopted* value, not copied from
    // the legacy key: a suggestion's storage id encodes its author suggestion id,
    // and that id is re-minted under the durable scope.
    final targetId = _storageIdOf(domain: domain, value: candidate);

    Object next = candidate;
    var targetHadValue = false;
    final existing = target.read(targetId);
    if (existing is Ok<Map<String, Object?>>) {
      final current = _adopt(
        domain: domain,
        payload: JsonRepository.payloadOf(existing.value),
        fromScope: target.accountScopeId,
      );
      if (current != null) {
        targetHadValue = true;
        next = _merge(domain: domain, current: current, incoming: candidate);
      }
    }
    // A corrupt destination is replaced by the decodable source: the source is
    // the only usable reading left, and keeping the damaged value would block
    // the migration forever. A corrupt *source* never reaches this point.

    try {
      await target.write(targetId, _encode(domain: domain, value: next));
    } catch (_) {
      // Destination write failed: the source stays, and the next pass retries.
      return (outcome: _MigrateOutcome.failed, sourceDeleteFailed: false);
    }
    try {
      await source.delete(sourceId);
    } catch (_) {
      return (
        outcome: targetHadValue
            ? _MigrateOutcome.merged
            : _MigrateOutcome.inserted,
        sourceDeleteFailed: true,
      );
    }
    return (
      outcome: targetHadValue
          ? _MigrateOutcome.merged
          : _MigrateOutcome.inserted,
      sourceDeleteFailed: false,
    );
  }

  /// Decodes one stored payload and rewrites it into the durable scope.
  ///
  /// Returns null when the payload is not a decodable shape of its domain, which
  /// the caller reports as skipped rather than as migrated.
  Object? _adopt({
    required String domain,
    required Map<String, Object?> payload,
    required String fromScope,
  }) {
    final rewritten = <String, Object?>{
      for (final entry in payload.entries) entry.key: entry.value,
    }..['accountScopeId'] = durableScopeId;

    if (domain == ContentGuardStorageKeys.suggestions) {
      final suggestion = BlacklistSuggestion.fromJson(rewritten);
      if (suggestion == null) return null;
      // The author suggestion id embeds the scope it was minted under; re-minting
      // it under the durable scope is what lets every anchor of that author find
      // this record again after a credential rotation.
      return BlacklistSuggestion(
        authorSuggestionId: SuggestionRunKey.authorSuggestionIdOf(
          durableScopeId,
          suggestion.authorUid,
        ),
        authorUid: suggestion.authorUid,
        state: suggestion.state,
        violationCount: suggestion.violationCount,
        createdAtMs: suggestion.createdAtMs,
        updatedAtMs: suggestion.updatedAtMs,
        threshold: suggestion.threshold,
        windowDays: suggestion.windowDays,
        snoozedUntilMs: suggestion.snoozedUntilMs,
        snoozeCount: suggestion.snoozeCount,
        reasonCodes: suggestion.reasonCodes,
        decidedAtMs: suggestion.decidedAtMs,
        decidedBy: suggestion.decidedBy,
        revision: suggestion.revision,
      );
    }

    if (isCorrectionPayload(rewritten)) {
      return ViolationCorrection.fromJson(rewritten);
    }
    return ViolationRecord.fromJson(rewritten);
  }

  /// Storage id of an adopted value inside the durable namespace.
  String _storageIdOf({required String domain, required Object value}) {
    if (domain == ContentGuardStorageKeys.suggestions) {
      return StorageIdCodec.encode(
        (value as BlacklistSuggestion).authorSuggestionId,
      );
    }
    if (value is ViolationCorrection) {
      return StorageIdCodec.encode(value.commentId);
    }
    return StorageIdCodec.encode((value as ViolationRecord).commentId);
  }

  /// Merges a legacy reading into the durable one, per domain.
  Object _merge({
    required String domain,
    required Object current,
    required Object incoming,
  }) {
    if (domain == ContentGuardStorageKeys.suggestions) {
      // Same rule the machine uses everywhere: the higher revision is the later
      // write, and at equal revision a terminal user decision outranks an
      // automatic state.
      return (current as BlacklistSuggestion).resolveAgainst(
        incoming as BlacklistSuggestion,
      );
    }
    if (current is ViolationCorrection && incoming is ViolationCorrection) {
      return current.mergedWith(incoming);
    }
    if (current is ViolationRecord && incoming is ViolationRecord) {
      return _mergeRecords(current, incoming);
    }
    // A record and a tombstone cannot share a key inside one domain; keep the
    // durable reading rather than inventing a third shape.
    return current;
  }

  /// Unions two readings of one occurrence without moving its window.
  ///
  /// The occurrence ([ViolationRecord.occurredAtMs], the earliest sighting) can
  /// only move **earlier**, never later: a migrated entry must not renew a
  /// thirty-day-old accusation into a fresh window, and a later re-record must not
  /// hide the original occurrence either. That is what keeps first-occurrence
  /// window arithmetic unchanged across the migration.
  ViolationRecord _mergeRecords(ViolationRecord a, ViolationRecord b) {
    final evidence = <FilterEvidence>[...a.evidence];
    for (final item in b.evidence) {
      if (!evidence.contains(item)) {
        evidence.add(item);
      }
    }
    final first = a.firstSeenAtMs <= b.firstSeenAtMs
        ? a.firstSeenAtMs
        : b.firstSeenAtMs;
    final last = a.lastSeenAtMs >= b.lastSeenAtMs
        ? a.lastSeenAtMs
        : b.lastSeenAtMs;
    return ViolationRecord(
      key: a.key,
      authorUid: a.authorUid,
      contentVersion: a.contentVersion ?? b.contentVersion,
      firstSeenAtMs: first,
      lastSeenAtMs: last,
      attributeEligible: a.attributeEligible || b.attributeEligible,
      surface: a.surface ?? b.surface,
      reasonCodes: Set<String>.unmodifiable(<String>{
        ...a.reasonCodes,
        ...b.reasonCodes,
      }),
      ruleIds: Set<String>.unmodifiable(<String>{...a.ruleIds, ...b.ruleIds}),
      operatorIds: Set<String>.unmodifiable(<String>{
        ...a.operatorIds,
        ...b.operatorIds,
      }),
      evidence: List<FilterEvidence>.unmodifiable(evidence),
    );
  }

  Map<String, Object?> _encode({
    required String domain,
    required Object value,
  }) {
    if (domain == ContentGuardStorageKeys.suggestions) {
      return (value as BlacklistSuggestion).toJson();
    }
    if (value is ViolationCorrection) {
      return value.toJson();
    }
    return (value as ViolationRecord).toJson();
  }
}

/// What one legacy entry became.
enum _MigrateOutcome { inserted, merged, skipped, failed, nothingToDo }
