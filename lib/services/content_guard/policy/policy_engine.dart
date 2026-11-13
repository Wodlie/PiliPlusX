/// Evaluates a rule set against content and produces an inspectable trace.
///
/// The engine is the only place that turns rule data into a disposition. It
/// owns four pieces of semantics, all of them contractual:
///
/// ## 1. Order
///
/// Rules are evaluated by descending [RuleDefinition.priority]. Equal priorities
/// keep declaration order — the order the documents were listed in — which is
/// what makes a rule file readable as an ordered policy rather than a set.
///
/// ## 2. Unresolved conditions are not "did not match"
///
/// A rule whose condition is unknown applies its own
/// [RuleDefinition.unknownAction]; a rule whose condition is in error applies its
/// own [RuleDefinition.errorAction]. Neither is silently dropped, and neither is
/// folded into "did not match". This is the single most important behaviour in
/// this file: an operator that is missing from the build must not turn into a
/// silent allow (plan-core section 2.3).
///
/// ## 3. How actions compose
///
/// * [HideAction], [CollapseAction], [MaskMediaAction] **accumulate**. They are
///   never undone by a later rule.
/// * [SetTagAction] and [SetScoreAction] **accumulate** (tags are added, scores
///   are summed).
/// * [ContinueAction] applies nothing and evaluation proceeds.
/// * [SkipAction] skips the remaining rules of its group, and only that group.
/// * [EvaluateAction] invokes an operator for its verdict without deciding
///   anything; the verdict is recorded so a later rule can compare against it.
/// * [AllowAction] **short-circuits**: no further rule is evaluated. It is
///   stop-and-permit, not an override — a hiding action accumulated earlier still
///   decides the disposition, because rule order is a declared precedence and a
///   later rule must not resurrect hidden content.
///
/// ## 4. Disposition precedence
///
/// When several hiding actions accumulate, the strongest wins:
/// [ContentDisposition.hide] over [ContentDisposition.collapse] over
/// [ContentDisposition.maskMedia]. Every accumulated action stays in the trace, so
/// "hidden, and this rule also wanted to collapse it" remains visible to the UI.
library;

import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/policy/policy_evaluator.dart';
import 'package:PiliPlus/services/content_guard/policy/policy_request.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';

/// What the engine decided should happen to one piece of content.
enum ContentDisposition {
  /// Show it normally.
  allow,

  /// Show a placeholder the user can expand.
  collapse,

  /// Do not show it.
  hide,

  /// Show the content but mask the listed media roles.
  maskMedia;

  /// Stable machine name for traces, storage and the UI.
  String get wireName => name;

  /// Whether this disposition removes content from view entirely.
  bool get isHidden => this == hide;
}

/// Outcome of evaluating one rule, including the rules that did not fire.
enum RuleVerdict {
  /// A disabled rule: kept, shown, never evaluated.
  disabled,

  /// A rule whose group was skipped before it was reached.
  skipped,

  /// The condition positively did not hold.
  notMatched,

  /// The condition held; [RuleDefinition.then] was applied.
  matched,

  /// The condition could not be decided; [RuleDefinition.unknownAction] was
  /// applied instead of any match action.
  unknown,

  /// Condition evaluation failed; [RuleDefinition.errorAction] was applied
  /// instead of any match action.
  error;

  /// Stable machine name for traces and the rule-testing UI.
  String get wireName => name;
}

/// One rule's contribution to a pass.
final class RuleTrace {
  const RuleTrace({
    required this.rule,
    required this.declarationIndex,
    required this.verdict,
    this.condition,
    this.appliedAction,
    this.operatorVerdict,
    this.note,
  });

  final RuleDefinition rule;

  /// Position of [rule] in the *declaration* order the engine received, before
  /// priority sorting. Recorded so a trace can be read against the rule file.
  final int declarationIndex;

  final RuleVerdict verdict;

  /// Condition tree, present whenever the condition was evaluated.
  final NodeEvaluation? condition;

  /// Action actually applied: [RuleDefinition.then] for [RuleVerdict.matched],
  /// [RuleDefinition.unknownAction] / [RuleDefinition.errorAction] otherwise,
  /// and null when nothing was applied.
  final RuleAction? appliedAction;

  /// Verdict an [EvaluateAction] produced, if this rule's action was one.
  final FilterResult? operatorVerdict;

  /// Stable machine note, used for skips and disabled rules.
  final String? note;

  /// Whether this rule positively matched.
  bool get didMatch => verdict == RuleVerdict.matched;

  /// Whether this rule's condition could not be decided (unknown or error).
  bool get isUnresolved =>
      verdict == RuleVerdict.unknown || verdict == RuleVerdict.error;

  @override
  String toString() =>
      'RuleTrace(${rule.id}, ${verdict.wireName}'
      '${appliedAction == null ? '' : ', ${appliedAction!.actionType}'})';
}

/// Everything a pass decided, in a shape a UI can render without re-running it.
///
/// The trace is the rule-testing surface's data source: it names the rules that
/// fired, the rules that did not, every operator verdict consulted, every action
/// accumulated and the final disposition. It never contains raw content text —
/// content is referenced by id and version only — so a trace is safe to log.
final class PolicyTrace {
  const PolicyTrace({
    required this.contentId,
    required this.contentVersion,
    required this.ruleVersion,
    required this.generation,
    required this.rules,
    required this.disposition,
    required this.hidingActions,
    required this.tags,
    required this.score,
    required this.operatorVerdicts,
    required this.skippedGroups,
    this.shortCircuitedBy,
  });

  final String contentId;

  final String contentVersion;

  /// Rule-set version the pass ran under, from the request's run context.
  final String ruleVersion;

  /// List generation the pass ran under, from the request's run context.
  final int generation;

  /// One entry per rule in evaluation order, including rules that did not fire.
  final List<RuleTrace> rules;

  final ContentDisposition disposition;

  /// Hiding actions that accumulated, in application order. Non-empty does not
  /// imply [disposition] equals the strongest entry — see the class docs on
  /// precedence.
  final List<RuleAction> hidingActions;

  /// Tags accumulated, in application order and de-duplicated.
  final List<String> tags;

  /// Sum of every [SetScoreAction] contribution.
  final double score;

  /// Every operator verdict consulted during the pass, keyed by operator id.
  final Map<String, FilterResult> operatorVerdicts;

  /// Groups whose remaining rules were skipped by a [SkipAction].
  final List<String> skippedGroups;

  /// Id of the rule whose [AllowAction] stopped evaluation, when one did.
  final String? shortCircuitedBy;

  /// Media roles masked by accumulated [MaskMediaAction]s; empty means "all
  /// attached media" when they stacked without naming roles, and no masking when
  /// [disposition] is not [ContentDisposition.maskMedia].
  Set<MediaType> get maskedMediaTypes {
    final result = <MediaType>{};
    for (final action in hidingActions) {
      if (action is MaskMediaAction) result.addAll(action.mediaTypes);
    }
    return Set<MediaType>.unmodifiable(result);
  }

  /// Rules that positively matched, in evaluation order.
  List<RuleTrace> get matchedRules => [
    for (final entry in rules)
      if (entry.didMatch) entry,
  ];

  /// Rules whose condition could not be decided, in evaluation order.
  List<RuleTrace> get unresolvedRules => [
    for (final entry in rules)
      if (entry.isUnresolved) entry,
  ];

  /// Whether any rule's condition could not be decided.
  ///
  /// A UI is expected to surface this: a hidden item whose reason is "the
  /// classifier is not installed" is a different message from a positive match.
  bool get hasUnresolvedRules => unresolvedRules.isNotEmpty;

  /// Whether the content is shown normally.
  bool get isAllowed => disposition == ContentDisposition.allow;

  @override
  String toString() =>
      'PolicyTrace($contentId v$contentVersion, ${disposition.wireName}, '
      'rules: ${rules.length}, matched: ${matchedRules.length}, '
      'unresolved: ${unresolvedRules.length}, '
      'operators: ${operatorVerdicts.length})';
}

/// The rule engine.
///
/// Holds an immutable, ordered rule set plus the resolver that turns an operator
/// id into an implementation, and produces a [PolicyTrace] per
/// [PolicyRequest]. It stores nothing and caches nothing across passes.
final class PolicyEngine {
  PolicyEngine(List<RuleDefinition> rules, this._resolver)
    : _ordered = _order(rules);

  /// A rule set with no rules: every content item is allowed.
  PolicyEngine.empty(this._resolver) : _ordered = const <_OrderedRule>[];

  final FilterOperatorResolver _resolver;

  final List<_OrderedRule> _ordered;

  /// Rules in evaluation order (priority descending, then declaration order).
  List<RuleDefinition> get rules =>
      List<RuleDefinition>.unmodifiable(_ordered.map((entry) => entry.rule));

  /// Whether the set is empty.
  bool get isEmpty => _ordered.isEmpty;

  /// Number of rules, disabled ones included.
  int get length => _ordered.length;

  /// Evaluates every applicable rule against [request].
  ///
  /// Creates a fresh [PolicyEvaluator] per pass, so operator verdicts are shared
  /// within the pass and never across passes.
  Future<PolicyTrace> evaluate(PolicyRequest request) async {
    final evaluator = PolicyEvaluator(_resolver);
    final traces = <RuleTrace>[];
    final hidingActions = <RuleAction>[];
    final tags = <String>[];
    final skippedGroups = <String>[];
    var scoreTotal = 0.0;
    String? shortCircuitedBy;

    for (final entry in _ordered) {
      final rule = entry.rule;
      if (!rule.enabled) {
        traces.add(
          RuleTrace(
            rule: rule,
            declarationIndex: entry.declarationIndex,
            verdict: RuleVerdict.disabled,
            note: _notes.disabled,
          ),
        );
        continue;
      }
      if (skippedGroups.contains(rule.group)) {
        traces.add(
          RuleTrace(
            rule: rule,
            declarationIndex: entry.declarationIndex,
            verdict: RuleVerdict.skipped,
            note: _notes.groupSkipped,
          ),
        );
        continue;
      }

      final condition = await evaluator.evaluate(rule.when, request);
      switch (condition.outcome) {
        case ConditionOutcome.unsatisfied:
          traces.add(
            RuleTrace(
              rule: rule,
              declarationIndex: entry.declarationIndex,
              verdict: RuleVerdict.notMatched,
              condition: condition,
            ),
          );
          continue;
        case ConditionOutcome.satisfied:
        case ConditionOutcome.unknown:
        case ConditionOutcome.error:
          break;
      }

      final verdict = switch (condition.outcome) {
        ConditionOutcome.satisfied => RuleVerdict.matched,
        ConditionOutcome.unknown => RuleVerdict.unknown,
        ConditionOutcome.error => RuleVerdict.error,
        ConditionOutcome.unsatisfied => RuleVerdict.notMatched,
      };
      final action = switch (verdict) {
        RuleVerdict.matched => rule.then,
        RuleVerdict.unknown => rule.unknownAction,
        RuleVerdict.error => rule.errorAction,
        RuleVerdict.notMatched ||
        RuleVerdict.skipped ||
        RuleVerdict.disabled => null,
      };

      FilterResult? operatorVerdict;
      var shortCircuits = false;
      if (action != null) {
        switch (action) {
          case AllowAction():
            shortCircuits = true;
          case HideAction():
          case CollapseAction():
          case MaskMediaAction():
            hidingActions.add(action);
          case ContinueAction():
            break;
          case SkipAction(:final ruleGroup):
            if (!skippedGroups.contains(ruleGroup)) {
              skippedGroups.add(ruleGroup);
            }
          case SetTagAction(:final tag):
            if (!tags.contains(tag)) tags.add(tag);
          case SetScoreAction(score: final contribution):
            scoreTotal += contribution;
          case EvaluateAction(:final operatorId):
            operatorVerdict = await evaluator.verdicts.resolve(
              operatorId,
              request,
            );
        }
      }

      traces.add(
        RuleTrace(
          rule: rule,
          declarationIndex: entry.declarationIndex,
          verdict: verdict,
          condition: condition,
          appliedAction: action,
          operatorVerdict: operatorVerdict,
        ),
      );
      if (shortCircuits) {
        shortCircuitedBy = rule.id;
        break;
      }
    }

    return PolicyTrace(
      contentId: request.content.contentId,
      contentVersion: request.content.contentVersion,
      ruleVersion: request.runContext.ruleVersion,
      generation: request.runContext.generation,
      rules: List<RuleTrace>.unmodifiable(traces),
      disposition: _dispositionOf(hidingActions),
      hidingActions: List<RuleAction>.unmodifiable(hidingActions),
      tags: List<String>.unmodifiable(tags),
      score: scoreTotal,
      operatorVerdicts: evaluator.verdicts.verdicts,
      skippedGroups: List<String>.unmodifiable(skippedGroups),
      shortCircuitedBy: shortCircuitedBy,
    );
  }

  /// Strongest accumulated hiding action, or [ContentDisposition.allow].
  ///
  /// Note the ordering rule from the class docs: an allow that short-circuited
  /// does not clear an accumulation that already happened.
  static ContentDisposition _dispositionOf(List<RuleAction> hidingActions) {
    var disposition = ContentDisposition.allow;
    for (final action in hidingActions) {
      final candidate = switch (action) {
        HideAction() => ContentDisposition.hide,
        CollapseAction() => ContentDisposition.collapse,
        MaskMediaAction() => ContentDisposition.maskMedia,
        _ => ContentDisposition.allow,
      };
      if (_strength(candidate) > _strength(disposition)) {
        disposition = candidate;
      }
    }
    return disposition;
  }

  static int _strength(ContentDisposition disposition) => switch (disposition) {
    ContentDisposition.allow => 0,
    ContentDisposition.maskMedia => 1,
    ContentDisposition.collapse => 2,
    ContentDisposition.hide => 3,
  };

  static List<_OrderedRule> _order(List<RuleDefinition> rules) {
    final indexed = <_OrderedRule>[
      for (var index = 0; index < rules.length; index++)
        _OrderedRule(rule: rules[index], declarationIndex: index),
    ];
    // List.sort is not guaranteed stable, so the declaration index is an
    // explicit secondary key: a rule file must evaluate the same way twice.
    indexed.sort((a, b) {
      final byPriority = b.rule.priority.compareTo(a.rule.priority);
      if (byPriority != 0) return byPriority;
      return a.declarationIndex.compareTo(b.declarationIndex);
    });
    return List<_OrderedRule>.unmodifiable(indexed);
  }
}

/// A rule plus its position in the declaration order it arrived in.
final class _OrderedRule {
  const _OrderedRule({required this.rule, required this.declarationIndex});

  final RuleDefinition rule;

  final int declarationIndex;
}

/// Stable machine notes attached to a trace entry.
abstract final class _notes {
  static const String disabled = 'rule.disabled';
  static const String groupSkipped = 'rule.group_skipped';
}
