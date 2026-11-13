/// The author-level blacklist suggestion, its lifecycle states and the record
/// that is stored.
///
/// The state machine itself lives in `blacklist_suggestion_machine.dart`; this
/// file is the vocabulary:
///
/// ```
/// candidate -> visible -> accepted
///                      -> rejected
///                      -> snoozed  (cooldown, then back to candidate/visible)
///                      -> invalidated (counts fell below the threshold)
/// ```
///
/// Two invariants shape every declaration here:
///
/// * **accepted is terminal and user-owned.** A new AI verdict, a correction or a
///   ledger change may never revoke it. Only an explicit `unaccept` does, because
///   the author is on the user's blocklist and the ledger has no business undoing
///   that.
/// * **rejected is persistent.** It survives restarts and suppresses
///   re-suggestion until the user resets it — an app that keeps proposing the same
///   block after being told no is worse than one that never proposed it.
library;

import 'package:PiliPlus/services/content_guard/model/content_types.dart';

/// Lifecycle state of one author-level suggestion.
enum SuggestionState {
  /// The author crossed the counting threshold but no card has been shown yet.
  candidate,

  /// The card is being shown (or may be shown at its anchors).
  visible,

  /// The user accepted it. Manual, terminal, never auto-revoked.
  accepted,

  /// The user rejected it. Persists across restart until explicitly reset.
  rejected,

  /// The user deferred it. Distinct from [rejected]: it expires, and it is not a
  /// statement that the suggestion is wrong.
  snoozed,

  /// The condition no longer holds (counts fell below the threshold after
  /// corrections). Not a user decision, so it may become a candidate again.
  invalidated;

  /// Stable machine name for storage and logs.
  String get wireName => name;

  /// Whether this state is a user decision that no automatic transition may
  /// replace.
  ///
  /// [accepted] and [rejected] are terminal: only [unaccept] and [reset] leave
  /// them. Everything else — candidate, visible, snoozed, invalidated — is a
  /// state the engine may revise on its own, so a stale second instance
  /// reconciling a new count is allowed to move it.
  bool get isTerminalDecision =>
      this == SuggestionState.accepted || this == SuggestionState.rejected;

  /// Whether the card may render in this state.
  bool get isRenderable => this == SuggestionState.visible;

  /// Whether this state blocks a new candidate from the same author.
  bool get isSuppressing =>
      this == SuggestionState.accepted ||
      this == SuggestionState.rejected ||
      this == SuggestionState.snoozed;
}

/// What the machine decided a suggestion is about, and why.
///
/// Author-level: [authorSuggestionId] is the id every anchor of this author
/// shares (see `SuggestionRunKey.authorSuggestionId`), so accept/reject addresses
/// all cards at once.
final class BlacklistSuggestion {
  const BlacklistSuggestion({
    required this.authorSuggestionId,
    required this.authorUid,
    required this.state,
    required this.violationCount,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.threshold,
    required this.windowDays,
    this.snoozedUntilMs,
    this.snoozeCount = 0,
    this.reasonCodes = const <String>{},
    this.decidedAtMs,
    this.decidedBy,
    this.revision = 0,
  });

  final String authorSuggestionId;
  final String authorUid;

  final SuggestionState state;

  /// Monotonic write revision of this record.
  ///
  /// Every store write of this record stamps one past the revision it
  /// observed, so two machine instances that reconciled the same author can be
  /// ordered without trusting their own caches or clocks: the higher revision
  /// is the write that saw more of the stored history. Records persisted before
  /// this field existed decode as 0, which is exactly "no write ordering
  /// information yet" and loses only to a record that has one.
  final int revision;

  /// Attributable violations counted when this suggestion settled.
  final int violationCount;

  final int createdAtMs;
  final int updatedAtMs;

  /// Threshold that was in force; recorded so a suggestion can be explained
  /// against the policy that produced it.
  final int threshold;

  /// Window that was in force, in days.
  final int windowDays;

  /// End of the snooze cooldown; null unless [state] is [SuggestionState.snoozed].
  final int? snoozedUntilMs;

  /// How many times this author has been snoozed. Past
  /// `SuggestionPolicy.snoozeRepeatLimit` the machine stops treating snooze as
  /// "ask me later".
  final int snoozeCount;

  final Set<String> reasonCodes;

  /// When the user's decision landed; null while the machine owns the state.
  final int? decidedAtMs;

  /// Who decided: `user` for a manual decision. Kept so a future automated path
  /// can never be confused with a user's own choice.
  final String? decidedBy;

  /// Whether the card may render.
  bool get isRenderable => state.isRenderable;

  /// Whether the suggestion is still inside its snooze cooldown at [nowMs].
  bool isSnoozedAt(int nowMs) {
    final until = snoozedUntilMs;
    return state == SuggestionState.snoozed && until != null && nowMs < until;
  }

  /// Copies with overrides. `clearSnooze` drops [snoozedUntilMs].
  BlacklistSuggestion copyWith({
    SuggestionState? state,
    int? violationCount,
    int? updatedAtMs,
    int? threshold,
    int? windowDays,
    int? snoozedUntilMs,
    bool clearSnooze = false,
    int? snoozeCount,
    Set<String>? reasonCodes,
    int? decidedAtMs,
    bool clearDecidedAt = false,
    String? decidedBy,
    bool clearDecidedBy = false,
    int? revision,
  }) => BlacklistSuggestion(
    revision: revision ?? this.revision,
    authorSuggestionId: authorSuggestionId,
    authorUid: authorUid,
    state: state ?? this.state,
    violationCount: violationCount ?? this.violationCount,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    threshold: threshold ?? this.threshold,
    windowDays: windowDays ?? this.windowDays,
    snoozedUntilMs: clearSnooze
        ? null
        : (snoozedUntilMs ?? this.snoozedUntilMs),
    snoozeCount: snoozeCount ?? this.snoozeCount,
    reasonCodes: reasonCodes ?? this.reasonCodes,
    decidedAtMs: clearDecidedAt ? null : (decidedAtMs ?? this.decidedAtMs),
    decidedBy: clearDecidedBy ? null : (decidedBy ?? this.decidedBy),
  );

  /// Persisted shape.
  Map<String, Object?> toJson() => <String, Object?>{
    'authorSuggestionId': authorSuggestionId,
    'authorUid': authorUid,
    'state': state.wireName,
    'violationCount': violationCount,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
    'threshold': threshold,
    'windowDays': windowDays,
    if (snoozedUntilMs != null) 'snoozedUntilMs': snoozedUntilMs,
    'snoozeCount': snoozeCount,
    'reasonCodes': (reasonCodes.toList()..sort()),
    if (decidedAtMs != null) 'decidedAtMs': decidedAtMs,
    if (decidedBy != null) 'decidedBy': decidedBy,
    'revision': revision,
  };

  /// Decodes [toJson]; null when a required field is unusable, which the
  /// repository reports as corrupt rather than as a silent miss.
  static BlacklistSuggestion? fromJson(Map<String, Object?> json) {
    final authorSuggestionId = json['authorSuggestionId'];
    final authorUid = json['authorUid'];
    final violationCount = json['violationCount'];
    final createdAtMs = json['createdAtMs'];
    final updatedAtMs = json['updatedAtMs'];
    final threshold = json['threshold'];
    final windowDays = json['windowDays'];
    final state = enumByWireName<SuggestionState>(
      SuggestionState.values,
      json['state'] is String ? json['state']! as String : null,
    );
    if (authorSuggestionId is! String ||
        authorSuggestionId.isEmpty ||
        authorUid is! String ||
        authorUid.isEmpty ||
        state == null ||
        violationCount is! int ||
        createdAtMs is! int ||
        updatedAtMs is! int ||
        threshold is! int ||
        windowDays is! int) {
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
    final snoozedUntilMs = json['snoozedUntilMs'];
    final snoozeCount = json['snoozeCount'];
    final decidedAtMs = json['decidedAtMs'];
    final decidedBy = json['decidedBy'];
    final revision = json['revision'];
    return BlacklistSuggestion(
      authorSuggestionId: authorSuggestionId,
      authorUid: authorUid,
      state: state,
      violationCount: violationCount,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      threshold: threshold,
      windowDays: windowDays,
      snoozedUntilMs: snoozedUntilMs is int ? snoozedUntilMs : null,
      snoozeCount: snoozeCount is int ? snoozeCount : 0,
      reasonCodes: Set<String>.unmodifiable(reasonCodes),
      decidedAtMs: decidedAtMs is int ? decidedAtMs : null,
      decidedBy: decidedBy is String ? decidedBy : null,
      // A record written before this field existed is revision 0: it carries
      // no ordering information, which must not read as a corrupt entry.
      revision: revision is int && revision >= 0 ? revision : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlacklistSuggestion &&
          authorSuggestionId == other.authorSuggestionId &&
          authorUid == other.authorUid &&
          state == other.state &&
          violationCount == other.violationCount &&
          createdAtMs == other.createdAtMs &&
          updatedAtMs == other.updatedAtMs &&
          threshold == other.threshold &&
          windowDays == other.windowDays &&
          snoozedUntilMs == other.snoozedUntilMs &&
          snoozeCount == other.snoozeCount &&
          decidedAtMs == other.decidedAtMs &&
          decidedBy == other.decidedBy &&
          revision == other.revision &&
          _setEquals(reasonCodes, other.reasonCodes);

  @override
  int get hashCode => Object.hash(
    authorSuggestionId,
    authorUid,
    state,
    violationCount,
    createdAtMs,
    updatedAtMs,
    threshold,
    windowDays,
    snoozedUntilMs,
    snoozeCount,
    decidedAtMs,
    decidedBy,
    revision,
    Object.hashAllUnordered(reasonCodes),
  );

  /// Resolves two readings of the same author suggestion into the record in
  /// force.
  ///
  /// This is the merge rule that makes a stale second instance harmless. It is a
  /// pure function of the two records, so it needs no lock, no clock and no
  /// shared cache:
  ///
  /// 1. **The higher [revision] is the later write, whoever wrote it.** A stale
  ///    cache by definition holds an older revision than the store, so the
  ///    stored record wins and a reconciliation computed from pre-rejection
  ///    counts cannot resurrect a rejected author. The same rule lets a real
  ///    later transition — [unaccept], or a reset followed by a new evaluation —
  ///    beat the rejection or acceptance it replaced, because those paths write
  ///    a higher revision.
  /// 2. **At equal revision a terminal user decision outranks an automatic
  ///    state.** [SuggestionState.accepted] and [SuggestionState.rejected] are
  ///    the two states no engine transition may produce, so on a tie they are
  ///    the side that reflects a decision rather than a guess. This is also what
  ///    protects records persisted before [revision] existed: they all carry 0.
  /// 3. Everything else falls to [compareTo], a total field order.
  ///
  /// The result is a total order, so two instances that read the same stored
  /// value and merge in either direction reach the same record.
  BlacklistSuggestion resolveAgainst(BlacklistSuggestion other) {
    if (identical(this, other) || this == other) {
      return this;
    }
    if (revision != other.revision) {
      return revision > other.revision ? this : other;
    }
    final mineTerminal = state.isTerminalDecision;
    final theirsTerminal = other.state.isTerminalDecision;
    if (mineTerminal != theirsTerminal) {
      return mineTerminal ? this : other;
    }
    return compareTo(other) <= 0 ? this : other;
  }

  /// Deterministic ordering of two readings of one author suggestion.
  ///
  /// Newer write first by the rules documented on [resolveAgainst]; the final
  /// comparisons exist only so the order is total, which is what makes
  /// [resolveAgainst] independent of merge direction. Every step is a pure
  /// field comparison — no clock, no store, no cache.
  int compareTo(BlacklistSuggestion other) {
    if (revision != other.revision) {
      return other.revision.compareTo(revision);
    }
    if (updatedAtMs != other.updatedAtMs) {
      return other.updatedAtMs.compareTo(updatedAtMs);
    }
    if (decidedAtMs != other.decidedAtMs) {
      final mine = decidedAtMs ?? -1;
      final theirs = other.decidedAtMs ?? -1;
      return theirs.compareTo(mine);
    }
    if (violationCount != other.violationCount) {
      return other.violationCount.compareTo(violationCount);
    }
    if (state != other.state) {
      return state.index.compareTo(other.state.index);
    }
    if (snoozeCount != other.snoozeCount) {
      return other.snoozeCount.compareTo(snoozeCount);
    }
    return authorSuggestionId.compareTo(other.authorSuggestionId);
  }

  @override
  String toString() =>
      'BlacklistSuggestion($authorUid, ${state.wireName}, '
      'count: $violationCount/$threshold, rev: $revision)';
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final item in a) {
    if (!b.contains(item)) return false;
  }
  return true;
}
