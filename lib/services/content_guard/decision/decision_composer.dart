/// Merges rule verdicts, exemptions and manual actions into one decision.
///
/// The composer is the only place that decides *what a row looks like*. It reads
/// a [PolicyTrace] and never evaluates anything itself, so a merged decision is
/// always explainable by the trace it came from.
///
/// ## Precedence (plan-core section 4)
///
/// Rungs are walked in order declared by [DecisionPrecedence]; the first rung
/// that answers decides:
///
/// 1. manual restore / manual allow — beats everything.
/// 2. author whitelist.
/// 3. followed author, only when the exemption is configured on.
/// 4. a rule-level allow ([PolicyTrace.shortCircuitedBy] != null).
/// 5. accumulated hiding actions, strongest wins: hide > collapse > maskMedia.
/// 6. an unknown verdict — [PresenterState.uncertain], never hidden and never
///    silently allowed.
/// 7. an error or timeout — the static rules that already ran stand, the row is
///    [PresenterState.uncertain], and it is never reported as passed.
///
/// Two interactions are worth stating because they are easy to get wrong:
///
/// * A rule-level allow (rung 4) outranks a hiding action accumulated earlier
///   (rung 5): an explicit permit is the stronger statement, and the engine has
///   already stopped evaluating.
/// * A hiding action (rung 5) outranks an unresolved verdict (rungs 6/7): once a
///   rule positively hid the content there is nothing left to be uncertain about.
///
/// ## Attribution
///
/// [DecisionComposerOutput.attributeViolation] is true only when a rule that
/// positively matched — and whose applied action actually hid something —
/// declared [RuleDefinition.attributeViolation]. It answers "may this be
/// attributed?", it does not record anything; writing a violation record is a
/// separate, later step, and a manual allow always answers false.
///
/// Two consequences are load-bearing:
///
/// * An unknown or error verdict is never attributable. [RuleVerdict] says the
///   condition could not be decided, so the action that was applied is a
///   fallback; an accusation cannot rest on a fallback, however the rule is
///   configured.
/// * Every matched rule that contributed a hiding action counts, not only the
///   one whose action determined the presentation. A weaker collapse that
///   matched and hid the body is still a positive finding when a stronger hide
///   wins the row.
library;

import 'package:PiliPlus/services/content_guard/decision/decision_precedence.dart';
import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/media_ref.dart';
import 'package:PiliPlus/services/content_guard/policy/policy_engine.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';

/// Everything a caller needs to render one decision, and to explain it.
///
/// The carrier is deliberately flat and code-only: no content text, no media
/// URL and no prose, so a decision is safe to log, persist and hand to a UI.
/// The const constructor does not copy its collections — producers pass
/// unmodifiable values.
final class DecisionComposerOutput {
  const DecisionComposerOutput({
    required this.disposition,
    required this.presentationState,
    required this.tags,
    required this.maskedMediaIds,
    required this.hits,
    required this.attributeViolation,
    required this.violationReasonCodes,
    required this.recoverable,
    required this.explanation,
  });

  /// What the rules decided. Kept alongside [presentationState] because the two
  /// differ by design: an [ContentDisposition.allow] with an unresolved verdict
  /// yields [PresenterState.uncertain], and a caller that only looked at the
  /// disposition would read that as a pass.
  final ContentDisposition disposition;

  /// What the list renders.
  final PresenterState presentationState;

  /// Tags the rule pass accumulated, de-duplicated by the engine.
  final Set<String> tags;

  /// Media identities to mask ([MediaRef.stableKey], never a URL). Empty unless
  /// [presentationState] is [PresenterState.masked].
  final Set<String> maskedMediaIds;

  /// Every consulted verdict that is not a clean negative, in first-consult
  /// order: matches, unknowns and errors. A clean [FilterStatus.notMatched] is
  /// not a hit and is not reported.
  final List<FilterResult> hits;

  /// Whether a violation may be attributed to the author.
  ///
  /// A permission, not a record: nothing has been written anywhere, and the
  /// ledger decides separately whether to act on it (plan-core section 6.2).
  final bool attributeViolation;

  /// Stable reason codes of the rule that decided against the content.
  ///
  /// Empty when nothing identified a problem (allowed, masked or uncertain).
  final Set<String> violationReasonCodes;

  /// Whether the user can lift what is shown here.
  final bool recoverable;

  /// Short, code-only explanation (see [DecisionReasonCodes]). Never raw
  /// content text, never a media URL.
  final String? explanation;

  /// Whether the row is shown normally.
  bool get isAllowed => presentationState == PresenterState.allowed;

  /// Whether the row is hidden.
  bool get isHidden => presentationState == PresenterState.hidden;

  /// Whether the row exposes its body (possibly with masked media).
  bool get showsBody => presentationState.showsBody;

  /// Whether the decision could not be settled.
  bool get isUncertain => presentationState == PresenterState.uncertain;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecisionComposerOutput &&
          disposition == other.disposition &&
          presentationState == other.presentationState &&
          attributeViolation == other.attributeViolation &&
          recoverable == other.recoverable &&
          explanation == other.explanation &&
          _setEquals(tags, other.tags) &&
          _setEquals(maskedMediaIds, other.maskedMediaIds) &&
          _setEquals(violationReasonCodes, other.violationReasonCodes) &&
          _listEquals(hits, other.hits);

  @override
  int get hashCode => Object.hash(
    disposition,
    presentationState,
    attributeViolation,
    recoverable,
    explanation,
    Object.hashAllUnordered(tags),
    Object.hashAllUnordered(maskedMediaIds),
    Object.hashAllUnordered(violationReasonCodes),
    Object.hashAll(hits),
  );

  @override
  String toString() {
    final dispositionWire = disposition.wireName;
    final stateWire = presentationState.wireName;
    return 'DecisionComposerOutput($dispositionWire, $stateWire, '
            'hits: ' +
        hits.length.toString() +
        ', '
            'attributeViolation: $attributeViolation, '
            'recoverable: $recoverable, explanation: $explanation)';
  }
}

/// The merge contract every composer implementation answers to.
abstract interface class DecisionComposer {
  /// Merges [trace] into one decision for [content].
  ///
  /// [manualOverride], [authorWhitelisted] and [authorFollowed] are caller
  /// facts, never inferred here: the composer has no access to account state,
  /// follow lists or stored preferences, which is what keeps it a pure function
  /// of its arguments.
  DecisionComposerOutput compose({
    required GuardContent content,
    required PolicyTrace trace,
    required ManualOverride manualOverride,
    required bool authorWhitelisted,
    required bool authorFollowed,
  });
}

/// The default merge: the precedence ladder, implemented once.
final class DefaultDecisionComposer implements DecisionComposer {
  const DefaultDecisionComposer({this.followedExempt = true});

  /// Whether following an author exempts their content.
  ///
  /// A user setting, so it is a constructor flag rather than a constant: with it
  /// off, [authorFollowed] is simply not a rung and the rule pass decides.
  final bool followedExempt;

  @override
  DecisionComposerOutput compose({
    required GuardContent content,
    required PolicyTrace trace,
    required ManualOverride manualOverride,
    required bool authorWhitelisted,
    required bool authorFollowed,
  }) {
    final tags = Set<String>.unmodifiable(trace.tags);
    final hits = _hitsOf(trace);

    // Rung 1 - a manual action beats every rule, exemption and verdict.
    if (manualOverride.isActive) {
      return DecisionComposerOutput(
        disposition: ContentDisposition.allow,
        presentationState: PresenterState.allowed,
        tags: tags,
        maskedMediaIds: const <String>{},
        hits: hits,
        attributeViolation: false,
        violationReasonCodes: const <String>{},
        recoverable: true,
        explanation: _explain(DecisionPrecedence.manualOverride, <String>[
          DecisionReasonCodes.manual(manualOverride),
        ]),
      );
    }

    // Rung 2 - the author is on the allow list.
    if (authorWhitelisted) {
      return _allowedBy(
        precedence: DecisionPrecedence.authorWhitelist,
        code: DecisionReasonCodes.authorWhitelisted,
        tags: tags,
        hits: hits,
      );
    }

    // Rung 3 - a followed author, when the exemption is configured on.
    if (authorFollowed && followedExempt) {
      return _allowedBy(
        precedence: DecisionPrecedence.followedExemption,
        code: DecisionReasonCodes.authorFollowedExempt,
        tags: tags,
        hits: hits,
      );
    }

    // Rung 4 - a rule applied an allow action; the engine already stopped.
    final allowRuleId = trace.shortCircuitedBy;
    if (allowRuleId != null) {
      return _allowedBy(
        precedence: DecisionPrecedence.ruleAllow,
        code: DecisionReasonCodes.ruleAllow(allowRuleId),
        tags: tags,
        hits: hits,
      );
    }

    // Rung 5 - accumulated hiding actions, strongest wins.
    final hiding = _winningHiding(trace);
    if (hiding != null) {
      return _fromHiding(
        content: content,
        trace: trace,
        disposition: hiding,
        tags: tags,
        hits: hits,
      );
    }

    // Rungs 6 and 7 - an unresolved verdict is never a pass.
    final unresolved = _unresolvedOf(trace, hits);
    if (unresolved.hasError || unresolved.hasUnknown) {
      final isFailure = unresolved.hasError;
      return DecisionComposerOutput(
        disposition: ContentDisposition.allow,
        presentationState: PresenterState.uncertain,
        tags: tags,
        maskedMediaIds: const <String>{},
        hits: hits,
        attributeViolation: false,
        violationReasonCodes: const <String>{},
        recoverable: true,
        explanation: _explain(
          isFailure
              ? DecisionPrecedence.failureFallback
              : DecisionPrecedence.uncertainty,
          <String>[
            isFailure
                ? DecisionReasonCodes.verdictError
                : DecisionReasonCodes.verdictUnknown,
            ...unresolved.sources,
          ],
        ),
      );
    }

    // Nothing applied a disposition: the content is allowed.
    return DecisionComposerOutput(
      disposition: ContentDisposition.allow,
      presentationState: PresenterState.allowed,
      tags: tags,
      maskedMediaIds: const <String>{},
      hits: hits,
      attributeViolation: false,
      violationReasonCodes: const <String>{},
      recoverable: false,
      explanation: DecisionReasonCodes.allowed,
    );
  }

  /// A row allowed by an exemption or a rule-level allow.
  ///
  /// Recoverable is false: an exemption is configuration, not a restoration, so
  /// there is no restriction on this row for the user to lift.
  static DecisionComposerOutput _allowedBy({
    required DecisionPrecedence precedence,
    required String code,
    required Set<String> tags,
    required List<FilterResult> hits,
  }) => DecisionComposerOutput(
    disposition: ContentDisposition.allow,
    presentationState: PresenterState.allowed,
    tags: tags,
    maskedMediaIds: const <String>{},
    hits: hits,
    attributeViolation: false,
    violationReasonCodes: const <String>{},
    recoverable: false,
    explanation: _explain(precedence, <String>[code]),
  );

  /// A row decided by accumulated hiding actions.
  ///
  /// [disposition] settles the presentation; attribution is read from the whole
  /// pass instead, so a weaker matched action still counts as a finding when a
  /// stronger one wins the row.
  static DecisionComposerOutput _fromHiding({
    required GuardContent content,
    required PolicyTrace trace,
    required ContentDisposition disposition,
    required Set<String> tags,
    required List<FilterResult> hits,
  }) {
    final contributors = _contributingRules(trace);
    final attribute = contributors.any(
      (entry) => entry.rule.attributeViolation,
    );
    // Reason codes describe what the row looks like, so they follow every
    // accumulated action, fallback actions included: an error that collapsed the
    // row still explains itself. Only attribution is match-gated.
    final reasonCodes = <String>{};
    for (final action in trace.hidingActions) {
      switch (action) {
        case HideAction(:final reasonCode):
        case CollapseAction(:final reasonCode):
          if (reasonCode.isNotEmpty) reasonCodes.add(reasonCode);
        case MaskMediaAction():
        case _:
          break;
      }
    }
    final state = switch (disposition) {
      ContentDisposition.hide => PresenterState.hidden,
      ContentDisposition.collapse => PresenterState.collapsed,
      ContentDisposition.maskMedia => PresenterState.masked,
      ContentDisposition.allow => PresenterState.allowed,
    };
    final codes = <String>[];
    for (final entry in contributors) {
      // Each contributor is named under its *own* disposition: a weaker collapse
      // that matched is still a collapse, even when a hide won the row.
      final own = _dispositionOf(entry.appliedAction);
      if (own == null) continue;
      codes.add(DecisionReasonCodes.hidingBase(own) + ':' + entry.rule.id);
    }
    if (codes.isEmpty) {
      codes.add(DecisionReasonCodes.hidingBase(disposition));
    }
    codes.addAll(reasonCodes);
    return DecisionComposerOutput(
      disposition: disposition,
      presentationState: state,
      tags: tags,
      maskedMediaIds: disposition == ContentDisposition.maskMedia
          ? _maskedIdsOf(content, trace)
          : const <String>{},
      hits: hits,
      attributeViolation: attribute,
      violationReasonCodes: Set<String>.unmodifiable(reasonCodes),
      recoverable: true,
      explanation: _explain(DecisionPrecedence.hidingActions, codes),
    );
  }

  /// Media identities the mask covers.
  ///
  /// A mask action that names no role means "every attached media role", which
  /// is what a rule author means by "do not show me pictures here"
  /// ([MaskMediaAction.mediaTypes]). That is a property of the pass, not of a
  /// union: one mask-all action covers everything, and a targeted action
  /// accumulated next to it cannot narrow the mask back down to a subset. Roles
  /// are unioned only when every mask action named roles.
  ///
  /// The accumulated actions are read here instead of
  /// [PolicyTrace.maskedMediaTypes] for exactly that reason: the getter unions
  /// the role sets, so an empty set plus {avatar} becomes {avatar} and the body
  /// image the rule meant to hide is exposed again.
  ///
  /// An identity is [MediaRef.stableKey]: the fingerprint when the media
  /// pipeline computed one, the platform id otherwise, never the URL. Content
  /// without media masks nothing and the row stays masked with an empty set,
  /// because silently downgrading it to allowed would undo the rule.
  static Set<String> _maskedIdsOf(GuardContent content, PolicyTrace trace) {
    final roles = <MediaType>{};
    var namedRoles = false;
    var maskAll = false;
    for (final action in trace.hidingActions) {
      if (action is! MaskMediaAction) continue;
      if (action.mediaTypes.isEmpty) {
        maskAll = true;
      } else {
        namedRoles = true;
        roles.addAll(action.mediaTypes);
      }
    }
    // A trace rebuilt from storage keeps the settled maskMedia disposition but
    // may not keep the actions behind it; an empty role set there still means
    // "every role", so the mask must not silently degrade to nothing.
    if (!namedRoles) maskAll = true;
    final ids = <String>{};
    for (final media in content.media) {
      if (maskAll || roles.contains(media.type)) ids.add(media.stableKey);
    }
    return Set<String>.unmodifiable(ids);
  }

  /// The strongest accumulated hiding disposition, or null when nothing hid.
  static ContentDisposition? _winningHiding(PolicyTrace trace) {
    var best = ContentDisposition.allow;
    for (final action in trace.hidingActions) {
      final candidate = _dispositionOf(action);
      if (candidate != null && _strength(candidate) > _strength(best)) {
        best = candidate;
      }
    }
    // Defensive: a trace rebuilt from storage may carry the settled disposition
    // without the individual actions. It must not become a silent allow.
    if (_strength(trace.disposition) > _strength(best)) {
      best = trace.disposition;
    }
    if (best == ContentDisposition.allow) return null;
    return best;
  }

  /// Matched rules whose applied action actually hid something.
  ///
  /// The pass walked in evaluation order, so this list is in application order.
  /// Provenance comes from the rule entry itself, never from matching an action
  /// value back to a rule: two rules may apply equal actions, and binding an
  /// action to the first equal-valued rule loses the attribution of the second.
  ///
  /// Only [RuleVerdict.matched] qualifies. An unknown or error verdict applied a
  /// fallback action — [RuleDefinition.unknownAction] / [RuleDefinition.errorAction]
  /// — and while that action still settles the row (rung 5 reads every
  /// accumulated action, fail-closed), it is not a finding about the content, so
  /// it cannot name itself as the cause or lend the rule's attribution.
  /// Disabled, skipped and notMatched rules applied nothing at all.
  static List<RuleTrace> _contributingRules(PolicyTrace trace) {
    final contributors = <RuleTrace>[];
    for (final entry in trace.rules) {
      if (!entry.didMatch) continue;
      if (entry.appliedAction?.isHidingAction ?? false) contributors.add(entry);
    }
    return contributors;
  }

  /// Every consulted verdict that is not a clean negative.
  static List<FilterResult> _hitsOf(PolicyTrace trace) {
    final seen = <String>{};
    final hits = <FilterResult>[];
    void consider(FilterResult? verdict) {
      if (verdict == null) return;
      if (!seen.add(verdict.operatorId)) return;
      if (verdict.status == FilterStatus.notMatched) return;
      hits.add(verdict);
    }

    for (final verdict in trace.operatorVerdicts.values) {
      consider(verdict);
    }
    for (final entry in trace.rules) {
      consider(entry.operatorVerdict);
    }
    return List<FilterResult>.unmodifiable(hits);
  }

  /// Which verdicts could not be settled.
  static _UnresolvedSummary _unresolvedOf(
    PolicyTrace trace,
    List<FilterResult> hits,
  ) {
    var hasUnknown = false;
    var hasError = false;
    final sources = <String>[];
    void note(String source) {
      if (!sources.contains(source)) sources.add(source);
    }

    for (final verdict in hits) {
      switch (verdict.status) {
        case FilterStatus.unknown:
          hasUnknown = true;
          note(verdict.operatorId);
        case FilterStatus.error:
          hasError = true;
          note(verdict.operatorId);
        case FilterStatus.matched:
        case FilterStatus.notMatched:
          break;
      }
    }
    for (final entry in trace.rules) {
      switch (entry.verdict) {
        case RuleVerdict.unknown:
          hasUnknown = true;
          note('rule:' + entry.rule.id);
        case RuleVerdict.error:
          hasError = true;
          note('rule:' + entry.rule.id);
        case RuleVerdict.matched:
        case RuleVerdict.notMatched:
        case RuleVerdict.skipped:
        case RuleVerdict.disabled:
          break;
      }
    }
    return _UnresolvedSummary(
      hasUnknown: hasUnknown,
      hasError: hasError,
      sources: List<String>.unmodifiable(sources),
    );
  }

  /// Builds the two-part, code-only explanation: ladder rung then reason codes.
  static String _explain(DecisionPrecedence precedence, List<String> codes) {
    if (codes.isEmpty) return precedence.wireName;
    return precedence.wireName + ': ' + codes.join(' + ');
  }

  static int _strength(ContentDisposition disposition) => switch (disposition) {
    ContentDisposition.allow => 0,
    ContentDisposition.maskMedia => 1,
    ContentDisposition.collapse => 2,
    ContentDisposition.hide => 3,
  };

  static ContentDisposition? _dispositionOf(RuleAction? action) =>
      switch (action) {
        HideAction() => ContentDisposition.hide,
        CollapseAction() => ContentDisposition.collapse,
        MaskMediaAction() => ContentDisposition.maskMedia,
        _ => null,
      };
}

/// Which verdicts could not be settled, and where they came from.
final class _UnresolvedSummary {
  const _UnresolvedSummary({
    required this.hasUnknown,
    required this.hasError,
    required this.sources,
  });

  final bool hasUnknown;
  final bool hasError;

  /// Operator ids, or "rule:<id>" for a rule whose condition could not be
  /// evaluated.
  final List<String> sources;
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final value in a) {
    if (!b.contains(value)) return false;
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
