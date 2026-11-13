/// Identity of one stored decision, plus the states it may be stored in.
///
/// A decision is only reusable when *every* input that produced it is still the
/// same: the account, the content revision, the surface, the structural parent,
/// the rule set, the prompt and profile the operators ran under, the provider and
/// model behind them, and the schema of the output. [DecisionCacheKey] names all
/// of them and reduces the combination to one opaque digest, so a lookup cannot
/// accidentally compare a subset (plan-core sections 5.1, 8.1).
///
/// ## Why this file has no raw content
///
/// The key carries [contentVersion] and an optional [textHash], never the text
/// itself, so a key is safe in a storage key, a log line and a toString. Raw
/// text is only ever digest input.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';

/// The four things a cached decision may be.
///
/// The distinction that matters is [isSettled]: a settled state is a real
/// verdict about content and may be kept for a long time; [uncertain] and
/// [failed] are "we do not know yet" and must expire quickly so the next pass
/// retries.
///
/// **A transient failure is never stored as [passed].** Turning "the model timed
/// out" into "the content is fine" is the silent-allow failure the whole
/// subsystem exists to prevent, so [failed] is a state of its own and
/// [DecisionCachePolicy.storableState] is the only supported way to derive one.
enum DecisionCacheState {
  /// The content was evaluated and allowed.
  passed('passed', settled: true, ttl: Duration(hours: 24)),

  /// The content was evaluated and restricted (collapse, hide or mask).
  blocked('blocked', settled: true, ttl: Duration(hours: 24)),

  /// The evaluation could not settle (missing capability, ambiguous model
  /// output). Retried soon, never treated as a pass.
  uncertain('uncertain', settled: false, ttl: Duration(minutes: 15)),

  /// The evaluation failed outright (execution error, parse failure, timeout).
  /// The shortest lifetime of the four: the next pass should retry almost
  /// immediately.
  failed('failed', settled: false, ttl: Duration(minutes: 1));

  const DecisionCacheState(
    this.wireName, {
    required this.settled,
    required this.ttl,
  });

  /// Stable machine name used by storage and logs. Frozen.
  final String wireName;

  /// Whether this state is a real verdict rather than a pending retry.
  final bool settled;

  /// How long an entry in this state stays usable.
  ///
  /// Guidance, not enforcement: the cache applies it through
  /// [DecisionCachePolicy.isReusable] with a caller-supplied clock, so nothing
  /// here reads the wall clock.
  final Duration ttl;

  /// Whether this entry may be reused without re-running the operators.
  bool get isReusable => settled;

  /// Whether this state must never be reported to the user as a pass.
  bool get isUnresolved => !settled;

  /// Short time-to-live used for [failed]; documented here so a cache
  /// implementation has one number to read instead of one to invent.
  static const Duration failedTtl = Duration(minutes: 1);

  /// Long time-to-live used for settled states.
  static const Duration settledTtl = Duration(hours: 24);
}

/// Identity of one decision, and the digest everything is keyed by.
///
/// Every component is part of the identity. Two decisions may be reused for one
/// another only when all of them agree, which is why they are folded into one
/// digest instead of being compared field by field at each call site: a partial
/// comparison is the bug this type exists to make impossible.
final class DecisionCacheKey {
  const DecisionCacheKey({
    required this.accountScopeId,
    required this.contentType,
    required this.contentId,
    required this.contentVersion,
    required this.surface,
    required this.parentContextHash,
    required this.ruleVersion,
    required this.promptVersion,
    required this.profileVersion,
    required this.providerId,
    required this.providerVersion,
    required this.model,
    required this.outputSchemaVersion,
    this.textHash = '',
  });

  /// Builds the key of [content] for one rule/prompt/profile/provider revision.
  ///
  /// [textHash] is filled in automatically from the content text — as a digest,
  /// so the text never enters the key. [parentContextHash] is supplied by the
  /// caller because the structural parent (video, thread, parent reply, sort
  /// key) lives in [GuardContent.context], and canonically encoding it is the
  /// caller's decision, not this file's.
  factory DecisionCacheKey.fromContent({
    required GuardContent content,
    required String parentContextHash,
    required String ruleVersion,
    required String promptVersion,
    required String profileVersion,
    required String providerId,
    required String providerVersion,
    required String model,
    required String outputSchemaVersion,
  }) => DecisionCacheKey(
    accountScopeId: content.account.id,
    contentType: content.contentType,
    contentId: content.contentId,
    contentVersion: content.contentVersion,
    surface: content.surface,
    parentContextHash: parentContextHash,
    ruleVersion: ruleVersion,
    promptVersion: promptVersion,
    profileVersion: profileVersion,
    providerId: providerId,
    providerVersion: providerVersion,
    model: model,
    outputSchemaVersion: outputSchemaVersion,
    textHash: hashText(content.text),
  );

  /// Version marker mixed into the digest, so a future key definition cannot
  /// collide with digests minted by this one.
  static const String digestSalt = 'contentguard.decision.key.v1';

  /// Prefix on every digest, which makes a stored key recognisable on sight.
  static const String digestPrefix = 'cgk1_';

  /// Opaque digest of the account identity ([AccountScope.id]).
  final String accountScopeId;

  final ContentType contentType;

  final String contentId;

  /// Opaque revision of the content payload; part of the identity so an edited
  /// comment is re-evaluated instead of reusing its old verdict.
  final String contentVersion;

  final ContentSurface surface;

  /// Digest of the structural position (see [GuardContent.context]).
  final String parentContextHash;

  /// Version of the rule set the pass ran under.
  final String ruleVersion;

  /// Version of the operator prompt the pass ran under.
  final String promptVersion;

  /// Version of the analysis profile (thresholds, enabled operators).
  final String profileVersion;

  /// Provider that served the semantic operator, or `local` for on-device work.
  final String providerId;

  /// Version of that provider's contract or output dialect.
  final String providerVersion;

  /// Model identifier used by that provider.
  final String model;

  /// Version of the decision output schema, so a shape change invalidates the
  /// cache instead of being decoded as an older shape.
  final String outputSchemaVersion;

  /// Digest of the content text; empty when the content has no text.
  final String textHash;

  /// Opaque digest of every component, in a frozen order.
  ///
  /// Components are length-prefixed rather than merely separated, so a value
  /// that contains a separator cannot forge a different combination.
  String get digest {
    final fields = <String>[
      accountScopeId,
      contentType.wireName,
      contentId,
      contentVersion,
      textHash,
      surface.wireName,
      parentContextHash,
      ruleVersion,
      promptVersion,
      profileVersion,
      providerId,
      providerVersion,
      model,
      outputSchemaVersion,
    ];
    final buffer = StringBuffer(digestSalt);
    for (final field in fields) {
      buffer
        ..write('\u0000')
        ..write(field.length)
        ..write(':')
        ..write(field);
    }
    final body = sha256.convert(utf8.encode(buffer.toString())).toString();
    return digestPrefix + body;
  }

  /// Digest without the storage prefix; convenient when a backend has its own.
  String get digestBody => digest.substring(digestPrefix.length);

  /// Storage id of this decision: the digest, nothing else.
  String get storageId => digest;

  /// Digest of [text], or an empty string when there is no text.
  ///
  /// Deliberately returns a digest, never a prefix of the text: a truncated
  /// excerpt is still user content.
  static String hashText(String? text) {
    if (text == null || text.isEmpty) return '';
    return 'tx1_' + sha256.convert(utf8.encode(text)).toString();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecisionCacheKey &&
          accountScopeId == other.accountScopeId &&
          contentType == other.contentType &&
          contentId == other.contentId &&
          contentVersion == other.contentVersion &&
          surface == other.surface &&
          parentContextHash == other.parentContextHash &&
          ruleVersion == other.ruleVersion &&
          promptVersion == other.promptVersion &&
          profileVersion == other.profileVersion &&
          providerId == other.providerId &&
          providerVersion == other.providerVersion &&
          model == other.model &&
          outputSchemaVersion == other.outputSchemaVersion &&
          textHash == other.textHash;

  @override
  int get hashCode => Object.hash(
    accountScopeId,
    contentType,
    contentId,
    contentVersion,
    surface,
    parentContextHash,
    ruleVersion,
    promptVersion,
    profileVersion,
    providerId,
    providerVersion,
    model,
    outputSchemaVersion,
    textHash,
  );

  /// Prints the digest and the identifying parts; every component is already
  /// opaque (an id, a hash or a version), and no text is held here at all.
  @override
  String toString() =>
      'DecisionCacheKey(' +
      digest +
      ', ' +
      contentType.wireName +
      ':' +
      contentId +
      ', surface: ' +
      surface.wireName +
      ', model: ' +
      model +
      ')';
}

/// One cached decision: its key, its state and when it was written.
final class DecisionCacheEntry {
  const DecisionCacheEntry({
    required this.key,
    required this.state,
    required this.storedAtMs,
  });

  final DecisionCacheKey key;

  final DecisionCacheState state;

  /// Write time from the injected clock; TTL is measured from here.
  final int storedAtMs;

  /// Age in milliseconds at [nowMs]; negative when the clock went backwards.
  int ageMs(int nowMs) => nowMs - storedAtMs;

  /// Whether this entry has reached its state's TTL at [nowMs].
  bool isExpired(int nowMs) => ageMs(nowMs) >= state.ttl.inMilliseconds;

  /// Whether this entry may be reused at [nowMs].
  bool isReusableAt(int nowMs) => state.isReusable && !isExpired(nowMs);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecisionCacheEntry &&
          key == other.key &&
          state == other.state &&
          storedAtMs == other.storedAtMs;

  @override
  int get hashCode => Object.hash(key, state, storedAtMs);

  @override
  String toString() =>
      'DecisionCacheEntry(' + state.wireName + ', ' + key.digest + ')';
}

/// The storage rules of the decision cache.
///
/// Every write goes through [storableState], so "a transient failure is never
/// stored as a pass" has exactly one implementation. Nothing here reads the wall
/// clock: callers pass [nowMs].
abstract final class DecisionCachePolicy {
  /// State a rendered decision is stored under.
  ///
  /// [PresenterState.pending] maps to [DecisionCacheState.uncertain] on purpose:
  /// a row that was never decided has no verdict to remember, and the only wrong
  /// answer is [DecisionCacheState.passed].
  static DecisionCacheState stateFor(PresenterState state) => switch (state) {
    PresenterState.allowed => DecisionCacheState.passed,
    PresenterState.collapsed ||
    PresenterState.hidden ||
    PresenterState.masked => DecisionCacheState.blocked,
    PresenterState.uncertain ||
    PresenterState.pending => DecisionCacheState.uncertain,
  };

  /// State a write is actually stored under.
  ///
  /// [transientFailure] covers every failure that is not a verdict about the
  /// content: a timeout, a transport error, an operator that threw. It always
  /// wins over [state], so a caller that reports a failure together with
  /// [PresenterState.allowed] gets [DecisionCacheState.failed] — never
  /// [DecisionCacheState.passed].
  static DecisionCacheState storableState({
    required PresenterState state,
    bool transientFailure = false,
  }) {
    if (transientFailure) return DecisionCacheState.failed;
    return stateFor(state);
  }

  /// Whether an entry written at [storedAtMs] has reached its TTL at [nowMs].
  ///
  /// Pure freshness: this is the predicate the eviction sweep uses. A [failed]
  /// entry expires quickly but is still never *reusable* — see [isReusable].
  static bool isExpired(
    DecisionCacheState state, {
    required int storedAtMs,
    required int nowMs,
  }) => (nowMs - storedAtMs) >= state.ttl.inMilliseconds;

  /// Whether an entry written at [storedAtMs] may answer a lookup at [nowMs].
  ///
  /// Requires a settled state as well as freshness: an [uncertain] or [failed]
  /// entry is a note that this content needs another pass, so it can never be
  /// the answer to one — returning it would turn a timeout into a verdict.
  static bool isReusable(
    DecisionCacheState state, {
    required int storedAtMs,
    required int nowMs,
  }) =>
      state.isReusable &&
      !isExpired(state, storedAtMs: storedAtMs, nowMs: nowMs);

  /// Builds the entry to write for a rendered decision.
  ///
  /// Always returns an entry: an outcome that cannot be settled is stored as
  /// [DecisionCacheState.uncertain] or [DecisionCacheState.failed] and carries
  /// that state's short TTL, so the next pass retries instead of the row being
  /// remembered as a pass.
  static DecisionCacheEntry entryFor({
    required DecisionCacheKey key,
    required PresenterState state,
    required int nowMs,
    bool transientFailure = false,
  }) => DecisionCacheEntry(
    key: key,
    state: storableState(state: state, transientFailure: transientFailure),
    storedAtMs: nowMs,
  );

  /// Time-to-live guidance for [state], exposed as one table for a cache
  /// implementation to read instead of inventing numbers.
  static Duration ttlOf(DecisionCacheState state) => state.ttl;
}
