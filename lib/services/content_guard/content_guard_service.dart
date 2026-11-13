/// The ContentGuard assembly a page can hold: pipeline plus capability report.
///
/// ## Why this is not a GetxController
///
/// The house style for a `lib/services/` singleton is a `GetxService` registered
/// in `main()` through `Get.lazyPut`. It cannot be one *here*, and the reason is
/// mechanical rather than stylistic: every entry point of `package:get/get.dart`
/// — `GetxController` included — transitively imports
/// `package:flutter/widgets.dart`, which imports `dart:ui`. A plain-Dart
/// verification script cannot run against `dart:ui` in this environment (the SDK
/// refuses `flutter test` outright here), so a GetxController assembly would be
/// unverifiable — and a subsystem whose wiring cannot be executed is a subsystem
/// nobody has shown to compose.
///
/// What replaces it is the same lifecycle without the Flutter dependency: a
/// plain class with a private constructor and one static [create], so there is
/// still a single assembly point and a page can still hold exactly one instance.
/// A page is free to wrap it in whatever reactive primitive it uses.
///
/// ## What it owns
///
/// The registry (one instance of every static operator), the policy engine, the
/// decision composer, the presenter, the violation ledger and the suggestion
/// machine, plus the [ContentGuardBootstrap] capability report. It holds no
/// `BuildContext`, imports no widget, no Hive and no GetX, and never reaches the
/// transport.
library;

import 'dart:convert';

import 'package:PiliPlus/services/content_guard/decision/decision.dart';
import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';
import 'package:PiliPlus/services/content_guard/operator/operator_registry.dart';
import 'package:PiliPlus/services/content_guard/operator/static/static_operators.dart';
import 'package:PiliPlus/services/content_guard/policy/policy.dart';
import 'package:PiliPlus/services/content_guard/presenter/content_presenter.dart';
import 'package:PiliPlus/services/content_guard/slice/content_guard_pipeline.dart';
import 'package:PiliPlus/services/content_guard/storage/durable_scope_bootstrap.dart';
import 'package:PiliPlus/services/content_guard/storage/durable_scope_migration.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion_machine.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_policy.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_ledger.dart';

/// One capability the subsystem either has or does not have.
///
/// Capability is *reported*, never inferred from silence. [available] is true
/// only when every operator the capability names is registered **and** ready;
/// otherwise [reasonCode] says why, so a settings page can print "local
/// inference is not in this build" instead of showing an empty list that reads
/// as "nothing to filter".
final class OperatorCapability {
  const OperatorCapability({
    required this.id,
    required this.label,
    required this.available,
    required this.operatorIds,
    required this.requiredInputs,
    this.reasonCode,
    this.message,
  });

  /// Stable machine id of the capability (`text.keyword`, `media.ocr`, ...).
  final String id;

  /// Short human label. English here because this layer is UI-free and owns no
  /// localisation table; the UI maps [id] to a localised string.
  final String label;

  /// Whether this build can actually run the capability right now.
  final bool available;

  /// Registered operator ids implementing it. Empty when the build does not
  /// implement the capability at all.
  final Set<String> operatorIds;

  /// Inputs the capability needs from `GuardContent`; empty when unavailable.
  final Set<ContentInput> requiredInputs;

  /// Stable reason code when [available] is false. Never localised.
  final String? reasonCode;

  /// Human-facing explanation. Display only; no caller branches on it.
  final String? message;

  /// Whether the capability has no implementation in this build.
  bool get isUnimplemented => operatorIds.isEmpty;

  @override
  String toString() =>
      'OperatorCapability($id, available: $available, '
      'operators: ${operatorIds.length}, reason: ${reasonCode ?? 'none'})';
}

/// Stable reason codes for a capability this build cannot run.
abstract final class CapabilityReasonCodes {
  /// The capability exists in the plan and has no implementation yet.
  static const String notImplemented = 'capability.not_implemented';

  /// The capability names operators, none of which is registered here.
  static const String operatorNotRegistered =
      'capability.operator_not_registered';

  /// The operator is registered but not dispatchable (disabled or failed).
  static const String operatorUnavailable = 'capability.operator_unavailable';

  /// The ContentGuard master switch is off, so no capability runs at all.
  ///
  /// Distinct from [operatorUnavailable] on purpose: "this build cannot do it"
  /// and "the user turned it off" are different messages, and only the second
  /// one is fixed by flipping a setting.
  static const String featureDisabled = 'capability.feature_disabled';
}

/// Stable reason codes for a rule-to-operator configuration application.
abstract final class ConfigDiagnosticReasonCodes {
  /// The rule's `config` block was installed on the operator instance.
  static const String applied = 'config.applied';

  /// No rule names this operator with a `config` block, so the instance keeps
  /// whatever configuration it was built with.
  static const String noConfig = 'config.no_rule_config';

  /// Several rules name this operator with *different* configuration.
  static const String ambiguous = 'config.ambiguous';

  /// The operator has no documented `config` adapter in this build.
  static const String unsupported = 'config.operator_has_no_adapter';

  /// The operator's config decoder rejected the rule's `config` block.
  static const String invalid = 'config.invalid';

  /// An enabled rule dispatches an operator id nothing is registered under.
  ///
  /// Not fatal: the engine turns an unresolvable id into an error verdict, which
  /// routes into the rule's `errorAction` instead of a silent "no match". The
  /// diagnostic exists so the authoring UI can name the typo.
  static const String operatorNotRegistered = 'config.operator_not_registered';
}

/// Raised by [ContentGuardService.create] when the supplied rules cannot be
/// turned into a pipeline without a rule silently deciding nothing.
///
/// Two situations reach this point, and both are document errors rather than
/// runtime conditions:
///
/// * several **enabled** rules name one operator with *different* configuration;
/// * an **enabled** rule supplies a `config` block this build cannot install —
///   no adapter for that operator, or the operator rejected the block.
///
/// The alternative — returning a service that reports ready and then answers
/// `notMatched` because the operator kept its empty default — is the silent
/// allow this subsystem exists to prevent, so the assembly refuses instead.
/// [diagnostics] carries the same evidence a created service would have
/// reported, so a caller can show *why* the rule set is unusable.
///
/// Declared in this file rather than the `content_guard.dart` barrel, so a
/// caller that catches it imports `content_guard_service.dart` directly.
final class ContentGuardConfigurationException implements Exception {
  const ContentGuardConfigurationException({
    required this.reasonCode,
    required this.message,
    required this.operatorIds,
    required this.ruleIds,
    this.diagnostics = const <OperatorConfigDiagnostic>[],
  });

  /// Stable machine reason; one of [ConfigDiagnosticReasonCodes].
  final String reasonCode;

  /// Human-facing explanation. Display only.
  final String message;

  /// Operators whose configuration could not be established.
  final Set<String> operatorIds;

  /// Rules that supplied the offending configuration.
  final Set<String> ruleIds;

  /// The failing diagnostics, in registration order.
  final List<OperatorConfigDiagnostic> diagnostics;

  @override
  String toString() =>
      'ContentGuardConfigurationException($reasonCode, '
      'operators: ${operatorIds.join(", ")}, rules: ${ruleIds.join(", ")})';
}

/// What a rule set asks of the operators, before anything is installed.
///
/// [diagnostics] always accounts for every registered operator (see
/// [ContentGuardService.configureFromRules]); [fatalDiagnostics] is the subset
/// that would leave an enabled rule unable to run as authored.
final class OperatorConfigPlan {
  const OperatorConfigPlan._({
    required this.diagnostics,
    required this.fatalDiagnostics,
  });

  /// One diagnostic per registered operator, plus one per operator an enabled
  /// rule names but nothing is registered under.
  final List<OperatorConfigDiagnostic> diagnostics;

  /// Diagnostics that make an enabled rule unable to run as authored: a
  /// configuration conflict, an operator with no config adapter, or a config
  /// the operator rejected.
  ///
  /// Empty is the only state in which the rules may be handed to a pipeline.
  final List<OperatorConfigDiagnostic> fatalDiagnostics;

  /// Whether handing these rules to a pipeline would let a rule silently
  /// decide nothing.
  bool get isFailClosed => fatalDiagnostics.isNotEmpty;

  /// Operators a [fatalDiagnostics] entry names.
  Set<String> get failingOperatorIds => <String>{
    for (final diagnostic in fatalDiagnostics) diagnostic.operatorId,
  };

  /// Rules a [fatalDiagnostics] entry names.
  Set<String> get failingRuleIds => <String>{
    for (final diagnostic in fatalDiagnostics) ...diagnostic.ruleIds,
  };
}

/// What the assembly did with one operator's rule-supplied configuration.
///
/// Reported rather than performed silently, because the operator contract v1
/// has no configuration channel (see [ContentGuardService.configureFromRules]):
/// a caller must be able to see whether a rule's `config` block actually took
/// effect, and a conflict must never be resolved by picking a winner.
final class OperatorConfigDiagnostic {
  const OperatorConfigDiagnostic({
    required this.operatorId,
    required this.applied,
    required this.reasonCode,
    this.message,
    this.ruleIds = const <String>{},
  });

  /// Operator the configuration was (or was not) installed on.
  final String operatorId;

  /// Whether the instance now carries the rule-supplied configuration.
  final bool applied;

  /// Stable machine reason; one of [ConfigDiagnosticReasonCodes].
  final String reasonCode;

  /// Human-facing explanation. Display only.
  final String? message;

  /// Rules that supplied configuration for this operator.
  final Set<String> ruleIds;

  @override
  String toString() =>
      'OperatorConfigDiagnostic($operatorId, applied: $applied, $reasonCode)';
}

/// The capability report a status banner or settings page renders.
///
/// [availableCapabilities] and [unavailableCapabilities] together always account
/// for every capability this build knows about: nothing can be missing from both
/// lists, which is the subsystem-level form of the operator contract's "report,
/// don't omit".
final class ContentGuardBootstrap {
  const ContentGuardBootstrap({
    required this.capabilities,
    required this.registrySnapshot,
    required this.contentTypesByOperator,
    required this.ruleCount,
    required this.enabledRuleCount,
    required this.ruleVersion,
    required this.buildVariant,
    required this.featureEnabled,
    this.configDiagnostics = const <OperatorConfigDiagnostic>[],
  });

  /// Every declared capability, in declaration order.
  final List<OperatorCapability> capabilities;

  /// `operatorId -> availability` for every registered operator.
  final Map<String, OperatorAvailability> registrySnapshot;

  /// `operatorId -> content types` for every registered operator.
  final Map<String, Set<ContentType>> contentTypesByOperator;

  /// Rules the pipeline evaluates, disabled ones included.
  final int ruleCount;

  /// Rules that will actually run.
  final int enabledRuleCount;

  /// Rule-set version every run context carries (see
  /// [ContentGuardPipeline.ruleVersion]).
  final String ruleVersion;

  /// Build variant handed to [OperatorInitContext.buildVariant].
  final String buildVariant;

  /// Master switch handed to [OperatorInitContext.featureEnabled].
  final bool featureEnabled;

  /// What the assembly did with each operator's rule-supplied configuration,
  /// in registration order.
  final List<OperatorConfigDiagnostic> configDiagnostics;

  /// Diagnostics where a rule's `config` block did NOT take effect.
  List<OperatorConfigDiagnostic> get ignoredConfigs => [
    for (final diagnostic in configDiagnostics)
      if (!diagnostic.applied) diagnostic,
  ];

  /// Capabilities this build can run right now.
  List<OperatorCapability> get availableCapabilities => [
    for (final capability in capabilities)
      if (capability.available) capability,
  ];

  /// Capabilities this build cannot run right now, with a reason.
  List<OperatorCapability> get unavailableCapabilities => [
    for (final capability in capabilities)
      if (!capability.available) capability,
  ];

  /// Capabilities with no implementation in this build at all.
  List<OperatorCapability> get unimplementedCapabilities => [
    for (final capability in capabilities)
      if (capability.isUnimplemented) capability,
  ];

  /// Stable ids of registered operators that are ready to dispatch.
  List<String> get availableOperatorIds => [
    for (final entry in registrySnapshot.entries)
      if (entry.value.isReady) entry.key,
  ];

  /// Stable ids of registered operators that are not dispatchable.
  ///
  /// Non-empty is not an error: it is the difference between "no match" and
  /// "this capability is not installed", which the UI must be able to show.
  List<String> get unavailableOperatorIds => [
    for (final entry in registrySnapshot.entries)
      if (!entry.value.isReady) entry.key,
  ];

  /// Content types at least one available operator can judge.
  Set<ContentType> get availableContentTypes => <ContentType>{
    for (final operatorId in availableOperatorIds)
      ...?contentTypesByOperator[operatorId],
  };

  /// Whether any available operator can judge [contentType].
  bool supportsContentType(ContentType contentType) =>
      availableContentTypes.contains(contentType);

  @override
  String toString() =>
      'ContentGuardBootstrap(available: ${availableCapabilities.length}, '
      'unavailable: ${unavailableCapabilities.length}, '
      'operators: ${registrySnapshot.length}, rules: $ruleCount)';
}

/// One declared capability, resolved against the registry at assembly time.
final class _CapabilitySpec {
  const _CapabilitySpec({
    required this.id,
    required this.label,
    required this.operatorIds,
    this.requiredInputs = const <ContentInput>{},
    this.unimplementedMessage,
  });

  final String id;
  final String label;
  final Set<String> operatorIds;
  final Set<ContentInput> requiredInputs;

  /// Present exactly for a capability this build has not implemented.
  final String? unimplementedMessage;
}

/// One `config` block an enabled rule supplies for one operator.
///
/// Kept with its rule id so a conflict can name both sides: "two rules disagree"
/// is only actionable if the caller learns *which* two.
final class _RuleConfig {
  const _RuleConfig({required this.ruleId, required this.config});

  final String ruleId;
  final Map<String, Object?> config;
}

/// The assembly: one pipeline, one registry, one capability report.
final class ContentGuardService {
  ContentGuardService._({
    required this.pipeline,
    required this.bootstrap,
    required this.account,
    required this.rules,
    required this.registry,
    required this.featureEnabled,
    required this.durableScopeReport,
  });

  /// Build variant reported when none is given.
  static const String defaultBuildVariant = 'standard';

  /// Every capability this build knows about: five implemented, five not.
  ///
  /// The unimplemented half is declared here on purpose. A capability that only
  /// existed as an absence could not be shown in a settings page, and "the
  /// media filter is not in this build" would be indistinguishable from "the
  /// media filter found nothing".
  static const List<_CapabilitySpec> _capabilitySpecs = <_CapabilitySpec>[
    _CapabilitySpec(
      id: 'text.keyword',
      label: 'Keyword matching',
      operatorIds: <String>{KeywordOperator.operatorId},
      requiredInputs: <ContentInput>{ContentInput.text},
    ),
    _CapabilitySpec(
      id: 'text.regex',
      label: 'Regular expression matching',
      operatorIds: <String>{RegexOperator.operatorId},
      requiredInputs: <ContentInput>{ContentInput.text},
    ),
    _CapabilitySpec(
      id: 'author.blocklist',
      label: 'Author blocklist',
      operatorIds: <String>{AuthorBlocklistOperator.operatorId},
      requiredInputs: <ContentInput>{ContentInput.authorUid},
    ),
    _CapabilitySpec(
      id: 'text.mention_quality',
      label: 'Mention quality',
      operatorIds: <String>{MentionQualityOperator.operatorId},
      requiredInputs: <ContentInput>{ContentInput.text},
    ),
    _CapabilitySpec(
      id: 'metadata.predicate',
      label: 'Metadata predicates',
      operatorIds: <String>{MetadataOperator.operatorId},
      requiredInputs: <ContentInput>{ContentInput.metadata},
    ),
    _CapabilitySpec(
      id: 'media.ocr',
      label: 'Text-in-image recognition',
      operatorIds: <String>{},
      requiredInputs: <ContentInput>{ContentInput.media},
      unimplementedMessage:
          'No local OCR runtime is wired into this build; text inside images '
          'is not read.',
    ),
    _CapabilitySpec(
      id: 'media.qr',
      label: 'QR code detection',
      operatorIds: <String>{},
      requiredInputs: <ContentInput>{ContentInput.media},
      unimplementedMessage:
          'No QR decoder operator is implemented, so a QR code in an image is '
          'not inspected.',
    ),
    _CapabilitySpec(
      id: 'media.perceptual',
      label: 'Perceptual image matching',
      operatorIds: <String>{},
      requiredInputs: <ContentInput>{ContentInput.media},
      unimplementedMessage:
          'The image fingerprint pipeline is not connected to ContentGuard, so '
          'no image is compared against known offenders.',
    ),
    _CapabilitySpec(
      id: 'semantic.topic',
      label: 'Semantic topic classification',
      operatorIds: <String>{},
      requiredInputs: <ContentInput>{ContentInput.text},
      unimplementedMessage:
          'No embedding model or classifier is bundled; only literal matching '
          'runs here.',
    ),
    _CapabilitySpec(
      id: 'llm.judge',
      label: 'LLM content judge',
      operatorIds: <String>{},
      requiredInputs: <ContentInput>{ContentInput.text},
      unimplementedMessage:
          'The `with_ai` build variant is not wired into ContentGuard; no '
          'model call is made.',
    ),
  ];

  /// The pipeline a page calls.
  final ContentGuardPipeline pipeline;

  /// Capability report for status/settings surfaces.
  final ContentGuardBootstrap bootstrap;

  /// Account every run and every ledger entry is scoped to.
  final AccountScope account;

  /// Rule set in force, disabled rules included.
  final List<RuleDefinition> rules;

  /// Operator registry the engine dispatches into.
  final OperatorRegistry registry;

  /// What the durable-scope migration did while this service was being built.
  ///
  /// Null when there was nothing to do: the account has no stable durable
  /// identity (guest, tourist), the feature is switched off, or an earlier
  /// service over the same store already ordered the namespace in this process.
  ///
  /// Carried on the service rather than only in
  /// [DurableScopeBootstrap.diagnostics] so a caller holding the service can
  /// report "your saved decisions from a previous login were carried over" without
  /// reaching into a global.
  final DurableScopeMigrationReport? durableScopeReport;

  /// Credential-free migration diagnostics this process accumulated.
  ///
  /// Counts and status words only; see [DurableScopeBootstrap.diagnostics].
  List<String> get durableScopeDiagnostics => DurableScopeBootstrap.diagnostics;

  /// Master switch this service was built with.
  ///
  /// When false, [evaluate] is a true no-op: it runs no rule, writes no ledger
  /// entry and reconciles no suggestion (see [evaluate]).
  final bool featureEnabled;

  /// Violation ledger this service records into.
  ViolationLedger get ledger => pipeline.ledger;

  /// Author-level suggestion machine this service reconciles.
  BlacklistSuggestionMachine get suggestions => pipeline.suggestions;

  /// Current list revision of the pipeline.
  int get generation => pipeline.generation;

  /// Starts a new list revision on the pipeline.
  void beginGeneration(int generation) => pipeline.beginGeneration(generation);

  /// Evaluates one content item end to end, exactly as the pipeline does.
  ///
  /// ## The master switch
  ///
  /// When [featureEnabled] is false this returns an **allowed** row without
  /// running anything: no rule is evaluated, no operator is dispatched, no
  /// ledger entry is written and no suggestion is reconciled. Handing the
  /// content to [pipeline.evaluate] with disabled operators would not be
  /// equivalent — the rules would still run, a [HideAction] whose condition
  /// degenerates to "unknown" would still be routed through
  /// `unknownAction`, and the ledger would still be writable — which is
  /// exactly the "feature is off but the feature still acted" failure this
  /// guard removes.
  ///
  /// The short-circuit is deliberately here rather than inside the pipeline:
  /// the pipeline is a pure composition that has no notion of a master switch,
  /// and a caller that built the pipeline by hand never asked for one.
  Future<PipelineResult> evaluate(
    GuardContent content, {
    ManualOverride manualOverride = ManualOverride.none,
    bool authorWhitelisted = false,
    bool authorFollowed = false,
  }) {
    if (!featureEnabled) {
      return Future<PipelineResult>.value(_disabledResult(content));
    }
    return pipeline.evaluate(
      content,
      manualOverride: manualOverride,
      authorWhitelisted: authorWhitelisted,
      authorFollowed: authorFollowed,
    );
  }

  /// The row a switched-off service returns: allowed, unpaid for, explained.
  ///
  /// Built from the public carriers only, so the guard needs no new surface on
  /// the pipeline. The trace is synthetic and carries no rules on purpose: a
  /// trace with rules in it would claim the rules were consulted, and the whole
  /// point of this path is that they were not.
  ///
  /// Throws [ArgumentError] for content from another scope, exactly as
  /// [ContentGuardPipeline.evaluate] does. That check is a caller-bug assertion
  /// rather than a policy action, so switching the feature off must not hide it.
  PipelineResult _disabledResult(GuardContent content) {
    if (content.account != account) {
      throw ArgumentError.value(
        content.account,
        'content.account',
        'does not match this pipeline scope ${account.id}',
      );
    }
    final generation = pipeline.generation;
    final decision = DecisionComposerOutput(
      disposition: ContentDisposition.allow,
      presentationState: PresenterState.allowed,
      tags: const <String>{},
      maskedMediaIds: const <String>{},
      hits: const <FilterResult>[],
      attributeViolation: false,
      violationReasonCodes: const <String>{},
      recoverable: false,
      explanation: disabledExplanation,
    );
    return PipelineResult(
      presentation: const ContentPresenter().presentContent(
        content: content,
        decision: decision,
        generation: generation,
      ),
      decision: decision,
      trace: PolicyTrace(
        contentId: content.contentId,
        contentVersion: content.contentVersion,
        ruleVersion: pipeline.ruleVersion,
        generation: generation,
        rules: const <RuleTrace>[],
        disposition: ContentDisposition.allow,
        hidingActions: const <RuleAction>[],
        tags: const <String>[],
        score: 0,
        operatorVerdicts: const <String, FilterResult>{},
        skippedGroups: const <String>[],
      ),
      violation: null,
      account: account,
      surface: content.surface,
      contentId: content.contentId,
      contentVersion: content.contentVersion,
      generation: generation,
      isStale: false,
    );
  }

  /// Explanation a switched-off service stamps on every row it allows.
  static const String disabledExplanation = 'feature_disabled';

  /// Builds a service over [store].
  ///
  /// [operators] replaces the default five static operators when supplied.
  ///
  /// ## Durable state is ordered before the service exists
  ///
  /// The very first thing this does — before any rule is resolved, any operator
  /// is initialised or any ledger is built — is
  /// [DurableScopeBootstrap.ensureMigrated]. That is the only point that
  /// satisfies all three constraints at once: the store exists (the caller had to
  /// open it), no evaluation can have happened yet (this object is the only thing
  /// that evaluates, and it does not exist until this returns), and the run
  /// happens exactly once per process however many services are constructed.
  ///
  /// The pass is non-fatal. A migration failure is deliberately not turned into a
  /// [ContentGuardConfigurationException] — that exception means "the rule set
  /// cannot run", and conflating it with "a legacy record could not be moved"
  /// would make an unrelated storage problem look like a configuration problem.
  /// The failure is recorded in [durableScopeDiagnostics], the service is built
  /// normally, and the next construction retries.
  ///
  /// ## Failing closed
  ///
  /// The rule set is resolved against the registry *before* anything is wired
  /// up, and the assembly refuses to return a service whose enabled rules could
  /// not be configured: see [ContentGuardConfigurationException] and
  /// [operatorConfigPlan]. A service that reported `available: true` while its
  /// operator kept the empty default configuration would answer `notMatched`
  /// for every item — a silent allow, and the one outcome this layer must never
  /// produce.
  ///
  /// Nothing is fatal about an *unused* registered operator: only an enabled
  /// rule that actually names an operator supplies its configuration, and an
  /// operator no rule names keeps its constructed configuration untouched.
  ///
  /// Every store the service owns is account-scoped and written through
  /// [KeyValueStore], so two services over the same store and the same account
  /// see each other's ledger and suggestion state — which is what makes a
  /// restart observable.
  ///
  /// With [featureEnabled] false the service is inert: it still reports the
  /// resolved registry and the config diagnostics, but every capability is
  /// unavailable ([CapabilityReasonCodes.featureDisabled]) and [evaluate]
  /// short-circuits to an allowed row without touching rules, ledger or
  /// suggestions. The durable-scope pass is skipped in that case as well: a
  /// switched-off feature is documented to have no storage side effects.
  static Future<ContentGuardService> create({
    required KeyValueStore store,
    required AccountScope account,
    required List<RuleDefinition> rules,
    int Function()? nowMs,
    List<FilterOperator>? operators,
    DecisionComposer? composer,
    SuggestionPolicy suggestionPolicy = const SuggestionPolicy(),
    String buildVariant = defaultBuildVariant,
    bool featureEnabled = true,
    int generation = 0,
    Iterable<String> trustedLegacyScopeIds = const <String>[],
  }) async {
    final clock = nowMs ?? _systemNowMs;

    // Must stay first: see the doc above. Nothing before this line may write to
    // `store`, and nothing after it may assume untouched legacy state.
    final durableScopeReport = await DurableScopeBootstrap.ensureMigrated(
      store: store,
      account: account,
      trustedLegacyScopeIds: trustedLegacyScopeIds,
      featureEnabled: featureEnabled,
      nowMs: nowMs,
    );

    final registry = OperatorRegistry();
    for (final operator in operators ?? defaultStaticOperators()) {
      registry.register(operator);
    }
    // Resolve and install configuration first, then decide whether the result is
    // usable. Doing it in this order means a rule set that cannot run is refused
    // with evidence, instead of being wired into a pipeline that answers
    // "no match" for every item.
    final plan = operatorConfigPlan(registry, rules);
    // The refusal is skipped when the master switch is off, and only then: a
    // switched-off service never evaluates a rule, so an unconfigurable rule set
    // cannot turn into a silent allow. Refusing here would instead remove the
    // one escape hatch a caller has when a stored rule set is unusable — they
    // could not start the app with the feature off to fix it. The findings are
    // still reported through [ContentGuardBootstrap.ignoredConfigs], so the
    // problem stays visible rather than becoming a silent downgrade.
    if (featureEnabled && plan.isFailClosed) {
      throw ContentGuardConfigurationException(
        reasonCode: plan.fatalDiagnostics.first.reasonCode,
        message: _failClosedMessage(plan),
        operatorIds: Set<String>.unmodifiable(plan.failingOperatorIds),
        ruleIds: Set<String>.unmodifiable(plan.failingRuleIds),
        diagnostics: plan.diagnostics,
      );
    }
    final configDiagnostics = plan.diagnostics;
    await registry.initializeAll(
      OperatorInitContext(
        buildVariant: buildVariant,
        featureEnabled: featureEnabled,
      ),
    );

    final engine = PolicyEngine(rules, RegistryOperatorResolver(registry));
    final ledger = ViolationLedger(store, account: account, nowMs: nowMs);
    final suggestions = BlacklistSuggestionMachine(
      store,
      account: account,
      policy: suggestionPolicy,
      nowMs: nowMs,
    );
    await suggestions.load();

    final pipeline = ContentGuardPipeline(
      registry: registry,
      engine: engine,
      composer: composer ?? const DefaultDecisionComposer(),
      presenter: const ContentPresenter(),
      ledger: ledger,
      suggestions: suggestions,
      account: account,
      rules: rules,
      nowMs: clock,
      generation: generation,
    );

    return ContentGuardService._(
      pipeline: pipeline,
      bootstrap: _bootstrapOf(
        registry: registry,
        rules: rules,
        ruleVersion: pipeline.ruleVersion,
        buildVariant: buildVariant,
        featureEnabled: featureEnabled,
        configDiagnostics: configDiagnostics,
      ),
      account: account,
      rules: rules,
      registry: registry,
      featureEnabled: featureEnabled,
      durableScopeReport: durableScopeReport,
    );
  }

  /// One-line reason the rule set was refused, naming the affected operators.
  static String _failClosedMessage(OperatorConfigPlan plan) {
    final codes = <String>{
      for (final diagnostic in plan.fatalDiagnostics) diagnostic.reasonCode,
    }.toList()..sort();
    final operators = plan.failingOperatorIds.toList()..sort();
    return 'no configuration could be established for '
        '${operators.join(", ")} (${codes.join(", ")}); the enabled rules '
        'that dispatch there would silently decide nothing';
  }

  /// Installs each enabled rule's `config` block on the operator it names and
  /// returns one diagnostic per registered operator, in registration order.
  ///
  /// ## Why the assembly has to do this
  ///
  /// The operator contract v1 has no configuration channel: [FilterOperator]
  /// declares `id`, supported types, inputs and [FilterOperator.evaluate], and
  /// `OperatorNode.config` is documented as *intent only*. In isolation that is
  /// harmless — the operators are verified and the engine is verified — but
  /// composing them exposes the seam: the engine dispatches by id, so a rule
  /// whose `config` carries `{"keywords": [...]}` still reaches a
  /// `KeywordOperator` that was constructed with an empty list, which answers
  /// `FilterStatus.unknown` (`keyword.no_keywords`) instead of matching.
  ///
  /// That unknown is *correct* per contract — a judge with nothing to look for
  /// must not report a pass — and the composer correctly refuses to turn it
  /// into `allowed`. But the end-to-end effect is that a fully authored rule
  /// set silently decides nothing. Rather than edit the verified packages, this
  /// assembly-level bridge reads the rule set it already holds and calls the
  /// operators' own `configure` methods, which exist for exactly that purpose.
  ///
  /// A thin view over [operatorConfigPlan] for callers that wire operators by
  /// hand: it performs the install and reports per-operator outcomes, but it
  /// cannot refuse. A caller that must not expose a half-configured service
  /// should consult [operatorConfigPlan] and act on
  /// [OperatorConfigPlan.isFailClosed].
  static List<OperatorConfigDiagnostic> configureFromRules(
    OperatorRegistry registry,
    List<RuleDefinition> rules,
  ) => operatorConfigPlan(registry, rules).diagnostics;

  /// Resolves the rule set against [registry] and installs the configuration,
  /// reporting what would make an enabled rule unable to run as authored.
  ///
  /// ## The walk is recursive
  ///
  /// The configuration carriers are leaves: an `all` / `any` / `not` node
  /// wraps the [OperatorNode] that holds the `config` block. Inspecting only a
  /// top-level node therefore misses every nested rule, and a schema-valid
  /// nested keyword rule would install nothing while the service still reported
  /// ready. [CompareNode] has no child, so it contributes nothing.
  ///
  /// ## Disabled rules are inert
  ///
  /// A disabled rule is kept and shown but never evaluated, so it may not
  /// influence the service at all: it supplies no configuration and takes part
  /// in no conflict. Otherwise a disabled rule carrying a different keyword
  /// list would poison an enabled rule, leaving the enabled rule unconfigured
  /// while the service still looked ready.
  ///
  /// ## What is fatal
  ///
  /// Only what an **enabled** rule depends on. A conflict between enabled
  /// rules, a configured operator with no config adapter, and a config the
  /// operator rejects are returned through
  /// [OperatorConfigPlan.fatalDiagnostics]. A registered operator that no
  /// enabled rule configures is never fatal: it keeps whatever configuration
  /// it was constructed with ([ConfigDiagnosticReasonCodes.noConfig]).
  static OperatorConfigPlan operatorConfigPlan(
    OperatorRegistry registry,
    List<RuleDefinition> rules,
  ) {
    final ruleIdsByOperator = <String, Set<String>>{};
    final configsByOperator = <String, List<_RuleConfig>>{};
    for (final rule in rules) {
      if (!rule.enabled) continue;
      for (final node in _operatorNodesOf(rule.when)) {
        final operatorId = node.operatorId;
        ruleIdsByOperator
            .putIfAbsent(operatorId, () => <String>{})
            .add(rule.id);
        if (node.config.isEmpty) continue;
        configsByOperator
            .putIfAbsent(operatorId, () => <_RuleConfig>[])
            .add(_RuleConfig(ruleId: rule.id, config: node.config));
      }
    }

    final diagnostics = <OperatorConfigDiagnostic>[];
    final fatal = <OperatorConfigDiagnostic>[];
    for (final operator in registry.operators) {
      final operatorId = operator.id;
      final ruleIds = Set<String>.unmodifiable(
        ruleIdsByOperator[operatorId] ?? const <String>{},
      );
      final supplied = configsByOperator[operatorId];
      if (supplied == null || supplied.isEmpty) {
        diagnostics.add(
          OperatorConfigDiagnostic(
            operatorId: operatorId,
            applied: false,
            reasonCode: ConfigDiagnosticReasonCodes.noConfig,
            message: 'no enabled rule supplies config for this operator',
            ruleIds: ruleIds,
          ),
        );
        continue;
      }
      final conflict = _conflictOf(supplied);
      if (conflict != null) {
        final diagnostic = OperatorConfigDiagnostic(
          operatorId: operatorId,
          applied: false,
          reasonCode: ConfigDiagnosticReasonCodes.ambiguous,
          message:
              'enabled rules name this operator with different config; '
              'nothing was installed',
          ruleIds: Set<String>.unmodifiable([...ruleIds, ...conflict]),
        );
        diagnostics.add(diagnostic);
        fatal.add(diagnostic);
        continue;
      }
      final diagnostic = _applyConfig(
        operator,
        supplied.first.config,
        ruleIds,
      );
      diagnostics.add(diagnostic);
      if (!diagnostic.applied) fatal.add(diagnostic);
    }

    // An enabled rule may name an operator this build does not register. The
    // engine turns that into an error verdict rather than a silent allow, so it
    // is reported as a diagnostic and never as a refusal: shipping a rule for a
    // capability that is not installed is legitimate.
    for (final entry in ruleIdsByOperator.entries) {
      if (registry.contains(entry.key)) continue;
      diagnostics.add(
        OperatorConfigDiagnostic(
          operatorId: entry.key,
          applied: false,
          reasonCode: ConfigDiagnosticReasonCodes.operatorNotRegistered,
          message:
              'no operator is registered under this id, so the rule config '
              'was not installed; the rule resolves to an error verdict',
          ruleIds: Set<String>.unmodifiable(entry.value),
        ),
      );
    }

    return OperatorConfigPlan._(
      diagnostics: List<OperatorConfigDiagnostic>.unmodifiable(diagnostics),
      fatalDiagnostics: List<OperatorConfigDiagnostic>.unmodifiable(fatal),
    );
  }

  /// Every operator node reachable from [node], in document order.
  static List<OperatorNode> _operatorNodesOf(RuleNode node) {
    final found = <OperatorNode>[];
    void visit(RuleNode current) {
      switch (current) {
        case AllNode(:final children):
        case AnyNode(:final children):
          for (final child in children) {
            visit(child);
          }
        case NotNode(:final child):
          visit(child);
        case OperatorNode():
          found.add(current);
        case CompareNode():
          break;
      }
    }

    visit(node);
    return found;
  }

  /// Rule ids whose config disagrees with the first one supplied, or null.
  ///
  /// Two rules asking for the same configuration is not a conflict: the
  /// install is idempotent, so the set stays usable.
  static List<String>? _conflictOf(List<_RuleConfig> supplied) {
    final reference = supplied.first;
    final disagreeing = <String>{};
    for (final candidate in supplied.skip(1)) {
      if (_sameConfig(reference.config, candidate.config)) continue;
      disagreeing.add(reference.ruleId);
      disagreeing.add(candidate.ruleId);
    }
    if (disagreeing.isEmpty) return null;
    return disagreeing.toList()..sort();
  }

  /// Installs [config] on [operator] through its documented adapter.
  static OperatorConfigDiagnostic _applyConfig(
    FilterOperator operator,
    Map<String, Object?> config,
    Set<String> ruleIds,
  ) {
    try {
      switch (operator) {
        case KeywordOperator():
          operator.configure(KeywordOperatorConfig.fromJson(config));
        case RegexOperator():
          operator.configure(RegexOperatorConfig.fromJson(config));
        case AuthorBlocklistOperator():
          operator.configure(AuthorBlocklistConfig.fromJson(config));
        case MentionQualityOperator():
          operator.configure(MentionQualityConfig.fromJson(config));
        case MetadataOperator():
          operator.configure(MetadataOperatorConfig.fromJson(config));
        default:
          return OperatorConfigDiagnostic(
            operatorId: operator.id,
            applied: false,
            reasonCode: ConfigDiagnosticReasonCodes.unsupported,
            message:
                'this build has no config adapter for this operator, so the '
                'rule config was not installed',
            ruleIds: ruleIds,
          );
      }
    } on Object catch (error) {
      return OperatorConfigDiagnostic(
        operatorId: operator.id,
        applied: false,
        reasonCode: ConfigDiagnosticReasonCodes.invalid,
        message: 'the operator rejected the rule config (${error.runtimeType})',
        ruleIds: ruleIds,
      );
    }
    return OperatorConfigDiagnostic(
      operatorId: operator.id,
      applied: true,
      reasonCode: ConfigDiagnosticReasonCodes.applied,
      message: 'config installed from ${ruleIds.length} rule(s)',
      ruleIds: ruleIds,
    );
  }

  /// Structural equality of two inert rule config maps.
  ///
  /// Compared through canonical JSON: a rule config is JSON by construction, so
  /// a deep comparison needs no hand-written recursion and cannot disagree with
  /// what the rule document actually says.
  static bool _sameConfig(
    Map<String, Object?> a,
    Map<String, Object?> b,
  ) {
    if (identical(a, b)) return true;
    try {
      return jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));
    } on Object {
      return false;
    }
  }

  /// JSON-safe, key-sorted form of [value].
  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonical(value[key]),
      };
    }
    if (value is List) {
      return <Object?>[for (final item in value) _canonical(item)];
    }
    return value;
  }

  /// The five static operators with their default (empty) configuration.
  ///
  /// Registration order is dispatch order, so the cheapest judges come first:
  /// author lookup, then literal keyword, then pattern, then mention shape,
  /// then metadata.
  static List<FilterOperator> defaultStaticOperators() => <FilterOperator>[
    AuthorBlocklistOperator(),
    KeywordOperator(),
    RegexOperator(),
    MentionQualityOperator(),
    MetadataOperator(),
  ];

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  static ContentGuardBootstrap _bootstrapOf({
    required OperatorRegistry registry,
    required List<RuleDefinition> rules,
    required String ruleVersion,
    required String buildVariant,
    required bool featureEnabled,
    required List<OperatorConfigDiagnostic> configDiagnostics,
  }) {
    final snapshot = registry.availabilitySnapshot();
    final contentTypes = <String, Set<ContentType>>{
      for (final operator in registry.operators)
        operator.id: Set<ContentType>.unmodifiable(
          operator.supportedContentTypes,
        ),
    };
    return ContentGuardBootstrap(
      capabilities: List<OperatorCapability>.unmodifiable(
        _resolveCapabilities(
          registry,
          snapshot,
          featureEnabled: featureEnabled,
        ),
      ),
      registrySnapshot: Map<String, OperatorAvailability>.unmodifiable(
        snapshot,
      ),
      contentTypesByOperator: Map<String, Set<ContentType>>.unmodifiable(
        contentTypes,
      ),
      ruleCount: rules.length,
      enabledRuleCount: rules.where((rule) => rule.enabled).length,
      ruleVersion: ruleVersion,
      buildVariant: buildVariant,
      featureEnabled: featureEnabled,
      configDiagnostics: configDiagnostics,
    );
  }

  /// Resolves every declared capability against what the registry actually has.
  ///
  /// A capability is available exactly when it names at least one operator and
  /// every named operator is registered and ready. Everything else becomes an
  /// unavailable entry carrying a reason — never a gap in the list.
  ///
  /// When [featureEnabled] is false every capability — implemented or not — is
  /// unavailable with [CapabilityReasonCodes.featureDisabled]. The master switch
  /// is reported ahead of the per-operator reasons because it is the one cause a
  /// setting can change, and reporting "operator disabled" for a switch the user
  /// flipped would send them looking in the wrong place.
  static List<OperatorCapability> _resolveCapabilities(
    OperatorRegistry registry,
    Map<String, OperatorAvailability> snapshot, {
    required bool featureEnabled,
  }) => <OperatorCapability>[
    for (final spec in _capabilitySpecs)
      featureEnabled
          ? _resolveCapability(spec, registry, snapshot)
          : _disabledCapability(spec),
  ];

  /// The report for one capability under a switched-off master switch.
  static OperatorCapability _disabledCapability(_CapabilitySpec spec) =>
      OperatorCapability(
        id: spec.id,
        label: spec.label,
        available: false,
        operatorIds: spec.operatorIds.isEmpty
            ? const <String>{}
            : Set<String>.unmodifiable(spec.operatorIds),
        requiredInputs: const <ContentInput>{},
        reasonCode: CapabilityReasonCodes.featureDisabled,
        message: 'The ContentGuard master switch is off, so nothing runs here.',
      );

  static OperatorCapability _resolveCapability(
    _CapabilitySpec spec,
    OperatorRegistry registry,
    Map<String, OperatorAvailability> snapshot,
  ) {
    if (spec.unimplementedMessage != null) {
      return OperatorCapability(
        id: spec.id,
        label: spec.label,
        available: false,
        operatorIds: const <String>{},
        requiredInputs: const <ContentInput>{},
        reasonCode: CapabilityReasonCodes.notImplemented,
        message: spec.unimplementedMessage,
      );
    }
    if (spec.operatorIds.isEmpty) {
      return OperatorCapability(
        id: spec.id,
        label: spec.label,
        available: false,
        operatorIds: const <String>{},
        requiredInputs: const <ContentInput>{},
        reasonCode: CapabilityReasonCodes.operatorNotRegistered,
        message: 'The capability declares no operator.',
      );
    }
    var available = true;
    String? reasonCode;
    String? message;
    final inputs = <ContentInput>{};
    for (final operatorId in spec.operatorIds) {
      final operator = registry.find(operatorId);
      if (operator == null) {
        available = false;
        reasonCode ??= CapabilityReasonCodes.operatorNotRegistered;
        message ??= 'No operator is registered under "$operatorId".';
        continue;
      }
      final availability = snapshot[operatorId] ?? operator.availability;
      if (!availability.isReady) {
        available = false;
        reasonCode ??=
            availability.reasonCode ??
            CapabilityReasonCodes.operatorUnavailable;
        message ??= '$operatorId is ${availability.state.name} in this build.';
        continue;
      }
      inputs.addAll(operator.requiredInputs);
    }
    return OperatorCapability(
      id: spec.id,
      label: spec.label,
      available: available,
      operatorIds: Set<String>.unmodifiable(spec.operatorIds),
      requiredInputs: available
          ? Set<ContentInput>.unmodifiable(inputs)
          : const <ContentInput>{},
      reasonCode: available ? null : reasonCode,
      message: available ? null : message,
    );
  }

  @override
  String toString() =>
      'ContentGuardService(${account.id}, rules: ${rules.length}, '
      '${bootstrap.availableCapabilities.length} capabilities)';
}
