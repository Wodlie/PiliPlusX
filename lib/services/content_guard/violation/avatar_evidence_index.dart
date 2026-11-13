/// Media evidence that is de-duplicated but never counted.
///
/// A recurring avatar, a repeated QR image or the same thumbnail across a
/// hundred comments is *one* piece of evidence about *one* account, not a
/// hundred violations. This index exists so that a caller can record the sighting
/// without the ledger ever seeing it (spec section 6.2, 7.1):
///
/// * The key is `(accountScopeId, avatarFingerprint, ruleId)`. The same avatar
///   matched by the same rule is one entry, forever.
/// * The same avatar matched by a *different* rule is a different entry: the two
///   rules are two independent reasons and the UI has to be able to say which.
/// * [AvatarEvidenceEntry.attributeEligible] defaults to **false**. Nothing in
///   this file can raise an author's violation count, and the index has no
///   reference to `ViolationLedger` at all — the separation is structural, not a
///   convention.
library;

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/storage/content_guard_storage_keys.dart';
import 'package:PiliPlus/services/content_guard/storage/json_repository.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_repository.dart';

/// Identity of one avatar observation: account scope + fingerprint + rule.
final class AvatarEvidenceKey {
  const AvatarEvidenceKey({
    required this.accountScopeId,
    required this.avatarFingerprint,
    required this.ruleId,
  });

  final String accountScopeId;

  /// Stable perceptual fingerprint of the avatar image. Never a URL: a signed
  /// URL expires and would produce a new "identity" on every fetch.
  final String avatarFingerprint;

  /// The rule that matched it.
  final String ruleId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AvatarEvidenceKey &&
          accountScopeId == other.accountScopeId &&
          avatarFingerprint == other.avatarFingerprint &&
          ruleId == other.ruleId;

  @override
  int get hashCode => Object.hash(accountScopeId, avatarFingerprint, ruleId);

  @override
  String toString() => 'AvatarEvidenceKey($avatarFingerprint, rule: $ruleId)';
}

/// What recording one [AvatarEvidenceKey] did.
enum AvatarEvidenceOutcome {
  /// First sighting of this avatar under this rule.
  inserted,

  /// This avatar was already recorded under this rule; only the sighting count
  /// moved.
  duplicate,

  /// Nothing was recorded because the fingerprint or the rule id was blank.
  rejected;

  String get wireName => name;
}

/// The stored evidence entry for one avatar/rule pair.
final class AvatarEvidenceEntry {
  const AvatarEvidenceEntry({
    required this.key,
    required this.firstSeenAtMs,
    required this.lastSeenAtMs,
    required this.sightingCount,
    this.attributeEligible = false,
    this.reasonCodes = const <String>{},
    this.lastCommentId,
  });

  final AvatarEvidenceKey key;

  final int firstSeenAtMs;
  final int lastSeenAtMs;

  /// How many comments carried this avatar. An *observation counter* used to
  /// show "seen 12 times"; it is explicitly not a violation count and nothing
  /// multiplies it into one.
  final int sightingCount;

  /// Whether this evidence may ever be attributed to the author. Always false
  /// by default, and the index never flips it on its own.
  final bool attributeEligible;

  final Set<String> reasonCodes;

  /// Last comment the avatar was seen on; helps a reviewer jump to an example.
  final String? lastCommentId;

  /// Same entry, one more sighting.
  AvatarEvidenceEntry withSighting({
    required int nowMs,
    String? commentId,
    Set<String> reasonCodes = const <String>{},
  }) => AvatarEvidenceEntry(
    key: key,
    firstSeenAtMs: firstSeenAtMs,
    lastSeenAtMs: nowMs > lastSeenAtMs ? nowMs : lastSeenAtMs,
    sightingCount: sightingCount + 1,
    attributeEligible: attributeEligible,
    reasonCodes: Set<String>.unmodifiable(<String>{
      ...this.reasonCodes,
      ...reasonCodes,
    }),
    lastCommentId: commentId ?? lastCommentId,
  );

  /// Persisted shape.
  Map<String, Object?> toJson() => <String, Object?>{
    'accountScopeId': key.accountScopeId,
    'avatarFingerprint': key.avatarFingerprint,
    'ruleId': key.ruleId,
    'firstSeenAtMs': firstSeenAtMs,
    'lastSeenAtMs': lastSeenAtMs,
    'sightingCount': sightingCount,
    'attributeEligible': attributeEligible,
    'reasonCodes': (reasonCodes.toList()..sort()),
    if (lastCommentId != null) 'lastCommentId': lastCommentId,
  };

  /// Decodes [toJson]; null when a required field is unusable.
  static AvatarEvidenceEntry? fromJson(Map<String, Object?> json) {
    final accountScopeId = json['accountScopeId'];
    final avatarFingerprint = json['avatarFingerprint'];
    final ruleId = json['ruleId'];
    final firstSeenAtMs = json['firstSeenAtMs'];
    final lastSeenAtMs = json['lastSeenAtMs'];
    final sightingCount = json['sightingCount'];
    final attributeEligible = json['attributeEligible'];
    if (accountScopeId is! String ||
        accountScopeId.isEmpty ||
        avatarFingerprint is! String ||
        avatarFingerprint.isEmpty ||
        ruleId is! String ||
        ruleId.isEmpty ||
        firstSeenAtMs is! int ||
        lastSeenAtMs is! int ||
        sightingCount is! int ||
        attributeEligible is! bool) {
      return null;
    }
    final reasonCodes = <String>{};
    final rawReasons = json['reasonCodes'];
    if (rawReasons is List) {
      for (final item in rawReasons) {
        if (item is! String) {
          return null;
        }
        reasonCodes.add(item);
      }
    } else if (rawReasons != null) {
      return null;
    }
    final lastCommentId = json['lastCommentId'];
    return AvatarEvidenceEntry(
      key: AvatarEvidenceKey(
        accountScopeId: accountScopeId,
        avatarFingerprint: avatarFingerprint,
        ruleId: ruleId,
      ),
      firstSeenAtMs: firstSeenAtMs,
      lastSeenAtMs: lastSeenAtMs,
      sightingCount: sightingCount,
      attributeEligible: attributeEligible,
      reasonCodes: Set<String>.unmodifiable(reasonCodes),
      lastCommentId: lastCommentId is String ? lastCommentId : null,
    );
  }

  @override
  String toString() =>
      'AvatarEvidenceEntry(${key.avatarFingerprint}, rule: ${key.ruleId}, '
      'seen: $sightingCount, attributable: $attributeEligible)';
}

/// Result of [AvatarEvidenceIndex.record].
final class AvatarEvidenceResult {
  const AvatarEvidenceResult({required this.outcome, this.entry});

  final AvatarEvidenceOutcome outcome;

  /// The stored entry after this operation; null when nothing was recorded.
  final AvatarEvidenceEntry? entry;

  @override
  String toString() =>
      'AvatarEvidenceResult(${outcome.wireName}, '
      'seen: ${entry?.sightingCount ?? 0})';
}

/// Account-scoped, de-duplicating avatar evidence index.
///
/// Storage id is `<fingerprint>.<ruleId>` with both halves escaped by
/// [StorageIdCodec], so a fingerprint holding a separator character cannot
/// collide with another pair.
final class AvatarEvidenceIndex {
  AvatarEvidenceIndex(
    KeyValueStore store, {
    required AccountScope account,
    int schemaVersion = 1,
    int Function()? nowMs,
  }) : accountScopeId = account.id,
       _nowMs = nowMs ?? _systemNowMs,
       _repository = JsonRepository(
         store,
         domain: ContentGuardStorageKeys.mediaFeatures,
         accountScopeId: account.id,
         schemaVersion: schemaVersion,
         nowMs: nowMs,
       );

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Storage domain this index owns.
  static const String domain = ContentGuardStorageKeys.mediaFeatures;

  final String accountScopeId;
  final int Function() _nowMs;
  final JsonRepository _repository;

  /// Records one sighting of [avatarFingerprint] under [ruleId].
  ///
  /// Because the key holds the fingerprint and the rule, N comments carrying the
  /// same avatar produce **one** entry whose [AvatarEvidenceEntry.sightingCount]
  /// grows — and an author violation count that never moves, whether or not
  /// [attributeEligible] is ever set.
  Future<AvatarEvidenceResult> record({
    required String avatarFingerprint,
    required String ruleId,
    String? commentId,
    Set<String> reasonCodes = const <String>{},
    bool attributeEligible = false,
  }) async {
    final fingerprint = avatarFingerprint.trim();
    final rule = ruleId.trim();
    if (fingerprint.isEmpty || rule.isEmpty) {
      return const AvatarEvidenceResult(
        outcome: AvatarEvidenceOutcome.rejected,
      );
    }
    final key = AvatarEvidenceKey(
      accountScopeId: accountScopeId,
      avatarFingerprint: fingerprint,
      ruleId: rule,
    );
    final nowMs = _nowMs();
    final existing = _read(key).valueOrNull;
    if (existing == null) {
      final created = AvatarEvidenceEntry(
        key: key,
        firstSeenAtMs: nowMs,
        lastSeenAtMs: nowMs,
        sightingCount: 1,
        attributeEligible: attributeEligible,
        reasonCodes: Set<String>.unmodifiable(reasonCodes),
        lastCommentId: commentId,
      );
      await _repository.write(_storageIdOf(key), created.toJson());
      return AvatarEvidenceResult(
        outcome: AvatarEvidenceOutcome.inserted,
        entry: created,
      );
    }
    final merged = existing.withSighting(
      nowMs: nowMs,
      commentId: commentId,
      reasonCodes: reasonCodes,
    );
    await _repository.write(_storageIdOf(key), merged.toJson());
    return AvatarEvidenceResult(
      outcome: AvatarEvidenceOutcome.duplicate,
      entry: merged,
    );
  }

  /// The entry for [avatarFingerprint] under [ruleId], or null.
  AvatarEvidenceEntry? lookup({
    required String avatarFingerprint,
    required String ruleId,
  }) => _read(
    AvatarEvidenceKey(
      accountScopeId: accountScopeId,
      avatarFingerprint: avatarFingerprint.trim(),
      ruleId: ruleId.trim(),
    ),
  ).valueOrNull;

  /// Every entry in this account scope, ordered by fingerprint then rule.
  List<AvatarEvidenceEntry> allEntries() {
    final entries = <AvatarEvidenceEntry>[];
    for (final id in _repository.ids()) {
      final stored = _repository.read(id);
      switch (stored) {
        case Ok<Map<String, Object?>>(:final value):
          final entry = AvatarEvidenceEntry.fromJson(
            JsonRepository.payloadOf(value),
          );
          if (entry != null && entry.key.accountScopeId == accountScopeId) {
            entries.add(entry);
          }
        case Miss<Map<String, Object?>>():
        case Corrupt<Map<String, Object?>>():
          break;
      }
    }
    entries.sort((a, b) {
      final byFingerprint = a.key.avatarFingerprint.compareTo(
        b.key.avatarFingerprint,
      );
      return byFingerprint != 0
          ? byFingerprint
          : a.key.ruleId.compareTo(b.key.ruleId);
    });
    return List<AvatarEvidenceEntry>.unmodifiable(entries);
  }

  /// Number of distinct avatar/rule pairs recorded.
  int get entryCount => allEntries().length;

  /// Removes one entry; returns whether it was there.
  Future<bool> forget({
    required String avatarFingerprint,
    required String ruleId,
  }) async {
    final id = _storageIdOf(
      AvatarEvidenceKey(
        accountScopeId: accountScopeId,
        avatarFingerprint: avatarFingerprint.trim(),
        ruleId: ruleId.trim(),
      ),
    );
    final existed = _repository.read(id).valueOrNull != null;
    if (existed) {
      await _repository.delete(id);
    }
    return existed;
  }

  static String _storageIdOf(AvatarEvidenceKey key) =>
      StorageIdCodec.encodePair(key.avatarFingerprint, key.ruleId);

  RepositoryResult<AvatarEvidenceEntry> _read(AvatarEvidenceKey key) {
    if (key.avatarFingerprint.isEmpty || key.ruleId.isEmpty) {
      return const Miss<AvatarEvidenceEntry>();
    }
    final stored = _repository.read(_storageIdOf(key));
    return switch (stored) {
      Ok<Map<String, Object?>>(:final value) =>
        switch (AvatarEvidenceEntry.fromJson(JsonRepository.payloadOf(value))) {
          final AvatarEvidenceEntry entry => Ok<AvatarEvidenceEntry>(entry),
          null => const Corrupt<AvatarEvidenceEntry>(
            'avatar evidence entry is unreadable',
          ),
        },
      Miss<Map<String, Object?>>() => const Miss<AvatarEvidenceEntry>(),
      Corrupt<Map<String, Object?>>(:final reason) =>
        Corrupt<AvatarEvidenceEntry>(reason),
    };
  }
}
