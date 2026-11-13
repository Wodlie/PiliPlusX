/// The precedence ladder a composed decision is resolved through.
///
/// The composer never votes: it walks a fixed ladder from the highest authority
/// to the lowest and the first rung that answers decides the row (plan-core
/// section 4). Declaring the ladder as data keeps the order reviewable in one
/// place instead of being implied by the shape of an if-chain.
///
/// Rungs, strongest first:
///
/// 1. [DecisionPrecedence.manualOverride] — the user restored or allowed it.
/// 2. [DecisionPrecedence.authorWhitelist] — the author is on the allow list.
/// 3. [DecisionPrecedence.followedExemption] — the author is followed and the
///    exemption is configured on.
/// 4. [DecisionPrecedence.ruleAllow] — a rule applied an allow action, which the
///    engine reports as [PolicyTrace.shortCircuitedBy].
/// 5. [DecisionPrecedence.hidingActions] — accumulated hide / collapse /
///    maskMedia, strongest wins.
/// 6. [DecisionPrecedence.uncertainty] — an undecidable verdict: never a pass.
/// 7. [DecisionPrecedence.failureFallback] — an execution failure: the static
///    rules that already ran stand, and the row is never reported as passed.
library;

import 'package:PiliPlus/services/content_guard/policy/policy_engine.dart';

/// A user action that outranks every rule and every exemption.
enum ManualOverride {
  /// No manual action is in force.
  none('none'),

  /// The user restored content a rule had collapsed or hidden.
  restored('restored'),

  /// The user allowed this content (or its author) permanently.
  permanentlyAllowed('permanently_allowed');

  const ManualOverride(this.wireName);

  /// Stable machine name used by reason codes and storage. Frozen.
  final String wireName;

  /// Whether a manual action is in force.
  bool get isActive => this != none;
}

/// One rung of the precedence ladder.
enum DecisionPrecedence {
  manualOverride(1, 'manual_override'),
  authorWhitelist(2, 'author_whitelist'),
  followedExemption(3, 'followed_exemption'),
  ruleAllow(4, 'rule_allow'),
  hidingActions(5, 'hiding_actions'),
  uncertainty(6, 'uncertainty'),
  failureFallback(7, 'failure_fallback');

  const DecisionPrecedence(this.rank, this.wireName);

  /// Ladder position, 1 being the strongest.
  ///
  /// Ordinal only: it orders rungs for review and is never persisted as a
  /// decision value.
  final int rank;

  /// Stable machine name used in explanations and traces. Frozen.
  final String wireName;
}

/// Stable machine reason codes the decision layer reports.
///
/// Codes, never prose and never content text: they are what a UI localises and
/// what a persisted record keeps. Renaming one is a schema change.
abstract final class DecisionReasonCodes {
  /// Nothing applied a disposition: the content is allowed.
  static const String allowed = 'decision.allowed';

  /// The user restored the content.
  static const String manualRestored = 'manual.restored';

  /// The user allowed the content permanently.
  static const String manualPermanentlyAllowed = 'manual.permanently_allowed';

  /// The author is on the allow list.
  static const String authorWhitelisted = 'author.whitelisted';

  /// The author is followed and the exemption is enabled.
  static const String authorFollowedExempt = 'author.followed_exempt';

  /// Base code for a rule-level allow; see [ruleAllow].
  static const String ruleAllowBase = 'rule.allow';

  /// Base code for a rule-level hide; see [hidingRule].
  static const String ruleHideBase = 'rule.hide';

  /// Base code for a rule-level collapse; see [hidingRule].
  static const String ruleCollapseBase = 'rule.collapse';

  /// Base code for a rule-level media mask; see [hidingRule].
  static const String ruleMaskMediaBase = 'rule.mask_media';

  /// An operator could not decide. Never a pass.
  static const String verdictUnknown = 'verdict.unknown';

  /// An operator failed (execution, parsing, timeout). Never a pass.
  static const String verdictError = 'verdict.error';

  /// Reason code for [override].
  static String manual(ManualOverride override) => switch (override) {
    ManualOverride.restored => manualRestored,
    ManualOverride.permanentlyAllowed => manualPermanentlyAllowed,
    ManualOverride.none => allowed,
  };

  /// Reason code an allow action of [ruleId] reports.
  static String ruleAllow(String ruleId) => ruleAllowBase + ':' + ruleId;

  /// Base code of the hiding disposition [disposition].
  static String hidingBase(ContentDisposition disposition) =>
      switch (disposition) {
        ContentDisposition.hide => ruleHideBase,
        ContentDisposition.collapse => ruleCollapseBase,
        ContentDisposition.maskMedia => ruleMaskMediaBase,
        ContentDisposition.allow => allowed,
      };
}
