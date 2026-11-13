/// The inert data grammar a ContentGuard rule is written in.
///
/// A rule is JSON this layer *parses*; it is never Dart, JavaScript or a
/// callback. Two consequences drive every declaration here:
///
/// * A loaded rule can only express what the action vocabulary below can say,
///   so a hostile or corrupted rule cannot reach the filesystem, the
///   transport, storage or the UI (plan-core section 2.4).
/// * Every construct carries a stable wire name, so a stored rule keeps its
///   meaning across releases or fails to parse — it is never reinterpreted by
///   a default.
///
/// These are value carriers, so they hold no behaviour beyond `toString» and
/// the wire-name getters; parsing lives in `rule_schema.dart» and evaluation in
/// `policy_evaluator.dart». The const constructors do not copy their
/// collections: callers must pass immutable values, and the JSON decoder
/// always does.
library;

import 'package:PiliPlus/services/content_guard/model/content_types.dart';

/// Stable wire names of every [RuleNode].
///
/// Frozen: they appear inside stored rule documents, so renaming one is a
/// schema version bump, not a refactor.
abstract final class RuleNodeTypes {
  static const String all = 'all';
  static const String any = 'any';
  static const String not = 'not';
  static const String operator = 'operator';
  static const String compare = 'compare';
}

/// Stable wire names of every [RuleAction].
abstract final class RuleActionTypes {
  static const String allow = 'allow';
  static const String collapse = 'collapse';
  static const String hide = 'hide';
  static const String maskMedia = 'maskMedia';
  static const String continueRule = 'continue';
  static const String skip = 'skip';
  static const String setTag = 'setTag';
  static const String setScore = 'setScore';
  static const String evaluate = 'evaluate';
}

/// A condition node of a rule's `when» clause.
///
/// Conditions are four-valued, not two-valued: satisfied, unsatisfied,
/// unknown, error (see `ConditionOutcome»). The last two exist so a missing
/// capability or a failed operator can never be folded into "did not match"
/// and become a silent allow (plan-core section 2.3).
sealed class RuleNode {
  const RuleNode();

  /// Stable machine name this node carries in rule JSON.
  String get nodeType;
}

/// Logical AND: satisfied only when every child is satisfied.
///
/// Kleene semantics: one unsatisfied child makes the whole node unsatisfied
/// regardless of the other children; otherwise a child in error makes the node
/// an error, and a child that is unknown makes it unknown.
final class AllNode extends RuleNode {
  const AllNode({required this.children});

  final List<RuleNode> children;

  @override
  String get nodeType => RuleNodeTypes.all;

  @override
  String toString() => 'AllNode(${children.length} children)';
}

/// Logical OR: satisfied as soon as one child is satisfied.
///
/// Kleene semantics: one satisfied child makes the whole node satisfied;
/// otherwise a child in error makes the node an error, and a child that is
/// unknown makes it unknown — never unsatisfied.
final class AnyNode extends RuleNode {
  const AnyNode({required this.children});

  final List<RuleNode> children;

  @override
  String get nodeType => RuleNodeTypes.any;

  @override
  String toString() => 'AnyNode(${children.length} children)';
}

/// Logical NOT. Inverts satisfied/unsatisfied and leaves unknown/error alone.
///
/// Negation is deliberately *not* a way to turn "cannot tell" into "matches":
/// a rule that hides content because a capability is missing would be exactly
/// the silent-allow failure the four-valued logic exists to prevent.
final class NotNode extends RuleNode {
  const NotNode({required this.child});

  final RuleNode child;

  @override
  String get nodeType => RuleNodeTypes.not;

  @override
  String toString() => 'NotNode($child)';
}

/// Leaf: dispatch [operatorId] through the injected resolver and read its
/// verdict.
///
/// The node never names a Dart type, so a rule cannot select an implementation
/// the running build does not have: an unresolvable id becomes an error
/// verdict, which routes into the rule's `errorAction».
final class OperatorNode extends RuleNode {
  const OperatorNode({
    required this.operatorId,
    this.inputs = const <ContentInput>{},
    this.config = const <String, Object?>{},
  });

  /// Stable operator id, resolved by `FilterOperatorResolver». An id no operator
  /// answers to is a configuration error, never a fallback.
  final String operatorId;

  /// Content inputs this node declares it needs.
  ///
  /// Documented so the rule-testing UI can show why an operator was not
  /// dispatched on thin content. Dispatchability itself stays the operator's
  /// decision ([FilterOperator.requiredInputs]); the engine never narrows it
  /// from rule data.
  final Set<ContentInput> inputs;

  /// Free-form operator configuration, carried as inert JSON.
  ///
  /// Rule data must never hold a credential, and that is enforced rather than
  /// asked for: a member whose name is credential-shaped — `apiKey`,
  /// `accessKey`, `privateKey`, `password`, `passphrase`, `secret`, `token`,
  /// `cookie`, `authorization`, `authHeader`, `bearer`, `credential`,
  /// `sessionKey`, `signingKey` — is rejected at any depth of this map, nested
  /// header maps included (`{"headers": {"Cookie": "..."}}`). Names are
  /// matched case-insensitively and ignoring separators, so `private_key` and
  /// `X-Api-Key` are rejected too. Values are never scanned: a keyword or a
  /// metadata predicate may still match the *text* "token" — only member names
  /// are reserved.
  ///
  /// There is no secret-reference channel in this build, so a reference
  /// (`secretRef`, `tokenEnv`) is rejected exactly like the secret itself; an
  /// operator that wants a budget names it outside the reserved vocabulary
  /// (`completionBudget`, not `maxTokens`).
  ///
  /// Apart from that reservation this map holds thresholds and selectors only,
  /// and it is what the trace records. The operator contract v1
  /// ([FilterOperator.evaluate]) has no configuration channel yet, so a node's
  /// `config` documents intent rather than changing the verdict.
  final Map<String, Object?> config;

  @override
  String get nodeType => RuleNodeTypes.operator;

  @override
  String toString() =>
      'OperatorNode($operatorId, inputs: ${inputs.length}, '
      'config: ${config.length})';
}

/// Leaf: compare one field of the content — or of an operator verdict — against
/// a literal from the rule document.
///
/// The literal is JSON, never an expression, so a rule cannot compute anything.
final class CompareNode extends RuleNode {
  const CompareNode({
    required this.field,
    required this.operator,
    required this.value,
    this.operatorId,
  });

  final RuleField field;

  final CompareOperator operator;

  /// Right-hand operand: a JSON scalar, or a list of them for a list operator.
  /// Its accepted shape is fixed by [RuleField.valueKind] and validated at parse
  /// time.
  ///
  /// Both list operators mean the same thing on either kind of field, and the
  /// shape of this operand is the *flat* one in both cases — a list of scalars,
  /// never a list of lists:
  ///
  /// * scalar field (`string`, `integer`, `decimal`): `inList` is membership of
  ///   that one value, `notInList` its complement.
  /// * `stringList` field ([RuleField.tags], [RuleField.mediaTypes]): `inList`
  ///   asks whether the field shares **at least one** element with this list,
  ///   `notInList` its complement (no element in common). `tags IN ["ads"]`
  ///   therefore matches content tagged `["ads"]`, and `tags NOT IN ["ads"]`
  ///   matches `[]` and `["life"]` but not `["ads", "life"]`.
  final Object? value;

  /// Operator whose verdict supplies [field]; required exactly when
  /// [RuleField.operatorDerived] is set, and rejected otherwise.
  final String? operatorId;

  @override
  String get nodeType => RuleNodeTypes.compare;

  @override
  String toString() =>
      'CompareNode(${field.wireName} ${operator.wireName} '
      '${field.operatorDerived ? operatorId : ""} value: $value)';
}

/// One observable property a rule may compare against.
///
/// Content fields read the [GuardContent] carrier directly. Operator fields read
/// a single [FilterResult], which is how a rule scopes on *what an operator
/// said* rather than on raw content — the only way a compound condition can
/// require "matched by A but not by B".
enum RuleField {
  contentId('contentId', RuleValueKind.string),
  occurrenceKey('occurrenceKey', RuleValueKind.string),
  authorUid('authorUid', RuleValueKind.string),
  parentId('parentId', RuleValueKind.string),
  text('text', RuleValueKind.string),
  title('title', RuleValueKind.string),
  contentType('contentType', RuleValueKind.string),
  surface('surface', RuleValueKind.string),
  tags('tags', RuleValueKind.stringList),
  mediaTypes('mediaTypes', RuleValueKind.stringList),
  mediaCount('mediaCount', RuleValueKind.integer),
  operatorStatus(
    'operator.status',
    RuleValueKind.string,
    operatorDerived: true,
  ),
  operatorReasonCode(
    'operator.reasonCode',
    RuleValueKind.string,
    operatorDerived: true,
  ),
  operatorScore('operator.score', RuleValueKind.decimal, operatorDerived: true),
  operatorAttributeViolation(
    'operator.attributeViolation',
    RuleValueKind.boolean,
    operatorDerived: true,
  );

  const RuleField(
    this.wireName,
    this.valueKind, {
    this.operatorDerived = false,
  });

  /// Stable machine name used by rule JSON. Dotted names belong to the
  /// operator-result namespace, which can never collide with a content field.
  final String wireName;

  final RuleValueKind valueKind;

  /// Whether the value comes from a [FilterResult] instead of the content.
  final bool operatorDerived;
}

/// Shape of a [RuleField] value, which fixes both the accepted literals and the
/// applicable [CompareOperator] set.
enum RuleValueKind {
  /// A `String?» — absent is null.
  string,

  /// A `List<String>» — never null; empty when nothing is attached.
  stringList,

  /// An `int» — always present.
  integer,

  /// A `double?» — absent is null.
  decimal,

  /// A `bool» — always present.
  boolean,
}

/// Comparison a [CompareNode] may apply.
///
/// There is deliberately no regular-expression operator: rule data is authored
/// outside the build, and an unbounded pattern run against every content item is
/// a denial-of-service the engine cannot price. Rules that need pattern matching
/// belong in an operator, where the cost is explicit.
enum CompareOperator {
  equals('equals'),
  notEquals('notEquals'),
  contains('contains'),
  notContains('notContains'),
  startsWith('startsWith'),
  endsWith('endsWith'),
  inList('inList'),
  notInList('notInList'),
  greaterThan('greaterThan'),
  greaterOrEqual('greaterOrEqual'),
  lessThan('lessThan'),
  lessOrEqual('lessOrEqual');

  const CompareOperator(this.wireName);

  final String wireName;

  /// Whether this operator consumes a list literal.
  bool get isListOperator => this == inList || this == notInList;

  /// Whether this operator orders its operands instead of testing presence.
  bool get isOrderingOperator =>
      this == greaterThan ||
      this == greaterOrEqual ||
      this == lessThan ||
      this == lessOrEqual;
}

/// What the engine does once a rule's condition has been decided.
///
/// The vocabulary mixes three different jobs — final disposition
/// ([AllowAction]), accumulation ([HideAction], [CollapseAction],
/// [MaskMediaAction], [SetTagAction], [SetScoreAction]) and control flow
/// ([ContinueAction], [SkipAction], [EvaluateAction]) — because a rule names
/// exactly one action. `PolicyEngine» documents how those jobs compose.
sealed class RuleAction {
  const RuleAction();

  /// Stable machine name this action carries in rule JSON.
  String get actionType;

  /// Whether this action contributes to a hiding disposition.
  bool get isHidingAction => false;
}

/// Permits the content and stops evaluating the remaining rules.
///
/// `allow» is stop-and-permit, not an override: a hiding action accumulated
/// earlier in the pass still decides the disposition, because rule order is a
/// declared precedence and a later rule must not resurrect hidden content.
final class AllowAction extends RuleAction {
  const AllowAction();

  @override
  String get actionType => RuleActionTypes.allow;

  @override
  String toString() => 'AllowAction()';
}

/// Collapses the content behind a placeholder the user can expand.
final class CollapseAction extends RuleAction {
  const CollapseAction({required this.reasonCode});

  /// Stable machine reason shown to the user and stored with the decision.
  final String reasonCode;

  @override
  String get actionType => RuleActionTypes.collapse;

  @override
  bool get isHidingAction => true;

  @override
  String toString() => 'CollapseAction($reasonCode)';
}

/// Hides the content entirely.
final class HideAction extends RuleAction {
  const HideAction({required this.reasonCode});

  final String reasonCode;

  @override
  String get actionType => RuleActionTypes.hide;

  @override
  bool get isHidingAction => true;

  @override
  String toString() => 'HideAction($reasonCode)';
}

/// Masks the listed media roles while leaving the rest of the content visible.
///
/// An empty set means "every attached media role", which is what a rule author
/// means by "do not show me pictures here".
final class MaskMediaAction extends RuleAction {
  const MaskMediaAction({required this.mediaTypes});

  final Set<MediaType> mediaTypes;

  @override
  String get actionType => RuleActionTypes.maskMedia;

  @override
  bool get isHidingAction => true;

  @override
  String toString() =>
      'MaskMediaAction(${mediaTypes.map((type) => type.name).join("|")})';
}

/// Applies no disposition and lets evaluation proceed.
///
/// Its real job is to be an explicit `unknownAction» / `errorAction»: a rule must
/// say what an unresolved condition means, and "no disposition change" is a
/// legal answer that still leaves the rule marked unresolved in the trace.
final class ContinueAction extends RuleAction {
  const ContinueAction();

  @override
  String get actionType => RuleActionTypes.continueRule;

  @override
  String toString() => 'ContinueAction()';
}

/// Skips the remaining rules of [ruleGroup], and only that group.
///
/// Scoping matters: a skip fired by a "this comment thread" rule must not
/// disable the media rules that live in another group.
final class SkipAction extends RuleAction {
  const SkipAction({required this.ruleGroup});

  final String ruleGroup;

  @override
  String get actionType => RuleActionTypes.skip;

  @override
  String toString() => 'SkipAction($ruleGroup)';
}

/// Adds a stable tag to the decision, for grouping and later filtering.
final class SetTagAction extends RuleAction {
  const SetTagAction({required this.tag});

  final String tag;

  @override
  String get actionType => RuleActionTypes.setTag;

  @override
  String toString() => 'SetTagAction($tag)';
}

/// Contributes [score] to the aggregate score of the decision.
///
/// Contributions are summed. The aggregate has no shared scale across rules, so
/// a threshold belongs in a `CompareNode» over a score an operator reported,
/// never in an assumption made here.
final class SetScoreAction extends RuleAction {
  const SetScoreAction({required this.score});

  final double score;

  @override
  String get actionType => RuleActionTypes.setScore;

  @override
  String toString() => 'SetScoreAction($score)';
}

/// Invokes an operator for its verdict without deciding anything.
///
/// The verdict lands in the trace and in the per-pass verdict cache, so a later
/// rule can compare against `operator.status» without paying for a second
/// evaluation. It changes no disposition by itself.
final class EvaluateAction extends RuleAction {
  const EvaluateAction({required this.operatorId});

  final String operatorId;

  @override
  String get actionType => RuleActionTypes.evaluate;

  @override
  String toString() => 'EvaluateAction($operatorId)';
}

/// One complete rule document.
///
/// [when] is the condition, [then] the action a satisfied condition applies, and
/// [unknownAction] / [errorAction] the actions an unresolved condition applies.
/// Those last two are mandatory document fields rather than defaults in code:
/// "a failed operator means nothing" is a policy decision the rule author writes
/// down, not an engine detail (plan-core section 2.3).
final class RuleDefinition {
  const RuleDefinition({
    required this.schemaVersion,
    required this.id,
    required this.when,
    required this.then,
    required this.unknownAction,
    required this.errorAction,
    this.migration = const <String>[],
    this.enabled = true,
    this.priority = 0,
    this.group = defaultGroup,
    this.attributeViolation = false,
  });

  /// Group every rule falls into when the document names none.
  static const String defaultGroup = 'default';

  /// Rule-document schema version this rule was authored under.
  final int schemaVersion;

  /// Migration steps that produced this document, oldest first.
  ///
  /// Empty for a rule authored at the current version. Recorded so the
  /// rule-testing UI can say *why* a stored rule looks the way it does after an
  /// upgrade, instead of silently rewriting the user's file.
  final List<String> migration;

  /// Stable rule id. Appears in traces, decision cache keys and the UI.
  final String id;

  /// Whether the rule participates. A disabled rule is kept and shown; it is
  /// never evaluated and never silently dropped from the set.
  final bool enabled;

  /// Evaluation order weight. Higher runs first; equal priorities keep
  /// declaration order (see `PolicyEngine»).
  final int priority;

  /// Group a [SkipAction] addresses.
  final String group;

  final RuleNode when;

  /// Applied when [when] is satisfied.
  final RuleAction then;

  /// Applied when [when] is unknown — a capability is missing, or a field could
  /// not be read. Never treated as "did not match".
  final RuleAction unknownAction;

  /// Applied when [when] is in error — an operator failed, or a comparison could
  /// not run. Never treated as "did not match".
  final RuleAction errorAction;

  /// Whether a match by this rule may be attributed to the content author and
  /// feed the violation ledger.
  ///
  /// Defaults to false, matching [FilterResult.attributeViolation]: a media or QR
  /// match is not, on its own, evidence about who posted the content
  /// (plan-core section 6.2).
  final bool attributeViolation;

  @override
  String toString() =>
      'RuleDefinition($id, v$schemaVersion, priority: $priority, '
      'group: $group, enabled: $enabled, '
      'when: ${when.nodeType}, then: ${then.actionType})';
}
