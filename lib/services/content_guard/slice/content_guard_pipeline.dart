/// The vertical ContentGuard slice: one content item in, one explained row out.
///
/// ## What this object is
///
/// The single call a page makes. It holds the pieces that were built and
/// verified in isolation (operator registry, policy engine, decision composer,
/// presenter, violation ledger, suggestion machine) and executes them in the one
/// order that is correct:
///
/// ```
///   GuardContent
///     -> PolicyEngine.evaluate        (rules -> PolicyTrace)
///     -> DecisionComposer.compose     (trace + caller facts -> one decision)
///     -> ContentPresenter.present     (decision -> row state)
///     -> ViolationLedger.record       (only when the decision permits it)
///     -> BlacklistSuggestionMachine   (count -> author-level suggestion)
/// ```
///
/// ## What it deliberately does not do
///
/// * It never hides, masks, collapses, removes or reorders anything. It returns
///   a [ContentPresentation]; removing a list element is the caller's decision
///   and the presenter's contract is that hidden content is still a row.
/// * It never evaluates an operator itself — the engine owns dispatch, and the
///   engine's per-pass verdict cache is what stops one operator being asked
///   twice in a pass.
/// * It never derives an author. The ledger receives
///   [GuardContent.authorUid] — the uid the platform reported — and nothing
///   else, so an operator's evidence can never accuse an account.
///
/// ## Account binding
///
/// The pipeline is scoped to one [AccountScope]. [evaluate] refuses content
/// carrying a different scope instead of writing account A's ledger entry from
/// account B's content: the ledger key is (account, comment), so a mismatch is
/// a cross-account leak, not a cosmetic bug.
///
/// ## Generation guard
///
/// List state is asynchronous and completion order is never list order. The
/// pipeline carries a monotonic `generation`; [evaluate] captures it on entry
/// and re-reads it three times:
///
/// 1. **before** the ledger/suggestion writes — a run whose generation has
///    already moved is reported as [PipelineResult.isStale] and records
///    nothing at all;
/// 2. **between** the awaited ledger record and the suggestion reconcile — a run
///    that went stale while the store write was in flight keeps its (idempotent)
///    ledger entry, because that accounting is keyed and a user's later
///    correction applies to it, but writes no suggestion state;
/// 3. **at the end**, for [PipelineResult.isStale]: the row is reported as stale
///    and its [ContentPresentation] is stamped with the *run's* generation so
///    `PresenterStore.put` refuses it through the write-back guard that already
///    exists.
///
/// The choice is therefore "finish the idempotent accounting, refuse the row":
/// dropping a ledger entry on a race would under-count a violation the user may
/// already have acted on, while showing a stale row would resurrect a list the
/// user has replaced.
///
/// The conclusive stale check is the *last* thing that happens before a
/// suggestion is reconciled: an entry already handed to the ledger may be
/// written (it is idempotent and the accounting is what the user's correction
/// later applies to), but no suggestion state may be created, revised or
/// invalidated for a list the user has already replaced.
///
/// ## Comment-only accounting
///
/// The ledger key is (account, comment id), so a video, article, dynamic or
/// search result that shares an id with a comment would merge into that
/// comment's entry and accuse the wrong author ([ViolationKey] cannot tell the
/// two apart). Accounting is therefore restricted to
/// [ContentType.comment]: other content types are still evaluated, composed and
/// presented exactly as before, and their decision, trace and presentation are
/// returned unchanged — only the ledger entry and the suggestion candidate are
/// not created.
///
/// ## Windows are the configured ones
///
/// The author count that feeds [BlacklistSuggestionMachine.reconcile] uses the
/// ledger's own window arithmetic with the machine's configured
/// [SuggestionPolicy.windowDays] — never the ledger's built-in default. A policy
/// that says one day must count one day, otherwise the threshold is reached on
/// sightings the configured window excludes.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:PiliPlus/services/content_guard/decision/decision.dart';
import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';
import 'package:PiliPlus/services/content_guard/operator/operator_registry.dart';
import 'package:PiliPlus/services/content_guard/policy/policy.dart';
import 'package:PiliPlus/services/content_guard/presenter/content_presenter.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion_machine.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_ledger.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_record.dart';

/// Adapts the concrete [OperatorRegistry] to the narrow resolver the policy
/// layer declares.
///
/// The policy layer must not import the registry (it would pull the operator
/// layer into every rule test), so the two are joined here, in the assembly
/// layer, and nowhere else. Lookup is exact: an unknown id resolves to null,
/// which the engine reports as `condition.operator_not_found` — an error
/// verdict, never a silent allow.
final class RegistryOperatorResolver implements FilterOperatorResolver {
  const RegistryOperatorResolver(this.registry);

  /// Registry this resolver dispatches into.
  final OperatorRegistry registry;

  @override
  FilterOperator? resolve(String operatorId) => registry.find(operatorId);
}

/// Everything one [ContentGuardPipeline.evaluate] produced.
///
/// The four required carriers are the slice's contract. [generation],
/// [isStale] and [authorSuggestion] are the additions the composition needs:
/// the first two make the write-back guard usable, the third hands the caller
/// the author-level suggestion the ledger count produced without a second
/// round trip.
///
/// ## Canonical identity
///
/// [account], [surface], [contentId], [contentVersion] and [generation] are the
/// identity of the run, copied from the content the pass received. They exist so
/// a consumer never has to guess or re-derive "which account, which surface,
/// which revision" from its own state: a result is written back only when all of
/// them still match the list it is being applied to, and reading any of them
/// from a caller-supplied field instead is how a verdict ends up on content it
/// never judged. The trace carries the content side of the same identity, and
/// the constructor refuses a result whose trace disagrees with it.
final class PipelineResult {
  const PipelineResult({
    required this.presentation,
    required this.decision,
    required this.trace,
    required this.violation,
    required this.account,
    required this.surface,
    required this.contentId,
    required this.contentVersion,
    required this.generation,
    required this.isStale,
    this.authorSuggestion,
  });

  /// Account scope this run was evaluated under.
  ///
  /// Copied from the evaluated content, which the pipeline already refuses to
  /// accept from another scope, so this value is authoritative rather than a
  /// caller's claim.
  final AccountScope account;

  /// Surface the content was listed on.
  final ContentSurface surface;

  /// Content this result describes, from the trace.
  final String contentId;

  /// Payload revision this result judged, from the trace.
  final String contentVersion;

  /// The row to render. Never null, and never a deleted list element: the
  /// vocabulary is a normal row, a placeholder, a masked row or an uncertain
  /// row.
  final ContentPresentation presentation;

  /// The merged decision the row came from, for explanation surfaces.
  final DecisionComposerOutput decision;

  /// The full rule pass, including the rules that did not fire.
  final PolicyTrace trace;

  /// What the ledger did with this sighting, or null when no violation was
  /// recorded: nothing was attributable, the content is not a comment (the
  /// ledger is comment-keyed), or the run went stale before the write.
  final ViolationRecordOutcome? violation;

  /// List revision this result belongs to. A caller writing the row back must
  /// use `PresenterStore.put`, whose guard is what actually drops a stale row.
  final int generation;

  /// Whether the generation moved while this run was in flight.
  ///
  /// A stale result is informational only and must not be written back to the
  /// list. A run that was already stale when it reached the writes recorded
  /// nothing at all; a run that went stale *during* them may keep the
  /// idempotent ledger entry it already started (see the library doc) but never
  /// reconciles a suggestion for it.
  final bool isStale;

  /// The author-level suggestion in force after this sighting, when one exists
  /// and qualifies.
  ///
  /// Null whenever [violation] is null, and null for a run that went stale while
  /// the ledger write was in flight: the entry is kept, the suggestion mutation
  /// is refused, so the caller learns the author state through the machine
  /// rather than from a row belonging to a list it has already replaced.
  final BlacklistSuggestion? authorSuggestion;

  /// Whether the row is shown normally.
  bool get isAllowed => presentation.state == PresenterState.allowed;

  /// Whether a violation entry was written or merged for this sighting.
  bool get recordedViolation => violation != null;

  /// Whether this sighting is the first *attributable* one for its comment.
  bool get insertedViolation => violation == ViolationRecordOutcome.inserted;

  /// Stable reason codes behind [presentation]. Never content text.
  Set<String> get reasonCodes => presentation.reasonCodes;

  @override
  String toString() =>
      'PipelineResult(${presentation.contentId}, ${presentation.state.wireName}, '
      'generation: $generation, stale: $isStale, '
      'violation: ${violation?.wireName ?? 'none'})';
}

/// The one object a page holds to judge content.
final class ContentGuardPipeline {
  ContentGuardPipeline({
    required this.registry,
    required this.engine,
    required DecisionComposer composer,
    required ContentPresenter presenter,
    required ViolationLedger ledger,
    required BlacklistSuggestionMachine suggestions,
    required this.account,
    required List<RuleDefinition> rules,
    required int Function() nowMs,
    int generation = 0,
  }) : _composer = composer,
       _presenter = presenter,
       _ledger = ledger,
       _suggestions = suggestions,
       _rules = List<RuleDefinition>.unmodifiable(rules),
       _nowMs = nowMs,
       _generation = generation,
       ruleVersion = ruleVersionFor(rules) {
    _checkEngineMatchesRules(engine, rules);
  }

  /// Registry the engine resolves operator ids through.
  ///
  /// Held (not just passed to the engine) so a caller can ask the same instance
  /// what is registered and what is unavailable — the capability report reads
  /// this object and nothing else.
  final OperatorRegistry registry;

  /// The rule engine. Must be built over the same rule set as [rules] and over
  /// a resolver backed by [registry]; the constructor rejects a rule-id
  /// mismatch instead of mislabelling a trace.
  final PolicyEngine engine;

  /// Account every run and every ledger entry is scoped to.
  final AccountScope account;

  /// Rule-set version stamped into every run context and decision cache key.
  ///
  /// Derived from the canonical JSON of [rules], so an unrelated edit to a rule
  /// document cannot leave a stale cache entry answering for the new set. Not
  /// derived from the clock: two processes given the same rules must agree.
  final String ruleVersion;

  final DecisionComposer _composer;
  final ContentPresenter _presenter;
  final ViolationLedger _ledger;
  final BlacklistSuggestionMachine _suggestions;
  final List<RuleDefinition> _rules;
  final int Function() _nowMs;

  int _generation;

  /// Rule set this pipeline evaluates.
  List<RuleDefinition> get rules => _rules;

  /// Violation ledger this pipeline records into.
  ViolationLedger get ledger => _ledger;

  /// Author-level suggestion machine this pipeline reconciles after a record.
  BlacklistSuggestionMachine get suggestions => _suggestions;

  /// Current list revision.
  int get generation => _generation;

  /// Starts a new list revision.
  ///
  /// Monotonic on purpose: a generation that goes backwards would make every
  /// in-flight result look current. Throws [ArgumentError] when the new value is
  /// not greater than the current one.
  void beginGeneration(int generation) {
    if (generation <= _generation) {
      throw ArgumentError.value(
        generation,
        'generation',
        'must be greater than the current generation $_generation',
      );
    }
    _generation = generation;
  }

  /// Evaluates one content item end to end.
  ///
  /// [manualOverride], [authorWhitelisted] and [authorFollowed] are caller
  /// facts: the composer reads them and the pipeline never infers them.
  ///
  /// Throws [ArgumentError] when [GuardContent.account] is not [account]: the
  /// ledger key is (account, comment id), so recording another scope's content
  /// here would put an entry in the wrong account.
  Future<PipelineResult> evaluate(
    GuardContent content, {
    ManualOverride manualOverride = ManualOverride.none,
    bool authorWhitelisted = false,
    bool authorFollowed = false,
  }) async {
    if (content.account != account) {
      throw ArgumentError.value(
        content.account,
        'content.account',
        'does not match this pipeline scope ${account.id}',
      );
    }
    final generation = _generation;
    final request = PolicyRequest(
      content: content,
      runContext: OperatorRunContext(
        account: account,
        ruleVersion: ruleVersion,
        generation: generation,
      ),
    );

    final trace = await engine.evaluate(request);
    final decision = _composer.compose(
      content: content,
      trace: trace,
      manualOverride: manualOverride,
      authorWhitelisted: authorWhitelisted,
      authorFollowed: authorFollowed,
    );
    final presentation = _presenter.presentContent(
      content: content,
      decision: decision,
      generation: generation,
    );

    // Guard 1: no side effect for a run whose list is already gone.
    final liveAtRecord = _generation == generation;
    ViolationRecordOutcome? violation;
    BlacklistSuggestion? suggestion;
    // The ledger key is (account, comment id): accounting anything else would
    // merge into a comment's entry and accuse that comment's author for another
    // content type's content. Non-comment content keeps its decision, trace and
    // presentation; it only stays out of the comment ledger.
    if (liveAtRecord &&
        decision.attributeViolation &&
        content.contentType == ContentType.comment) {
      final ledgerResult = await _ledger.record(
        _attributionOf(
          content: content,
          decision: decision,
          trace: trace,
          observedAtMs: _nowMs(),
        ),
      );
      violation = ledgerResult.outcome;
      final author = content.authorUid?.trim();
      if (author != null && author.isNotEmpty) {
        // Guard 1b: the awaited write may have outlived the list it was made
        // for. The entry stays (see the guard-2 note and the library doc), but
        // a suggestion write is a *user-facing* mutation of author state and is
        // not idempotent across lists, so it may not happen for a replaced one.
        // Re-checked here, not after the reconcile, because reconcile is the
        // mutation.
        if (_generation == generation) {
          // The count the ledger already maintains is the only input the machine
          // gets, measured over the *configured* window: a policy that says one
          // day must not reach a threshold on a ten-day-old sighting. Reconciling
          // is idempotent for an unchanged count, so a repeated evaluate()
          // neither re-raises nor revises a user's decision.
          suggestion = await _suggestions.reconcile(
            authorUid: author,
            violationCount: _ledger.countFor(
              author,
              windowDays: _suggestions.policy.windowDays,
            ),
          );
        }
      }
    }

    // Guard 2: the generation may have moved while the operator work or the
    // store writes were in flight. Accounting already handed to the ledger
    // stays (it is keyed and idempotent, and the user's correction applies to
    // it); no suggestion was written for it (guard 1b); the row is reported as
    // stale and carries the run's own generation so the presenter store drops
    // it.
    final isStale = _generation != generation;
    return PipelineResult(
      presentation: presentation,
      decision: decision,
      trace: trace,
      violation: violation,
      account: account,
      surface: content.surface,
      contentId: trace.contentId,
      contentVersion: trace.contentVersion,
      generation: generation,
      isStale: isStale,
      authorSuggestion: suggestion,
    );
  }

  /// The attribution the ledger receives for one attributed decision.
  ///
  /// Author and comment id come from the content; reason codes, rule ids,
  /// operator ids and evidence come from the pass. Nothing identity-shaped is
  /// read out of a [FilterResult].
  ViolationAttribution _attributionOf({
    required GuardContent content,
    required DecisionComposerOutput decision,
    required PolicyTrace trace,
    required int observedAtMs,
  }) {
    final ruleIds = <String>{
      for (final entry in trace.rules)
        if (entry.didMatch && (entry.appliedAction?.isHidingAction ?? false))
          entry.rule.id,
    };
    final operatorIds = <String>{};
    final evidence = <FilterEvidence>[];
    for (final hit in decision.hits) {
      operatorIds.add(hit.operatorId);
      evidence.addAll(hit.evidence);
    }
    return ViolationAttribution(
      commentId: content.contentId,
      authorUid: content.authorUid,
      // The composer already answered "may this be attributed?", and this
      // method is only reached when that answer was true.
      attributeViolation: decision.attributeViolation,
      surface: content.surface,
      reasonCodes: decision.violationReasonCodes,
      ruleIds: Set<String>.unmodifiable(ruleIds),
      operatorIds: Set<String>.unmodifiable(operatorIds),
      evidence: dedupeEvidence(evidence),
      observedAtMs: observedAtMs,
      // The revision the pass actually judged. Without it the ledger stores an
      // attribution that cannot say WHICH edit of the comment it accused, so
      // `ViolationCorrection.correctsVersion` degenerates to "always" and the
      // persisted record loses the only fact that ties it to the payload. It is
      // the content's own opaque digest, never the body: see
      // `replyGuardContentVersionOf`.
      contentVersion: content.contentVersion,
    );
  }

  static void _checkEngineMatchesRules(
    PolicyEngine engine,
    List<RuleDefinition> rules,
  ) {
    final engineIds = <String>[for (final rule in engine.rules) rule.id]
      ..sort();
    final givenIds = <String>[for (final rule in rules) rule.id]..sort();
    if (engineIds.length != givenIds.length) {
      throw ArgumentError.value(
        rules,
        'rules',
        'the engine was built from ${engineIds.length} rule(s), not '
            '${givenIds.length}',
      );
    }
    for (var i = 0; i < engineIds.length; i++) {
      if (engineIds[i] != givenIds[i]) {
        throw ArgumentError.value(
          rules,
          'rules',
          'rule ids do not match the engine (engine: ${engineIds[i]}, '
              'given: ${givenIds[i]})',
        );
      }
    }
  }

  /// Stable version of [rules] for run contexts, traces and decision cache
  /// keys.
  ///
  /// Canonical rule JSON is hashed, so the value changes exactly when the rule
  /// *meaning* does and two instances given the same rules agree without
  /// sharing a clock.
  static String ruleVersionFor(List<RuleDefinition> rules) {
    final buffer = StringBuffer();
    for (final rule in rules) {
      buffer.writeln(RuleSchema.encodeJson(rule));
    }
    final digest = sha256.convert(utf8.encode(buffer.toString())).toString();
    return 'rules.v${RuleSchema.currentSchemaVersion}.'
        '${digest.substring(0, 16)}';
  }

  /// Content types any registered operator declares support for.
  ///
  /// A pure convenience for a capability banner; it never narrows dispatch,
  /// which stays the registry's decision.
  Set<ContentType> get declaredContentTypes => <ContentType>{
    for (final operator in registry.operators)
      ...operator.supportedContentTypes,
  };
}
