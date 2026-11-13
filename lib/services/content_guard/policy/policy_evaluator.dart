/// Evaluates one [RuleNode] against one [PolicyRequest].
///
/// ## Conditions are four-valued
///
/// A condition is not a boolean. It is one of [ConditionOutcome]'s four values,
/// and the extra two are the whole reason this file exists:
///
/// * [ConditionOutcome.unsatisfied] — the engine positively determined that the
///   condition does not hold.
/// * [ConditionOutcome.unknown] — the engine cannot tell: a capability is
///   missing, an operator could not decide, or a field is absent where the
///   comparison needs a value.
/// * [ConditionOutcome.error] — evaluation failed: the operator id is not
///   resolvable, the operator threw, or a verdict the comparison depends on is
///   itself in error.
///
/// Folding [ConditionOutcome.unknown] or [ConditionOutcome.error] into
/// [ConditionOutcome.unsatisfied] is the one mistake this file must never make:
/// it would turn "the safety operator is not installed" into "this content is
/// fine" (plan-core section 2.3). Every unresolved condition therefore carries a
/// reason code up to the rule, which applies that rule's unknownAction or
/// errorAction.
///
/// ## Operators are reached through an injected resolver
///
/// This layer depends on [FilterOperator] plus [FilterOperatorResolver] and
/// nothing else. It never imports the concrete operators or the registry, so a
/// test can supply any verdict without a build variant, a model or a network.
library;

import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';
import 'package:PiliPlus/services/content_guard/policy/policy_request.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';

/// Resolves an operator id to the implementation that answers to it.
///
/// The narrowest dependency the policy layer can have on the operator layer: the
/// engine asks for one id and gets null when nothing answers. null is a
/// configuration error, never a "no match".
///
/// OperatorRegistry satisfies it structurally; a test double or a scoped
/// sub-registry does too, and neither has to be the concrete registry this build
/// bootstraps.
abstract interface class FilterOperatorResolver {
  /// The operator registered under [operatorId], or null when there is none.
  FilterOperator? resolve(String operatorId);
}

/// Four-valued result of evaluating one condition node.
enum ConditionOutcome {
  /// The condition positively holds.
  satisfied,

  /// The condition positively does not hold.
  unsatisfied,

  /// The condition could not be decided. Never a pass.
  unknown,

  /// Evaluation failed. Never a pass.
  error;

  /// Stable machine name for traces, rule-testing UI and logs.
  String get wireName => name;

  /// Whether this outcome is resolved (as opposed to unknown/error).
  bool get isResolved => this == satisfied || this == unsatisfied;
}

/// Stable reason codes the evaluator reports on unresolved conditions.
abstract final class ConditionReasonCodes {
  /// No operator is registered under the id the rule names.
  static const String operatorNotFound = 'condition.operator_not_found';

  /// The operator exists but is not dispatchable in this build.
  static const String operatorUnavailable = 'condition.operator_unavailable';

  /// The operator threw despite the contract requiring it not to.
  static const String operatorThrew = 'condition.operator_threw';

  /// The comparison cannot be applied to this value shape.
  static const String comparisonNotApplicable =
      'condition.comparison_not_applicable';
}

/// What reading one [RuleField] produced.
sealed class FieldRead {
  const FieldRead();
}

/// The field produced a value. [value] may be null for a nullable field.
final class FieldValue extends FieldRead {
  const FieldValue(this.value);

  final Object? value;

  @override
  String toString() => 'FieldValue($value)';
}

/// The field could not be read.
final class FieldUnavailable extends FieldRead {
  const FieldUnavailable({
    required this.outcome,
    required this.reasonCode,
    required this.message,
  });

  final ConditionOutcome outcome;

  final String reasonCode;

  final String message;

  @override
  String toString() => 'FieldUnavailable(${outcome.wireName}, $reasonCode)';
}

/// One node's evaluation, with enough structure to explain a decision.
///
/// The tree mirrors the rule document, so the rule-testing UI can render which
/// branch decided a verdict without re-running the engine. [children] holds the
/// children that were actually evaluated: an all/any node short-circuits on the
/// deciding child, so an absent child is a child that was skipped, not one that
/// passed.
final class NodeEvaluation {
  const NodeEvaluation({
    required this.node,
    required this.outcome,
    this.reasonCode,
    this.message,
    this.operatorId,
    this.verdict,
    this.children = const <NodeEvaluation>[],
  });

  final RuleNode node;

  final ConditionOutcome outcome;

  /// Stable machine reason for an unresolved outcome; null when resolved.
  final String? reasonCode;

  /// Human-facing explanation. Display only.
  final String? message;

  /// Operator this node consulted, for an [OperatorNode] and for an
  /// operator-derived [CompareNode].
  final String? operatorId;

  /// Verdict this node read, when it consulted an operator.
  final FilterResult? verdict;

  final List<NodeEvaluation> children;

  /// Whether the condition positively holds.
  bool get isSatisfied => outcome == ConditionOutcome.satisfied;

  /// Whether the outcome is unresolved and must route to unknownAction or
  /// errorAction.
  bool get isUnresolved => !outcome.isResolved;

  @override
  String toString() =>
      'NodeEvaluation(${node.nodeType}, ${outcome.wireName}, $reasonCode)';
}

/// Per-pass operator verdict cache.
///
/// One policy pass consults each operator at most once: two rules naming the same
/// operator must not pay for, or disagree about, a second evaluation. Unresolved
/// verdicts are cached too — re-asking an unavailable operator cannot produce a
/// different answer within one pass, and re-asking would only multiply the
/// failure.
///
/// The cache is per pass and never persisted: a verdict carries no expiry, and a
/// stale negative cached across passes is exactly the silent allow this design
/// forbids (plan-core section 8.2).
final class OperatorVerdictCache {
  OperatorVerdictCache(this._resolver);

  final FilterOperatorResolver _resolver;

  final Map<String, FilterResult> _verdicts = <String, FilterResult>{};

  final List<String> _consulted = <String>[];

  /// Operator ids consulted so far, in first-consultation order.
  List<String> get consultedOperatorIds =>
      List<String>.unmodifiable(_consulted);

  /// Verdicts produced so far, including synthesised unresolved ones.
  Map<String, FilterResult> get verdicts =>
      Map<String, FilterResult>.unmodifiable(_verdicts);

  /// Whether [operatorId] has already been consulted in this pass.
  bool has(String operatorId) => _verdicts.containsKey(operatorId);

  /// The verdict for [operatorId], evaluating the operator on first use.
  ///
  /// Never throws and never returns null: every failure becomes a FilterResult
  /// whose status is unknown (capability or input problem) or error
  /// (configuration or execution problem). Neither is a pass.
  Future<FilterResult> resolve(String operatorId, PolicyRequest request) async {
    final cached = _verdicts[operatorId];
    if (cached != null) return cached;
    final verdict = await _evaluate(operatorId, request);
    _verdicts[operatorId] = verdict;
    _consulted.add(operatorId);
    return verdict;
  }

  Future<FilterResult> _evaluate(
    String operatorId,
    PolicyRequest request,
  ) async {
    final operator = _resolver.resolve(operatorId);
    if (operator == null) {
      return _synthesised(
        operatorId: operatorId,
        status: FilterStatus.error,
        reasonCode: ConditionReasonCodes.operatorNotFound,
        errorCode: ConditionReasonCodes.operatorNotFound,
        explanation: 'no operator is registered under "$operatorId"',
      );
    }
    final availability = operator.availability;
    if (!availability.isReady) {
      return _synthesised(
        operatorId: operatorId,
        status: FilterStatus.unknown,
        reasonCode:
            availability.reasonCode ?? ConditionReasonCodes.operatorUnavailable,
        explanation: 'operator is ${availability.state.name} here',
      );
    }
    try {
      return await operator.evaluate(request.content, request.runContext);
    } catch (error) {
      return _synthesised(
        operatorId: operatorId,
        status: FilterStatus.error,
        reasonCode: ConditionReasonCodes.operatorThrew,
        errorCode: ConditionReasonCodes.operatorThrew,
        explanation: 'operator threw ${error.runtimeType}',
      );
    }
  }

  static FilterResult _synthesised({
    required String operatorId,
    required FilterStatus status,
    required String reasonCode,
    required String explanation,
    String? errorCode,
  }) => FilterResult(
    operatorId: operatorId,
    status: status,
    reasonCode: reasonCode,
    explanation: explanation,
    evidence: const [],
    errorCode: errorCode,
  );
}

/// Evaluates rule conditions. One instance per policy pass.
final class PolicyEvaluator {
  PolicyEvaluator(FilterOperatorResolver resolver)
    : verdicts = OperatorVerdictCache(resolver);

  /// Verdicts consulted during this pass.
  final OperatorVerdictCache verdicts;

  /// Evaluates [node] against [request].
  Future<NodeEvaluation> evaluate(RuleNode node, PolicyRequest request) =>
      switch (node) {
        AllNode() => _evaluateAll(node, request),
        AnyNode() => _evaluateAny(node, request),
        NotNode() => _evaluateNot(node, request),
        OperatorNode() => _evaluateOperator(node, request),
        CompareNode() => _evaluateCompare(node, request),
      };

  Future<NodeEvaluation> _evaluateAll(
    AllNode node,
    PolicyRequest request,
  ) async {
    final children = <NodeEvaluation>[];
    var outcome = ConditionOutcome.satisfied;
    String? reasonCode;
    String? message;
    for (final child in node.children) {
      final evaluation = await evaluate(child, request);
      children.add(evaluation);
      if (evaluation.outcome == ConditionOutcome.unsatisfied) {
        return NodeEvaluation(
          node: node,
          outcome: ConditionOutcome.unsatisfied,
          children: List<NodeEvaluation>.unmodifiable(children),
        );
      }
      if (evaluation.outcome == ConditionOutcome.error) {
        outcome = ConditionOutcome.error;
        reasonCode ??= evaluation.reasonCode;
        message ??= evaluation.message;
      } else if (evaluation.outcome == ConditionOutcome.unknown) {
        if (outcome != ConditionOutcome.error) {
          outcome = ConditionOutcome.unknown;
        }
        reasonCode ??= evaluation.reasonCode;
        message ??= evaluation.message;
      }
    }
    return NodeEvaluation(
      node: node,
      outcome: outcome,
      reasonCode: reasonCode,
      message: message,
      children: List<NodeEvaluation>.unmodifiable(children),
    );
  }

  Future<NodeEvaluation> _evaluateAny(
    AnyNode node,
    PolicyRequest request,
  ) async {
    final children = <NodeEvaluation>[];
    var outcome = ConditionOutcome.unsatisfied;
    String? reasonCode;
    String? message;
    for (final child in node.children) {
      final evaluation = await evaluate(child, request);
      children.add(evaluation);
      if (evaluation.outcome == ConditionOutcome.satisfied) {
        return NodeEvaluation(
          node: node,
          outcome: ConditionOutcome.satisfied,
          children: List<NodeEvaluation>.unmodifiable(children),
        );
      }
      if (evaluation.outcome == ConditionOutcome.error) {
        outcome = ConditionOutcome.error;
        reasonCode ??= evaluation.reasonCode;
        message ??= evaluation.message;
      } else if (evaluation.outcome == ConditionOutcome.unknown) {
        if (outcome != ConditionOutcome.error) {
          outcome = ConditionOutcome.unknown;
        }
        reasonCode ??= evaluation.reasonCode;
        message ??= evaluation.message;
      }
    }
    return NodeEvaluation(
      node: node,
      outcome: outcome,
      reasonCode: reasonCode,
      message: message,
      children: List<NodeEvaluation>.unmodifiable(children),
    );
  }

  Future<NodeEvaluation> _evaluateNot(
    NotNode node,
    PolicyRequest request,
  ) async {
    final child = await evaluate(node.child, request);
    final outcome = switch (child.outcome) {
      ConditionOutcome.satisfied => ConditionOutcome.unsatisfied,
      ConditionOutcome.unsatisfied => ConditionOutcome.satisfied,
      ConditionOutcome.unknown => ConditionOutcome.unknown,
      ConditionOutcome.error => ConditionOutcome.error,
    };
    return NodeEvaluation(
      node: node,
      outcome: outcome,
      reasonCode: child.reasonCode,
      message: child.message,
      children: <NodeEvaluation>[child],
    );
  }

  Future<NodeEvaluation> _evaluateOperator(
    OperatorNode node,
    PolicyRequest request,
  ) async {
    final verdict = await verdicts.resolve(node.operatorId, request);
    return NodeEvaluation(
      node: node,
      outcome: switch (verdict.status) {
        FilterStatus.matched => ConditionOutcome.satisfied,
        FilterStatus.notMatched => ConditionOutcome.unsatisfied,
        FilterStatus.unknown => ConditionOutcome.unknown,
        FilterStatus.error => ConditionOutcome.error,
      },
      reasonCode: verdict.isUnresolved ? verdict.reasonCode : null,
      message: verdict.isUnresolved ? verdict.explanation : null,
      operatorId: node.operatorId,
      verdict: verdict,
    );
  }

  Future<NodeEvaluation> _evaluateCompare(
    CompareNode node,
    PolicyRequest request,
  ) async {
    final read = await _read(node, request);
    final verdict = node.operatorId == null
        ? null
        : verdicts.verdicts[node.operatorId];
    switch (read) {
      case FieldUnavailable(:final outcome, :final reasonCode, :final message):
        return NodeEvaluation(
          node: node,
          outcome: outcome,
          reasonCode: reasonCode,
          message: message,
          operatorId: node.operatorId,
          verdict: verdict,
        );
      case FieldValue(:final value):
        return NodeEvaluation(
          node: node,
          outcome: _compare(node, value),
          operatorId: node.operatorId,
          verdict: verdict,
        );
    }
  }

  Future<FieldRead> _read(CompareNode node, PolicyRequest request) async {
    final content = request.content;
    if (!node.field.operatorDerived) {
      return switch (node.field) {
        RuleField.contentId => FieldValue(content.contentId),
        RuleField.occurrenceKey => FieldValue(content.occurrenceKey),
        RuleField.authorUid => FieldValue(content.authorUid),
        RuleField.parentId => FieldValue(content.parentId),
        RuleField.text => FieldValue(content.text),
        RuleField.title => FieldValue(content.title),
        RuleField.contentType => FieldValue(content.contentType.wireName),
        RuleField.surface => FieldValue(content.surface.wireName),
        RuleField.tags => FieldValue(content.tags),
        RuleField.mediaTypes => FieldValue(<Object?>[
          for (final media in content.media) media.type.wireName,
        ]),
        RuleField.mediaCount => FieldValue(content.media.length),
        _ => const FieldUnavailable(
          outcome: ConditionOutcome.error,
          reasonCode: ConditionReasonCodes.comparisonNotApplicable,
          message: 'an operator field cannot be read from content',
        ),
      };
    }

    final operatorId = node.operatorId;
    if (operatorId == null) {
      return const FieldUnavailable(
        outcome: ConditionOutcome.error,
        reasonCode: ConditionReasonCodes.comparisonNotApplicable,
        message: 'an operator-derived field needs an operatorId',
      );
    }
    final verdict = await verdicts.resolve(operatorId, request);
    if (verdict.status == FilterStatus.unknown) {
      return FieldUnavailable(
        outcome: ConditionOutcome.unknown,
        reasonCode: verdict.reasonCode,
        message: verdict.explanation ?? 'operator could not decide',
      );
    }
    if (verdict.status == FilterStatus.error) {
      return FieldUnavailable(
        outcome: ConditionOutcome.error,
        reasonCode: verdict.reasonCode,
        message: verdict.explanation ?? 'operator failed',
      );
    }
    return FieldValue(_operatorFieldValue(node.field, verdict));
  }

  /// Reads a settled verdict.
  ///
  /// Only reached for matched / notMatched: an unresolved verdict becomes
  /// [FieldUnavailable] above, which is what stops a rule from inverting "the
  /// capability is missing" into "the content is clean".
  static Object? _operatorFieldValue(RuleField field, FilterResult verdict) =>
      switch (field) {
        RuleField.operatorStatus => verdict.status.name,
        RuleField.operatorReasonCode => verdict.reasonCode,
        RuleField.operatorScore => verdict.score,
        RuleField.operatorAttributeViolation => verdict.attributeViolation,
        _ => throw ArgumentError.value(field, 'field', 'not operator-derived'),
      };

  /// Compares [value] — already read and cast for [CompareNode.field] — with the
  /// node's literal.
  ///
  /// A comparison over an absent value is [ConditionOutcome.unknown] except for
  /// equals/notEquals, the two comparisons still meaningful when the content has
  /// no text, no author or no score: "absent" is a fact, but "does not contain X"
  /// is not knowable about an absent string.
  static ConditionOutcome _compare(CompareNode node, Object? value) =>
      switch (node.field.valueKind) {
        RuleValueKind.string => _compareString(
          value as String?,
          node.operator,
          node.value,
        ),
        RuleValueKind.stringList => _compareStringList(
          (value as List<Object?>?) ?? const <Object?>[],
          node.operator,
          node.value,
        ),
        RuleValueKind.integer => _compareNumber(
          value as num,
          node.operator,
          node.value,
        ),
        RuleValueKind.decimal => _compareNumber(
          value as num?,
          node.operator,
          node.value,
        ),
        RuleValueKind.boolean => _compareBool(
          value as bool,
          node.operator,
          node.value,
        ),
      };

  static ConditionOutcome _compareString(
    String? actual,
    CompareOperator comparison,
    Object? literal,
  ) {
    final expected = literal is String ? literal : null;
    if (actual == null) {
      switch (comparison) {
        case CompareOperator.equals:
          return _bool(literal == null);
        case CompareOperator.notEquals:
          return _bool(literal != null);
        default:
          return ConditionOutcome.unknown;
      }
    }
    if (comparison.isListOperator) {
      final list = (literal as List<Object?>?) ?? const <Object?>[];
      final hit = list.contains(actual);
      return _bool(comparison == CompareOperator.inList ? hit : !hit);
    }
    if (expected == null) {
      return comparison == CompareOperator.notEquals
          ? ConditionOutcome.satisfied
          : ConditionOutcome.unsatisfied;
    }
    return switch (comparison) {
      CompareOperator.equals => _bool(actual == expected),
      CompareOperator.notEquals => _bool(actual != expected),
      CompareOperator.contains => _bool(actual.contains(expected)),
      CompareOperator.notContains => _bool(!actual.contains(expected)),
      CompareOperator.startsWith => _bool(actual.startsWith(expected)),
      CompareOperator.endsWith => _bool(actual.endsWith(expected)),
      _ => ConditionOutcome.unknown,
    };
  }

  static ConditionOutcome _compareStringList(
    List<Object?> actual,
    CompareOperator comparison,
    Object? literal,
  ) {
    final expected = (literal as List<Object?>?) ?? const <Object?>[];
    final sameSet =
        actual.length == expected.length &&
        actual.every(expected.contains) &&
        expected.every(actual.contains);
    return switch (comparison) {
      CompareOperator.equals => _bool(sameSet),
      CompareOperator.notEquals => _bool(!sameSet),
      CompareOperator.contains => _bool(expected.every(actual.contains)),
      CompareOperator.notContains => _bool(!expected.every(actual.contains)),
      CompareOperator.inList => _bool(actual.any(expected.contains)),
      CompareOperator.notInList => _bool(!actual.any(expected.contains)),
      _ => ConditionOutcome.unknown,
    };
  }

  static ConditionOutcome _compareNumber(
    num? actual,
    CompareOperator comparison,
    Object? literal,
  ) {
    if (comparison.isListOperator) {
      final expected = (literal as List<Object?>?) ?? const <Object?>[];
      var hit = false;
      if (actual != null) {
        for (final candidate in expected) {
          if (candidate is num && candidate == actual) {
            hit = true;
            break;
          }
        }
      }
      return _bool(comparison == CompareOperator.inList ? hit : !hit);
    }
    if (actual == null) {
      switch (comparison) {
        case CompareOperator.equals:
          return _bool(literal == null);
        case CompareOperator.notEquals:
          return _bool(literal != null);
        default:
          return ConditionOutcome.unknown;
      }
    }
    if (literal is! num) return ConditionOutcome.unknown;
    return switch (comparison) {
      CompareOperator.equals => _bool(actual == literal),
      CompareOperator.notEquals => _bool(actual != literal),
      CompareOperator.greaterThan => _bool(actual > literal),
      CompareOperator.greaterOrEqual => _bool(actual >= literal),
      CompareOperator.lessThan => _bool(actual < literal),
      CompareOperator.lessOrEqual => _bool(actual <= literal),
      _ => ConditionOutcome.unknown,
    };
  }

  static ConditionOutcome _compareBool(
    bool actual,
    CompareOperator comparison,
    Object? literal,
  ) {
    if (literal is! bool) return ConditionOutcome.unknown;
    return switch (comparison) {
      CompareOperator.equals => _bool(actual == literal),
      CompareOperator.notEquals => _bool(actual != literal),
      _ => ConditionOutcome.unknown,
    };
  }

  static ConditionOutcome _bool(bool value) =>
      value ? ConditionOutcome.satisfied : ConditionOutcome.unsatisfied;
}
