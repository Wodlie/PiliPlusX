/// One attributed violation, its identity, and the outcome of recording it.
///
/// The ledger's whole job is *idempotent accounting*: a comment is either in the
/// ledger or it is not, and every later sighting of the same comment merges into
/// that one entry (spec section 7). The types in this file are what makes that
/// shape expressible:
///
/// * [ViolationKey] is the accounting identity — account scope plus comment id.
///   Nothing else identifies a violation, so two surfaces that see the same
///   comment cannot double count it.
/// * [ViolationAttribution] is what the caller *observed*. It carries the author
///   uid the platform reported; the ledger never derives an author from a model
///   verdict, so a mislabelled AI hit can never accuse an account.
/// * [ViolationRecord] is what is stored: one entry per key, with every merged
///   reason code, rule id, operator id and piece of evidence, and with an
///   explicit [ViolationRecord.attributeEligible] flag that says whether this
///   entry may be counted against its author.
///
/// There is deliberately no per-record counter. A violation count is the number
/// of distinct ledger entries for an author inside a window
/// (`ViolationLedger.countFor`), never a tally that a repeated evaluate() call
/// could inflate.
library;

import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';

/// Accounting identity of one violation: the account scope plus the comment id.
///
/// The account scope is part of the key, not a namespace bolted on at the
/// storage edge, so the same comment id seen by two accounts is two records and
/// can never be merged across accounts.
final class ViolationKey {
  const ViolationKey({required this.accountScopeId, required this.commentId});

  /// Opaque account digest (`AccountScope.id`).
  final String accountScopeId;

  /// Platform comment/reply id. Never a model-generated id.
  final String commentId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ViolationKey &&
          accountScopeId == other.accountScopeId &&
          commentId == other.commentId;

  @override
  int get hashCode => Object.hash(accountScopeId, commentId);

  @override
  String toString() => 'ViolationKey($commentId)';
}

/// What `ViolationLedger.record` did with one attribution.
///
/// [inserted] is the only outcome that raises an author's violation count, and
/// it happens at most once per [ViolationKey]. Everything else either merges
/// into the existing entry ([duplicate], [duplicateEvidence]) or refuses to
/// record at all ([rejectedNoAuthor]).
enum ViolationRecordOutcome {
  /// The first *attributable* sighting of this comment. Counts.
  inserted,

  /// A repeat sighting of a comment that already counts. Merged; the count does
  /// not move.
  duplicate,

  /// The first sighting, stored as evidence only because the caller said the
  /// violation may not be attributed (spec section 7.1). Does not count.
  recordedAsEvidence,

  /// A repeat sighting of an evidence-only entry. Merged; still does not count.
  duplicateEvidence,

  /// A sighting of content whose version was corrected
  /// ([ViolationLedger.revoke]). Nothing is stored and nothing counts until a
  /// deliberate [ViolationLedger.reset] lifts the correction.
  suppressedByCorrection,

  /// A sighting of a *different* content version than the corrected one.
  ///
  /// The correction still stands — an edit is not a clean slate — but the
  /// outcome is distinct so a caller can tell "the content changed after you
  /// corrected it" apart from "nothing changed at all", and can lift the
  /// correction deliberately. [ViolationCorrection] states the whole policy.
  suppressedNewVersion,

  /// The correction stored for this comment cannot be decoded, so the ledger
  /// cannot tell whether recording would resurrect a dismissed accusation.
  ///
  /// Nothing was stored. This is a refusal, never a pass: an unusable tombstone
  /// must not be read as "never corrected".
  rejectedCorruptStorage,

  /// The caller supplied no usable author uid, so the attribution would accuse
  /// nobody in particular. Nothing was stored.
  rejectedNoAuthor;

  /// Whether this outcome produced a counting entry.
  bool get counts => this == inserted;

  /// Whether the attribution was accepted (stored), as opposed to refused.
  bool get isStored =>
      this == inserted ||
      this == duplicate ||
      this == recordedAsEvidence ||
      this == duplicateEvidence;

  /// Whether a previous entry existed and was merged into.
  bool get isMerge => this == duplicate || this == duplicateEvidence;

  /// Whether a stored correction refused this sighting.
  ///
  /// A suppressed sighting is neither stored nor counted: it is the tombstone
  /// doing its job, not a failure, and not a pass either.
  bool get isSuppressed =>
      this == suppressedByCorrection || this == suppressedNewVersion;

  /// Stable machine name for logs and evidence.
  String get wireName => name;
}

/// One attribution as the caller observed it.
///
/// [authorUid] is **platform data**, supplied by the caller from the fetched
/// comment. It is never read out of a [FilterResult], because an operator's
/// evidence may mention whatever text it saw and that text is not an identity
/// (spec section 7.1).
final class ViolationAttribution {
  const ViolationAttribution({
    required this.commentId,
    required this.authorUid,
    required this.attributeViolation,
    this.surface,
    this.reasonCodes = const <String>{},
    this.ruleIds = const <String>{},
    this.operatorIds = const <String>{},
    this.evidence = const <FilterEvidence>[],
    this.observedAtMs,
    this.contentVersion,
  });

  /// Builds an attribution from the operator verdicts that fired.
  ///
  /// Convenience for a caller that holds a decision's hits but no composer
  /// output. The author uid still has to be passed separately: this factory
  /// reads reason codes and operator ids out of the verdicts, and deliberately
  /// reads nothing identity-shaped out of them.
  factory ViolationAttribution.fromHits({
    required String commentId,
    required String? authorUid,
    required List<FilterResult> hits,
    ContentSurface? surface,
    bool? attributeViolation,
    int? observedAtMs,
    String? contentVersion,
  }) {
    final reasonCodes = <String>{};
    final operatorIds = <String>{};
    final evidence = <FilterEvidence>[];
    var anyAttributable = false;
    for (final hit in hits) {
      if (!hit.isMatch) {
        continue;
      }
      reasonCodes.add(hit.reasonCode);
      operatorIds.add(hit.operatorId);
      evidence.addAll(hit.evidence);
      if (hit.attributeViolation) {
        anyAttributable = true;
      }
    }
    return ViolationAttribution(
      commentId: commentId,
      authorUid: authorUid,
      attributeViolation: attributeViolation ?? anyAttributable,
      surface: surface,
      reasonCodes: reasonCodes,
      operatorIds: operatorIds,
      evidence: evidence,
      observedAtMs: observedAtMs,
      contentVersion: contentVersion,
    );
  }

  /// Platform comment/reply id this attribution is about.
  final String commentId;

  /// Author of the comment as the platform reported it. Null/blank is a
  /// rejection, never a guess.
  final String? authorUid;

  /// Whether the deciding rule allowed this violation to be attributed to the
  /// author (spec section 7.1). False means "evidence only" — a filter hit that
  /// says nothing about who posted the content must not enter a count.
  final bool attributeViolation;

  final ContentSurface? surface;

  /// Stable reason codes that fired (for example `text.keyword_hit`).
  final Set<String> reasonCodes;

  /// Rule ids that fired.
  final Set<String> ruleIds;

  /// Operator ids that fired; kept for the same audit reason as [reasonCodes].
  final Set<String> operatorIds;

  /// Redacted support for the verdict. Already safe to persist.
  final List<FilterEvidence> evidence;

  /// When the platform data was observed; the ledger stamps its own clock when
  /// this is null, so nothing here has to call `DateTime.now()`.
  final int? observedAtMs;

  /// Revision of the content this sighting judged (for example a comment's
  /// edit counter).
  ///
  /// Optional so every existing caller keeps compiling; null means "the caller
  /// does not version this content", which [ViolationCorrection] treats as "no
  /// change" — a correction can never be lifted by silence.
  final String? contentVersion;

  @override
  String toString() =>
      'ViolationAttribution($commentId, author: ${authorUid ?? 'none'}, '
      'attributable: $attributeViolation, reasons: ${reasonCodes.length})';
}

/// The stored, de-duplicated entry for one [ViolationKey].
///
/// One object per comment, forever: repeats merge reason codes, rule ids,
/// operator ids and evidence into this entry instead of creating siblings, so
/// downstream consumers (suggestion anchors, the UI, exports) can treat "one
/// record per comment" as an invariant.
final class ViolationRecord {
  const ViolationRecord({
    required this.key,
    required this.authorUid,
    required this.firstSeenAtMs,
    required this.lastSeenAtMs,
    required this.attributeEligible,
    this.surface,
    this.reasonCodes = const <String>{},
    this.ruleIds = const <String>{},
    this.operatorIds = const <String>{},
    this.evidence = const <FilterEvidence>[],
    this.contentVersion,
  });

  /// Accounting identity.
  final ViolationKey key;

  /// Author supplied by the platform when the first sighting was recorded.
  final String authorUid;

  /// First and last sighting, in milliseconds since the epoch.
  final int firstSeenAtMs;
  final int lastSeenAtMs;

  /// Whether this entry may be counted against [authorUid].
  ///
  /// True once any sighting was attributable. It never drops back to false on a
  /// later evidence-only sighting: demoting a recorded violation because a
  /// second operator only produced media evidence would silently delete an
  /// accusation the user already saw. Corrections go through
  /// `ViolationLedger.revoke`, which removes the entry and leaves a
  /// [ViolationCorrection] tombstone in its place.
  final bool attributeEligible;

  final ContentSurface? surface;

  final Set<String> reasonCodes;
  final Set<String> ruleIds;
  final Set<String> operatorIds;
  final List<FilterEvidence> evidence;

  /// Content version of the first attributed sighting; null when the caller does
  /// not version its content.
  ///
  /// Set once and never rewritten by [mergedWith]: the version names the
  /// occurrence this entry accounts for, so a later read of a different revision
  /// must not relabel the original accusation.
  final String? contentVersion;

  /// Comment id, for call sites that do not need the whole key.
  String get commentId => key.commentId;

  /// Whether this entry contributes to `countFor`.
  bool get countsAsViolation => attributeEligible;

  /// Timestamp the window is measured from: when this violation *happened*.
  ///
  /// [lastSeenAtMs] is audit metadata and never enters the decision. A repeat
  /// read of a 31-day-old comment today must not renew it into a 30-day window,
  /// so eligibility follows the occurrence only.
  int get occurredAtMs => firstSeenAtMs;

  /// Whether this entry's occurrence is inside [windowDays] of [nowMs].
  ///
  /// Measured from [occurredAtMs], never from [lastSeenAtMs].
  bool isWithinWindow({required int nowMs, required int windowDays}) {
    final occurred = occurredAtMs;
    if (occurred > nowMs) {
      // An occurrence dated in the future cannot be inside a window that ends
      // now; it is not eligible yet.
      return false;
    }
    return nowMs - occurred <= windowDays * _millisecondsPerDay;
  }

  /// Is this record about [authorUid]?
  bool isAbout(String authorUid) => this.authorUid == authorUid;

  /// Merges one observation into this entry.
  ///
  /// Sets are unioned; evidence is appended with exact duplicates dropped, so a
  /// repeated evaluate() that replays the same operator verdicts does not grow
  /// the stored evidence either.
  ViolationRecord mergedWith(
    ViolationAttribution attribution, {
    required int nowMs,
  }) {
    final observedAt = attribution.observedAtMs ?? nowMs;
    final mergedReasonCodes = <String>{
      ...reasonCodes,
      ...attribution.reasonCodes,
    };
    final mergedRuleIds = <String>{...ruleIds, ...attribution.ruleIds};
    final mergedOperatorIds = <String>{
      ...operatorIds,
      ...attribution.operatorIds,
    };
    final mergedEvidence = <FilterEvidence>[...evidence];
    for (final item in attribution.evidence) {
      if (!mergedEvidence.contains(item)) {
        mergedEvidence.add(item);
      }
    }
    final observedSurface = attribution.surface ?? surface;
    return ViolationRecord(
      key: key,
      authorUid: authorUid,
      // The occurrence version is set at most once: a later sighting of another
      // revision must not relabel the accusation that created this entry.
      contentVersion: contentVersion ?? attribution.contentVersion,
      firstSeenAtMs: observedAt < firstSeenAtMs ? observedAt : firstSeenAtMs,
      lastSeenAtMs: observedAt > lastSeenAtMs ? observedAt : lastSeenAtMs,
      attributeEligible: attributeEligible || attribution.attributeViolation,
      surface: observedSurface,
      reasonCodes: Set<String>.unmodifiable(mergedReasonCodes),
      ruleIds: Set<String>.unmodifiable(mergedRuleIds),
      operatorIds: Set<String>.unmodifiable(mergedOperatorIds),
      evidence: List<FilterEvidence>.unmodifiable(mergedEvidence),
    );
  }

  /// Persisted shape. Sets are written sorted so two runs of the same data
  /// produce byte-identical JSON.
  Map<String, Object?> toJson() => <String, Object?>{
    'accountScopeId': key.accountScopeId,
    'commentId': key.commentId,
    'authorUid': authorUid,
    if (contentVersion != null) 'contentVersion': contentVersion,
    if (surface != null) 'surface': surface!.wireName,
    'firstSeenAtMs': firstSeenAtMs,
    'lastSeenAtMs': lastSeenAtMs,
    'attributeEligible': attributeEligible,
    'reasonCodes': _sorted(reasonCodes),
    'ruleIds': _sorted(ruleIds),
    'operatorIds': _sorted(operatorIds),
    'evidence': <Object?>[for (final item in evidence) _evidenceToJson(item)],
  };

  /// Decodes [toJson]; returns null when a required field is missing or of the
  /// wrong type, which the repository reports as `Corrupt` rather than as a
  /// silent miss.
  static ViolationRecord? fromJson(Map<String, Object?> json) {
    final accountScopeId = json['accountScopeId'];
    final commentId = json['commentId'];
    final authorUid = json['authorUid'];
    final firstSeenAtMs = json['firstSeenAtMs'];
    final lastSeenAtMs = json['lastSeenAtMs'];
    final attributeEligible = json['attributeEligible'];
    if (accountScopeId is! String ||
        accountScopeId.isEmpty ||
        commentId is! String ||
        commentId.isEmpty ||
        authorUid is! String ||
        authorUid.isEmpty ||
        firstSeenAtMs is! int ||
        lastSeenAtMs is! int ||
        attributeEligible is! bool) {
      return null;
    }
    final surfaceName = json['surface'];
    final rawVersion = json['contentVersion'];
    if (rawVersion != null && rawVersion is! String) {
      return null;
    }
    final evidence = <FilterEvidence>[];
    final rawEvidence = json['evidence'];
    if (rawEvidence is List) {
      for (final item in rawEvidence) {
        final decoded = _evidenceFromJson(item);
        if (decoded == null) {
          return null;
        }
        evidence.add(decoded);
      }
    } else if (rawEvidence != null) {
      return null;
    }
    return ViolationRecord(
      key: ViolationKey(
        accountScopeId: accountScopeId,
        commentId: commentId,
      ),
      authorUid: authorUid,
      contentVersion: rawVersion is String && rawVersion.isNotEmpty
          ? rawVersion
          : null,
      surface: enumByWireName<ContentSurface>(
        ContentSurface.values,
        surfaceName is String ? surfaceName : null,
      ),
      firstSeenAtMs: firstSeenAtMs,
      lastSeenAtMs: lastSeenAtMs,
      attributeEligible: attributeEligible,
      reasonCodes: _readStringSet(json['reasonCodes']) ?? const <String>{},
      ruleIds: _readStringSet(json['ruleIds']) ?? const <String>{},
      operatorIds: _readStringSet(json['operatorIds']) ?? const <String>{},
      evidence: List<FilterEvidence>.unmodifiable(evidence),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ViolationRecord &&
          key == other.key &&
          authorUid == other.authorUid &&
          contentVersion == other.contentVersion &&
          firstSeenAtMs == other.firstSeenAtMs &&
          lastSeenAtMs == other.lastSeenAtMs &&
          attributeEligible == other.attributeEligible &&
          surface == other.surface &&
          _setEquals(reasonCodes, other.reasonCodes) &&
          _setEquals(ruleIds, other.ruleIds) &&
          _setEquals(operatorIds, other.operatorIds) &&
          _listEquals(evidence, other.evidence);

  @override
  int get hashCode => Object.hash(
    key,
    authorUid,
    contentVersion,
    firstSeenAtMs,
    lastSeenAtMs,
    attributeEligible,
    surface,
    Object.hashAllUnordered(reasonCodes),
    Object.hashAllUnordered(ruleIds),
    Object.hashAllUnordered(operatorIds),
    Object.hashAll(evidence),
  );

  @override
  String toString() =>
      'ViolationRecord(${key.commentId} by $authorUid, '
      'counts: $attributeEligible, reasons: ${reasonCodes.length}, '
      'evidence: ${evidence.length})';
}

/// The durable correction of one [ViolationKey]: a tombstone, not a deletion.
///
/// ## The policy (the one place it is written down)
///
/// `ViolationLedger.revoke` stops counting a record by *replacing* it with this
/// tombstone. The entry is gone from `countFor` — that is the correction — but
/// the key remembers that a correction happened, so a later evaluate() of the
/// very same content cannot quietly recreate the accusation the user just
/// dismissed:
///
/// * **Same version, or an unversioned re-sighting → suppressed.** Rewriting the
///   same bytes is not new evidence. When either side has no version there is
///   nothing to compare, and silence must not lift a correction, so it is
///   suppressed too.
/// * **Different version → still suppressed, reported as
///   [ViolationRecordOutcome.suppressedNewVersion].** An edit is a signal worth
///   seeing, not a clean slate and not proof of new intent; only a human
///   decision lifts a correction.
/// * **Lifting one requires `ViolationLedger.reset`.** The reset is deliberate,
///   account-scoped, and audited; after it the next evaluate() inserts again.
///
/// The tombstone carries no author to accuse and nothing that counts. That is
/// what makes "corrected" safe to keep forever.
final class ViolationCorrection {
  const ViolationCorrection({
    required this.key,
    this.eventTimestampMs,
    this.revokedAtMs,
    this.contentVersion,
    this.reasonCode,
    this.previousAuthorUid,
    this.previousReasonCodes = const <String>{},
  });

  /// Accounting identity the correction applies to.
  final ViolationKey key;

  /// Event time of the revoked violation; null when the revoked entry never had
  /// one worth keeping.
  ///
  /// This is the original violation's occurrence, not the time of the revoke,
  /// and it is what a later [ViolationLedger.reset] uses as the window floor.
  final int? eventTimestampMs;

  /// When the correction was recorded. Audit metadata.
  final int? revokedAtMs;

  /// Content version that was corrected, when the caller versioned its content.
  final String? contentVersion;

  /// Caller-supplied reason, kept for audit.
  final String? reasonCode;

  /// Author of the revoked entry. Audit only — nothing here is ever counted.
  final String? previousAuthorUid;

  /// Reason codes of the revoked entry. Audit only.
  final Set<String> previousReasonCodes;

  /// Comment id, for call sites that do not need the whole key.
  String get commentId => key.commentId;

  /// Whether a sighting of [version] is the corrected version.
  ///
  /// Unversioned on either side counts as "the same": see the class doc.
  bool correctsVersion(String? version) =>
      contentVersion == null || version == null || contentVersion == version;

  /// Merges a repeat correction into this one.
  ///
  /// Keeps the earliest occurrence and the earliest known version (a correction
  /// about the first sighting must not be overwritten by a later revision),
  /// and the latest recorded reason.
  ViolationCorrection mergedWith(ViolationCorrection other) {
    final event = switch ((eventTimestampMs, other.eventTimestampMs)) {
      (null, final later) => later,
      (final first, null) => first,
      (final first?, final later?) => first <= later ? first : later,
    };
    final revoked = switch ((revokedAtMs, other.revokedAtMs)) {
      (null, final later) => later,
      (final first, null) => first,
      (final first?, final later?) => first >= later ? first : later,
    };
    return ViolationCorrection(
      key: key,
      eventTimestampMs: event,
      revokedAtMs: revoked,
      contentVersion: contentVersion ?? other.contentVersion,
      reasonCode: other.reasonCode ?? reasonCode,
      previousAuthorUid: previousAuthorUid ?? other.previousAuthorUid,
      previousReasonCodes: Set<String>.unmodifiable(<String>{
        ...previousReasonCodes,
        ...other.previousReasonCodes,
      }),
    );
  }

  /// Persisted shape. A tombstone and a record live in the same account-scoped
  /// storage and are told apart by [isCorrectionField].
  Map<String, Object?> toJson() => <String, Object?>{
    'accountScopeId': key.accountScopeId,
    'commentId': key.commentId,
    isCorrectionField: true,
    if (eventTimestampMs != null) 'eventTimestampMs': eventTimestampMs,
    if (revokedAtMs != null) 'revokedAtMs': revokedAtMs,
    if (contentVersion != null) 'contentVersion': contentVersion,
    if (reasonCode != null) 'reasonCode': reasonCode,
    if (previousAuthorUid != null) 'previousAuthorUid': previousAuthorUid,
    'previousReasonCodes': _sorted(previousReasonCodes),
  };

  /// Decodes [toJson]; null when the tombstone is unusable, which the
  /// repository reports as `Corrupt` rather than as a silent miss.
  static ViolationCorrection? fromJson(Map<String, Object?> json) {
    final accountScopeId = json['accountScopeId'];
    final commentId = json['commentId'];
    if (accountScopeId is! String ||
        accountScopeId.isEmpty ||
        commentId is! String ||
        commentId.isEmpty) {
      return null;
    }
    final eventTimestampMs = json['eventTimestampMs'];
    final revokedAtMs = json['revokedAtMs'];
    final contentVersion = json['contentVersion'];
    final reasonCode = json['reasonCode'];
    final previousAuthorUid = json['previousAuthorUid'];
    if ((eventTimestampMs != null && eventTimestampMs is! int) ||
        (revokedAtMs != null && revokedAtMs is! int) ||
        (contentVersion != null && contentVersion is! String) ||
        (reasonCode != null && reasonCode is! String) ||
        (previousAuthorUid != null && previousAuthorUid is! String)) {
      return null;
    }
    return ViolationCorrection(
      key: ViolationKey(accountScopeId: accountScopeId, commentId: commentId),
      eventTimestampMs: eventTimestampMs as int?,
      revokedAtMs: revokedAtMs as int?,
      contentVersion: contentVersion as String?,
      reasonCode: reasonCode as String?,
      previousAuthorUid: previousAuthorUid as String?,
      previousReasonCodes:
          _readStringSet(json['previousReasonCodes']) ?? const <String>{},
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ViolationCorrection &&
          key == other.key &&
          eventTimestampMs == other.eventTimestampMs &&
          revokedAtMs == other.revokedAtMs &&
          contentVersion == other.contentVersion &&
          reasonCode == other.reasonCode &&
          previousAuthorUid == other.previousAuthorUid &&
          _setEquals(previousReasonCodes, other.previousReasonCodes);

  @override
  int get hashCode => Object.hash(
    key,
    eventTimestampMs,
    revokedAtMs,
    contentVersion,
    reasonCode,
    previousAuthorUid,
    Object.hashAllUnordered(previousReasonCodes),
  );

  @override
  String toString() =>
      'ViolationCorrection(${key.commentId}${contentVersion == null ? '' : '@$contentVersion'}, '
      'event: ${eventTimestampMs ?? 'none'})';
}

/// Persisted marker that tells a [ViolationCorrection] from a [ViolationRecord].
const String isCorrectionField = 'isCorrection';

/// Whether this stored payload is a correction tombstone rather than a record.
bool isCorrectionPayload(Map<String, Object?> json) =>
    json[isCorrectionField] == true;

/// Whether [authorUid] is a usable platform identity.
///
/// Shared so the ledger and the correction index answer the same question the
/// same way: a blank uid is a rejection, never a guess.
bool isUsableAuthorUid(String? authorUid) {
  final trimmed = authorUid?.trim();
  return trimmed != null && trimmed.isNotEmpty;
}

/// [evidence] with exact duplicates dropped, order preserved.
///
/// Evidence is a set: three operators that each report the same redacted
/// excerpt describe one observation, not three. Applied on insert as well as on
/// merge, so the stored record is the same whichever sighting created it.
List<FilterEvidence> dedupeEvidence(Iterable<FilterEvidence> evidence) {
  final result = <FilterEvidence>[];
  for (final item in evidence) {
    if (!result.contains(item)) {
      result.add(item);
    }
  }
  return List<FilterEvidence>.unmodifiable(result);
}

const int _millisecondsPerDay = 24 * 60 * 60 * 1000;

List<String> _sorted(Set<String> values) {
  final list = values.toList()..sort();
  return list;
}

Map<String, Object?> _evidenceToJson(FilterEvidence evidence) =>
    <String, Object?>{
      'kind': evidence.kind.name,
      'field': evidence.field,
      if (evidence.redactedExcerpt != null) 'excerpt': evidence.redactedExcerpt,
      if (evidence.fingerprint != null) 'fingerprint': evidence.fingerprint,
      if (evidence.mediaId != null) 'mediaId': evidence.mediaId,
    };

FilterEvidence? _evidenceFromJson(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final kindName = raw['kind'];
  final field = raw['field'];
  final kind = enumByWireName<EvidenceKind>(
    EvidenceKind.values,
    kindName is String ? kindName : null,
  );
  if (kind == null || field is! String || field.isEmpty) {
    return null;
  }
  final excerpt = raw['excerpt'];
  final fingerprint = raw['fingerprint'];
  final mediaId = raw['mediaId'];
  return FilterEvidence(
    kind: kind,
    field: field,
    redactedExcerpt: excerpt is String ? excerpt : null,
    fingerprint: fingerprint is String ? fingerprint : null,
    mediaId: mediaId is String ? mediaId : null,
  );
}

Set<String>? _readStringSet(Object? raw) {
  if (raw is! List) {
    return null;
  }
  final result = <String>{};
  for (final item in raw) {
    if (item is! String) {
      return null;
    }
    result.add(item);
  }
  return Set<String>.unmodifiable(result);
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final item in a) {
    if (!b.contains(item)) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
