/// The bridge between a comment list and the ContentGuard decision layer.
///
/// ## The one rule this file exists to enforce
///
/// The source list is never touched. No element is removed, no element is
/// reordered, and no element is rewritten. What comes out is a **parallel
/// projection**: row `i` of the projection describes row `i` of the list the
/// caller is holding, keyed by `contentId`, plus a separate suggestion-anchor
/// set. Everything a widget needs is looked up by index or by id; nothing is
/// looked up by arrival time.
///
/// That is not a stylistic preference. Comment pages paginate, mutate, sort and
/// refresh while async decisions are still in flight, so "the third result that
/// came back" and "the third comment on screen" are different things almost
/// immediately. A hidden comment therefore keeps a placeholder entry — deleting
/// it would shift every row below it, break the scroll offset and move a
/// suggestion card onto a comment it does not belong to.
///
/// ## Why the bridge takes plain values
///
/// The input is [CommentInput], not the platform's reply model. Importing
/// `ReplyInfo` (or anything under `lib/pages/` or `lib/http/`) would drag the
/// transport, the account state and the whole Flutter graph into this file, and
/// it would become unverifiable in the environment this project is developed in,
/// where those package imports cannot even be resolved. The caller supplies the
/// six facts the bridge actually needs and nothing else.
///
/// ## Write-back guard: canonical identity, not caller assertions
///
/// A result is applied only when every part of its identity still matches, and
/// every one of those parts is read from the **[PolicyTrace]** the pipeline
/// stamped — never from an argument the caller chose. A trace already carries
/// contentId, contentVersion, generation and the account/rule run context it
/// ran under; deriving the guard from anything else lets a caller pair one
/// result's presentation with another result's identity and have the bridge
/// accept it.
///
/// The five checks, in order ([ReplyApplyOutcome] names each refusal):
///
/// 1. **surface** — the trace must belong to this bridge's surface;
/// 2. **contentId** — the trace, the presentation and the decision must all name
///    the same id, and that id must be registered *now*;
/// 3. **account** — the result's account must be this bridge's account. The trace
///    does not carry an [AccountScope], so the result's own canonical account is
///    recorded once when it is produced ([ReplyDecision.fromPipelineResult]) and
///    that single value is what is compared, never a fresh guess;
/// 4. **generation** — exactly equal to the current revision. An older value is
///    a replaced list; a newer one does not describe a list that exists yet and
///    would outlive the next refresh. Both are refused, so the guard is equality
///    and not `<`;
/// 5. **contentVersion** — exactly equal to the revision registered for that row
///    right now, so a verdict computed for the previous text of an edited
///    comment cannot land on the current text.
///
/// Only then is the row written, through [PresenterStore.putCurrent], which
/// re-applies the same generation and identity rules at the storage boundary.
/// Attribution is recorded **only** on a successful write and is stamped with
/// the revision it was computed for, so a refused write cannot move a suggestion
/// card.
///
/// ## Registration is a snapshot, not an accumulation
///
/// [buildNodes] receives the complete current list and **replaces** the
/// registry: rows, attribution, card associations and ordering are rebuilt from
/// it. A full refresh therefore cannot leave a removed comment writable, and a
/// stale result for a removed id is refused as
/// [ReplyApplyOutcome.unknownContent] instead of landing in a dead row. A
/// pagination append is expressed by passing the complete list again — the
/// anchor scan is stateless, so re-registering everything is the correct move
/// and cannot duplicate a card.
///
/// ## Anchoring
///
/// [buildNodes] produces the [GuardListNode] snapshot [SuggestionAnchoring]
/// scans. `countsAsViolation` and the hidden-placeholder flag come from the
/// applied decision when one exists, and from the caller's own facts until then,
/// so a card never renders because of stale data.
library;

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/presenter/presenter_store.dart';
import 'package:PiliPlus/services/content_guard/presenter/reply_presentation.dart';
import 'package:PiliPlus/services/content_guard/slice/content_guard_pipeline.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion_machine.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_anchor.dart';

/// One comment as the caller knows it, in the vocabulary the bridge needs.
///
/// Deliberately narrow: these are exactly the facts a comment list already holds
/// and the decision layer cannot derive.
final class CommentInput {
  const CommentInput({
    required this.contentId,
    required this.contentVersion,
    required this.stableOrderKey,
    this.authorUid,
    this.threadId = '',
    this.depth = 0,
    this.countsAsViolation = false,
    this.isHiddenPlaceholder = false,
  });

  /// Platform comment id (rpid as a string). Identity for the projection.
  final String contentId;

  /// Revision of the comment payload being listed.
  ///
  /// Opaque to the bridge: it is compared for equality and never parsed. Anything
  /// that changes when the text, the media or the author attribution changes is a
  /// correct value; a constant is not, because it would let a verdict computed for
  /// the previous text land on the current one.
  final String contentVersion;

  /// The key the list is displayed in.
  ///
  /// The host sorts by whatever it already uses (pinned first, then the server
  /// rank, then a tie-break) and hands the resulting key in. The bridge never
  /// derives it from arrival order — that is exactly the bug it exists to avoid.
  final String stableOrderKey;

  /// Author uid the platform reported, or null when unknown.
  final String? authorUid;

  /// Thread the comment belongs to; `''` for the surface's own top level.
  final String threadId;

  /// Nesting depth.
  final int depth;

  /// Caller-known violation attribution, used only until a decision lands.
  ///
  /// The applied decision takes precedence: once the pipeline has answered, the
  /// bridge reads `attributeViolation` from it and ignores this flag.
  final bool countsAsViolation;

  /// Whether the caller already knows this row stands in for hidden content.
  ///
  /// A hidden comment keeps its slot; this flag makes it a hidden placeholder in
  /// the anchor snapshot from the very first scan instead of from the moment its
  /// decision arrives.
  final bool isHiddenPlaceholder;
}

/// What [ReplyGuardBridge.applyDecisions] did with one result.
///
/// Reported rather than silently dropped: a caller that keeps resubmitting
/// refused results needs to see why they are refused. Every refusal path in
/// [ReplyGuardBridge.applyDecisions] names one of these values.
enum ReplyApplyOutcome {
  /// The row was written to the store.
  applied,

  /// The result belongs to another list revision than the one in force — an
  /// older one (the user replaced the list) or a newer one (it does not describe
  /// a list that exists yet). Dropped.
  stale,

  /// The result judged a different revision of the payload than the one
  /// registered for this row. Dropped: the text the verdict is about is not the
  /// text on screen any more.
  superseded,

  /// No row with that content id is registered in the current list. Covers a
  /// comment that was never listed *and* one removed by a full re-registration.
  unknownContent,

  /// The result belongs to another account, another surface, or its trace and
  /// presentation disagree about which content they describe. Dropped: this is
  /// the cross-scope/paired-identity case, not a timing race.
  foreignResult,

  /// The store kept a row it considers newer or identical; nothing changed.
  unchanged,
}

/// One pipeline result, plus the revision the caller claims it is about.
///
/// Every identity the bridge enforces is read from the result itself — its
/// [PipelineResult.trace] and the canonical carriers the pipeline stamped. The
/// [contentVersion] argument is **not** authoritative: it is the caller's claim,
/// kept so a disagreement is *reported* ([ReplyApplyOutcome.foreignResult])
/// instead of silently resolved in the caller's favour. That is what stops a
/// caller from relabelling a verdict computed for an old revision with the
/// revision now on screen.
final class ReplyDecision {
  const ReplyDecision._({
    required this.result,
    required this.contentId,
    required this.contentVersion,
    required this.claimedContentVersion,
    required this.generation,
    required this.account,
    required this.surface,
  });

  /// Files [result] under its own identity, remembering the claimed revision.
  ///
  /// Nothing is thrown: the identity is taken from [result], and a disagreement
  /// between it and the claim is preserved as data so [ReplyGuardBridge
  /// .applyDecisions] can report a refusal instead of an exception. Resolving the
  /// disagreement here — by preferring either side — is precisely the defect this
  /// guard removes.
  factory ReplyDecision.fromPipelineResult(
    PipelineResult result, {
    required String contentVersion,
  }) => ReplyDecision._(
    result: result,
    contentId: result.trace.contentId,
    contentVersion: result.trace.contentVersion,
    claimedContentVersion: contentVersion,
    generation: result.trace.generation,
    account: result.account,
    surface: result.surface,
  );

  /// The pipeline's answer.
  final PipelineResult result;

  /// Comment this verdict is about, from the trace.
  final String contentId;

  /// Revision of the payload the pipeline actually evaluated, from the trace.
  ///
  /// This is the authoritative value: it is what the pass judged.
  final String contentVersion;

  /// Revision the caller claimed this result was about.
  ///
  /// Recorded only so a claim that contradicts [contentVersion] is reported. It
  /// is never written to a row and never overrides the trace.
  final String claimedContentVersion;

  /// List revision the pipeline stamped this run with, from the trace.
  final int generation;

  /// Account scope the evaluation ran under, from [PipelineResult.account].
  final AccountScope account;

  /// Surface the evaluation ran on, from [PipelineResult.surface].
  final ContentSurface surface;

  @override
  String toString() =>
      'ReplyDecision($contentId@$contentVersion, '
      'claimed: $claimedContentVersion, generation: $generation)';
}

/// Outcome of one [ReplyGuardBridge.applyDecisions] call.
final class ReplyApplyReport {
  const ReplyApplyReport({required this.outcomes});

  /// One outcome per submitted decision, in submission order.
  final List<ReplyApplyOutcome> outcomes;

  /// Number of decisions accepted.
  int get applied => _count(ReplyApplyOutcome.applied);

  /// Number of decisions refused for being from an older list revision.
  int get stale => _count(ReplyApplyOutcome.stale);

  /// Number of decisions refused for being about a different payload revision.
  int get superseded => _count(ReplyApplyOutcome.superseded);

  /// Number of decisions whose content id is not in the current list.
  int get unknown => _count(ReplyApplyOutcome.unknownContent);

  /// Number of decisions refused for belonging to another account, surface or
  /// content identity.
  int get foreign => _count(ReplyApplyOutcome.foreignResult);

  /// Number of decisions the store already agreed with.
  int get unchanged => _count(ReplyApplyOutcome.unchanged);

  /// Total submitted.
  int get total => outcomes.length;

  int _count(ReplyApplyOutcome outcome) =>
      outcomes.where((value) => value == outcome).length;

  @override
  String toString() =>
      'ReplyApplyReport(total: $total, applied: $applied, '
      'stale: $stale, superseded: $superseded, unknown: $unknown, '
      'foreign: $foreign, unchanged: $unchanged)';
}

/// A comment list and its presentations, one slot per source element.
///
/// [contentIds] has exactly one entry per row of the list it was built from, in
/// the same order, so index arithmetic in the caller stays valid: a hidden row
/// occupies its slot with a placeholder, it is not skipped.
final class ReplyGuardProjection {
  const ReplyGuardProjection({
    required this.contentIds,
    required this.byContentId,
    required this.decidedContentIds,
    required this.anchors,
    required this.generation,
  });

  /// Source order, one entry per list row. Never sorted, never filtered.
  final List<String> contentIds;

  /// Presentation per content id. Covers every id in [contentIds]: a row whose
  /// decision has not landed yet carries a [PresenterState.pending] placeholder
  /// rather than being absent.
  final Map<String, ReplyPresentation> byContentId;

  /// Ids a real decision was applied to. [byContentId] minus this set is pending.
  final Set<String> decidedContentIds;

  /// Anchor set recomputed for this snapshot.
  final SuggestionAnchorIndex anchors;

  /// List revision the projection was built for.
  final int generation;

  /// Number of slots, identical to the number of source elements.
  int get length => contentIds.length;

  /// Whether there is nothing to project.
  bool get isEmpty => contentIds.isEmpty;

  /// Presentation for slot [index]; null only when [index] is out of range.
  ReplyPresentation? at(int index) {
    if (index < 0 || index >= contentIds.length) return null;
    return byContentId[contentIds[index]];
  }

  /// Presentation for [contentId], when the list holds it.
  ReplyPresentation? forContentId(String contentId) => byContentId[contentId];

  /// Whether slot [index] has had a real decision applied.
  bool isDecidedAt(int index) {
    if (index < 0 || index >= contentIds.length) return false;
    return decidedContentIds.contains(contentIds[index]);
  }

  /// Anchor rendering at slot [index], or null.
  SuggestionAnchor? anchorAt(int index) {
    if (index < 0 || index >= contentIds.length) return null;
    return anchors.anchorAtNode(nodeIdFor(index));
  }

  /// Whether a suggestion card renders at slot [index].
  bool showsSuggestionCardAt(int index) {
    final presentation = at(index);
    return presentation != null && presentation.showSuggestionCard;
  }

  /// Source indices where a card renders, in list order — the set a builder can
  /// ask about without scanning.
  List<int> get suggestionCardIndices => <int>[
    for (var i = 0; i < contentIds.length; i++)
      if (showsSuggestionCardAt(i)) i,
  ];

  /// Node id the bridge mints for slot [index].
  ///
  /// Derived from the content id and the position so it is stable across rebuilds
  /// of the same list and unique for a list that legitimately repeats a comment.
  String nodeIdFor(int index) => index >= 0 && index < contentIds.length
      ? _nodeIdOf(contentIds[index], index)
      : '';

  @override
  String toString() =>
      'ReplyGuardProjection(rows: $length, decided: '
      '${decidedContentIds.length}, anchors: ${anchors.length}, '
      'generation: $generation)';
}

String _nodeIdOf(String contentId, int index) => '$index#$contentId';

/// An applied decision's attribution, stamped with the payload revision it was
/// computed for.
///
/// The version is part of the record on purpose: attribution is the one field of a
/// verdict that can be stale *independently* of the generation, because it is a
/// statement about a specific edit. Keeping it version-stamped means an edited
/// comment cannot inherit its predecessor's attribution.
final class _Attribution {
  const _Attribution({required this.contentVersion, required this.attribute});

  final String contentVersion;
  final bool attribute;
}

/// Row facts the bridge registered for one content id.
final class _RegisteredRow {
  _RegisteredRow({
    required this.contentVersion,
    required this.rawIndex,
    required this.authorUid,
    required this.threadId,
    required this.depth,
    required this.stableOrderKey,
    required this.countsAsViolation,
    required this.isHiddenPlaceholder,
  });

  final String contentVersion;
  final int rawIndex;
  final String? authorUid;
  final String threadId;
  final int depth;
  final String stableOrderKey;
  final bool countsAsViolation;
  final bool isHiddenPlaceholder;
}

/// Turns a comment list into presentations and suggestion anchors.
///
/// Holds one [PresenterStore] (the presentations), the row facts registered by
/// the last [buildNodes] call, and the card decisions applied by the suggestion
/// machine. It is not a `GetxController`: the store already exposes a listener
/// list, so a page can wrap it in whatever reactive primitive it uses, and this
/// file stays importable from a plain-Dart check script.
final class ReplyGuardBridge {
  ReplyGuardBridge({
    required this.account,
    this.surface = ContentSurface.rootComments,
    PresenterStore? store,
    ContentGuardPipeline? pipeline,
  }) : store = store ?? PresenterStore(),
       _pipeline = _scopedPipeline(pipeline, account);

  /// Refuses a pipeline bound to another account.
  ///
  /// The ledger key is (account, comment id) and the bridge filters by account,
  /// so applying another account's results here would attribute one account's
  /// verdict to another's list. A scope mismatch is a construction bug, so it is
  /// refused here rather than silently producing refusals on every apply.
  static ContentGuardPipeline? _scopedPipeline(
    ContentGuardPipeline? pipeline,
    AccountScope account,
  ) {
    if (pipeline == null) return null;
    if (pipeline.account != account) {
      throw ArgumentError.value(
        pipeline.account,
        'pipeline',
        'is scoped to another account than this bridge (${account.id})',
      );
    }
    return pipeline;
  }

  /// Account every node is scoped to. Cross-account anchors must never merge, so
  /// this is not optional.
  final AccountScope account;

  /// Surface the rows were listed on.
  final ContentSurface surface;

  /// Presentation store. The write-back guard lives here.
  final PresenterStore store;

  /// Pipeline whose results this bridge applies, when one is supplied.
  ///
  /// Held so [beginList] can move the pipeline's revision together with the
  /// store's. Two independent counters would be worse than useless: the store
  /// compares [PresenterStore.generation] against the generation the pipeline
  /// stamped, so letting them drift turns every in-flight result into either a
  /// false stale or a false accept depending on which side is ahead.
  final ContentGuardPipeline? _pipeline;

  final Map<String, _RegisteredRow> _rows = <String, _RegisteredRow>{};
  final Map<String, _Attribution> _attribution = <String, _Attribution>{};
  List<String> _order = const <String>[];

  /// Suggestion id currently rendering per content id.
  final Map<String, String> _cardByContentId = <String, String>{};

  /// Current list revision, taken from [store] so the two cannot drift apart.
  int get generation => store.generation;

  /// Starts a new list revision and drops rows stamped with an older one.
  ///
  /// Call this on refresh, sort change, account switch and filter change — any
  /// event that makes previously computed rows describe something else.
  ///
  /// Advances the pipeline's revision too when one is wired, so the generation on
  /// an in-flight result and the generation the store compares it against are the
  /// same number. The new revision is one past whichever side is ahead, so the
  /// call is safe even if someone bumped the pipeline out of band.
  ///
  /// With no pipeline wired the rows were stamped by some *other* pipeline whose
  /// revision this bridge cannot see, so the new revision is chosen one past the
  /// newest row actually held. Bumping by a fixed step instead would leave those
  /// rows sitting at a revision the store still considers current, and they would
  /// describe a list that no longer exists — the exact failure the guard is for.
  int beginList() {
    _cardByContentId.clear();
    // Attribution is a statement about one specific evaluation, so it cannot
    // outlive the list revision the evaluation belonged to: a changed filter or
    // whitelist would otherwise keep feeding suggestion anchors from a verdict
    // that no longer applies.
    _attribution.clear();
    final pipeline = _pipeline;
    var next = store.generation + 1;
    if (pipeline != null) {
      if (pipeline.generation >= next) next = pipeline.generation + 1;
      pipeline.beginGeneration(next);
    } else {
      for (final row in store.snapshot.values) {
        if (row.generation >= next) next = row.generation + 1;
      }
    }
    // The store only moves one revision at a time and has no setter; each step
    // also drops the rows it supersedes, so the loop settles quickly.
    while (store.generation < next) {
      store.bumpGeneration();
    }
    return store.generation;
  }

  /// Content ids registered by the last [buildNodes] call, in source order.
  List<String> get contentIds => _order;

  /// Registers [rows] and returns the anchor snapshot input.
  ///
  /// Registration is what makes "which list is this result about" answerable:
  /// [applyDecisions] compares a result against the version and flags recorded
  /// here. Call it on every list change, including a pagination append — the
  /// anchor scan is stateless, so passing the whole list again is the correct move
  /// and cannot duplicate a card.
  ///
  /// `rawIndex` is the position inside [rows] as given, before any sorting.
  List<GuardListNode> buildNodes(Iterable<CommentInput> rows) {
    final nodes = <GuardListNode>[];
    final order = <String>[];
    final registered = <String, _RegisteredRow>{};
    var index = 0;
    for (final row in rows) {
      final entry = _RegisteredRow(
        contentVersion: row.contentVersion,
        rawIndex: index,
        authorUid: row.authorUid,
        threadId: row.threadId,
        depth: row.depth,
        stableOrderKey: row.stableOrderKey,
        countsAsViolation: row.countsAsViolation,
        isHiddenPlaceholder: row.isHiddenPlaceholder,
      );
      registered[row.contentId] = entry;
      order.add(row.contentId);
      nodes.add(_nodeOf(row.contentId, entry));
      index++;
    }
    // The registry is replaced, never merged. [rows] is the complete current
    // list, so any id it no longer holds has been removed from the list and must
    // stop being a write-back target: a late verdict for it is refused as
    // unknownContent instead of landing in a row nobody renders. Attribution and
    // card associations are row-scoped state, so they are pruned to the same set
    // — a removed id must not keep contributing to an anchor.
    _rows
      ..clear()
      ..addAll(registered);
    _attribution.removeWhere(
      (contentId, _) => !registered.containsKey(contentId),
    );
    _cardByContentId.removeWhere(
      (contentId, _) => !registered.containsKey(contentId),
    );
    // The stored presentation is row-scoped state too. A registration that no
    // longer lists an id must not keep its verdict: retaining it would grow the
    // store without bound and, worse, silently resurrect the old verdict if the
    // id were ever re-registered at the same revision.
    for (final contentId in store.snapshot.keys) {
      if (!registered.containsKey(contentId)) store.remove(contentId);
    }
    _order = List<String>.unmodifiable(order);
    return List<GuardListNode>.unmodifiable(nodes);
  }

  /// The node for [contentId], reading the applied decision when there is one.
  ///
  /// Once a decision exists it wins over the caller's own flags: the pipeline is
  /// the authority on whether the sighting is attributable ([DecisionComposerOutput
  /// .attributeViolation], which is a narrower question than "was this filtered"),
  /// and a row it turned into a placeholder is a hidden placeholder whether or not
  /// the caller knew. Both reads are version-checked, so a verdict computed for a
  /// previous edit of the comment cannot decide anything about the current one.
  GuardListNode _nodeOf(String contentId, _RegisteredRow row) {
    final stored = _currentVerdict(contentId, row.contentVersion);
    final attribution = _attribution[contentId];
    final attributionApplies =
        stored != null &&
        attribution != null &&
        attribution.contentVersion == row.contentVersion;
    final state = stored?.state;
    return GuardListNode(
      nodeId: _nodeIdOf(contentId, row.rawIndex),
      contentId: contentId,
      accountScopeId: account.id,
      surface: surface,
      threadId: row.threadId,
      depth: row.depth,
      authorUid: row.authorUid,
      rawIndex: row.rawIndex,
      stableOrderKey: row.stableOrderKey,
      countsAsViolation: attributionApplies
          ? attribution.attribute
          : row.countsAsViolation,
      isHiddenPlaceholder:
          row.isHiddenPlaceholder ||
          state == PresenterState.collapsed ||
          state == PresenterState.hidden,
      listGeneration: stored?.generation ?? generation,
    );
  }

  /// The stored presentation for [contentId], but only when it is the verdict
  /// for the revision registered right now.
  ///
  /// Every read of the store goes through here. Reading it directly is how an
  /// old verdict gets relabelled with a new revision: the presentation carries no
  /// revision of its own, so the only way to tell "this judged the text on
  /// screen" from "this judged the previous edit" is the identity stamped beside
  /// it when it was written. A row that fails the check is pending, not decided.
  ContentPresentation? _currentVerdict(
    String contentId,
    String contentVersion,
  ) {
    final entry = store.entryFor(contentId);
    if (entry == null) return null;
    if (!entry.isCurrent(
      contentVersion: contentVersion,
      generation: generation,
    )) {
      return null;
    }
    if (entry.accountScopeId != null && entry.accountScopeId != account.id) {
      return null;
    }
    if (entry.surface != null && entry.surface != surface) return null;
    return entry.presentation;
  }

  /// Applies [decisions] to the store, in submission order.
  ///
  /// Submission order is irrelevant to correctness: every decision is matched by
  /// content id, payload revision and list generation, never by position. Results
  /// that fail a check are refused and reported, never merged into another row.
  ReplyApplyReport applyDecisions(Iterable<ReplyDecision> decisions) {
    final outcomes = <ReplyApplyOutcome>[];
    for (final decision in decisions) {
      outcomes.add(_applyOne(decision));
    }
    return ReplyApplyReport(
      outcomes: List<ReplyApplyOutcome>.unmodifiable(outcomes),
    );
  }

  /// Applies one decision, or reports precisely why it was refused.
  ///
  /// The checks run cheapest-and-broadest first, so the reported outcome names
  /// the real reason rather than whichever check happened to be adjacent to the
  /// write. Nothing mutates before the write succeeds: attribution is recorded
  /// only after [PresenterStore.putCurrent] returns true.
  ReplyApplyOutcome _applyOne(ReplyDecision decision) {
    final contentId = decision.contentId;

    // 1. Provenance: this result must belong to this bridge. A surface or account
    // mismatch is not a race — it is a result from somewhere else, and the
    // suggestion/ledger scopes are per (account, surface), so applying it here
    // would attribute one scope's verdict inside another.
    if (decision.surface != surface) return ReplyApplyOutcome.foreignResult;
    if (decision.account != account) return ReplyApplyOutcome.foreignResult;

    // 2. The result's own carriers must agree with each other, and with the
    // revision the caller claimed for it. A trace about one comment paired with a
    // presentation about another, a generation that is not the one its trace
    // stamped, or a caller relabelling an old verdict with the current revision
    // are all forged pairings: no list event can produce them.
    if (decision.result.contentId != contentId ||
        decision.result.contentVersion != decision.contentVersion ||
        decision.result.generation != decision.generation ||
        decision.result.trace.generation != decision.generation ||
        decision.result.trace.contentId != contentId ||
        decision.result.trace.contentVersion != decision.contentVersion ||
        decision.result.presentation.contentId != contentId ||
        decision.claimedContentVersion != decision.contentVersion) {
      return ReplyApplyOutcome.foreignResult;
    }

    // 3. The row must be in the list registered *now*. This is what refuses a
    // result for a comment a full re-registration removed.
    final registered = _rows[contentId];
    if (registered == null) return ReplyApplyOutcome.unknownContent;

    // 4. The pipeline already noticed the list move while it ran; trusting the
    // row anyway is exactly the bug the guard exists to prevent.
    if (decision.result.isStale) return ReplyApplyOutcome.stale;

    // 5. Generation must be exactly current. `<` would admit a future revision,
    // which then survives every subsequent refresh; `>` is a replaced list.
    if (decision.generation != generation) return ReplyApplyOutcome.stale;

    // 6. The verdict must be about the payload revision on screen now.
    if (decision.contentVersion != registered.contentVersion) {
      return ReplyApplyOutcome.superseded;
    }

    final written = store.putCurrent(
      decision.result.presentation,
      contentVersion: decision.contentVersion,
      accountScopeId: account.id,
      surface: surface,
    );
    if (!written) {
      // The store kept a row it considers newer or identical. Recording
      // attribution for a refused result would let a dropped verdict still move
      // a suggestion card.
      return ReplyApplyOutcome.unchanged;
    }
    _attribution[contentId] = _Attribution(
      contentVersion: decision.contentVersion,
      attribute: decision.result.decision.attributeViolation,
    );
    return ReplyApplyOutcome.applied;
  }

  /// Records which rows may render a suggestion card.
  ///
  /// [SuggestionRenderDecision] comes from
  /// `BlacklistSuggestionMachine.applyTo(anchors)`, which reads the stored
  /// accept/reject/snooze state. Passing the decisions rather than the machine
  /// keeps this file free of the machine's persistence.
  void applySuggestionDecisions(Iterable<SuggestionRenderDecision> decisions) {
    _cardByContentId.clear();
    for (final decision in decisions) {
      if (!decision.shouldRender) continue;
      _cardByContentId[decision.anchor.contentId] =
          decision.anchor.authorSuggestionId;
    }
  }

  /// Builds the projection for the last registered list.
  ///
  /// Every slot is filled: a row with no applied decision becomes a
  /// [PresenterState.pending] placeholder, so a widget never has to guess what an
  /// absent entry means.
  ///
  /// The suggestion-card flag is applied to every slot, decided or not. It is an
  /// anchoring fact — "a card belongs at this row" — derived from the row facts the
  /// caller supplied, and it does not become true when a pipeline verdict lands on
  /// that same row. Gating it on the presentation would make a card wait for an
  /// unrelated async result and, worse, disappear again whenever the row's
  /// decision was dropped as stale.
  ReplyGuardProjection projection() {
    final presentations = <String, ReplyPresentation>{};
    final decided = <String>{};
    for (final contentId in _order) {
      final registered = _rows[contentId];
      final version = registered?.contentVersion ?? '';
      final suggestionId = _cardByContentId[contentId];
      // Only a verdict written for this exact revision, in this revision of the
      // list, is read as one. Anything else is pending: an old verdict must never
      // be relabelled with the current row's version.
      final stored = registered == null
          ? null
          : _currentVerdict(contentId, registered.contentVersion);
      if (stored == null) {
        final pending = ReplyPresentation.pending(
          contentId: contentId,
          contentVersion: version,
          generation: generation,
        );
        presentations[contentId] = suggestionId == null
            ? pending
            : ReplyPresentation(
                contentId: pending.contentId,
                contentVersion: pending.contentVersion,
                state: pending.state,
                isPlaceholder: pending.isPlaceholder,
                recoverable: pending.recoverable,
                reasonCodes: pending.reasonCodes,
                maskedMediaIds: pending.maskedMediaIds,
                generation: pending.generation,
                suggestionId: suggestionId,
                showSuggestionCard: true,
              );
        continue;
      }
      decided.add(contentId);
      presentations[contentId] = ReplyPresentation.fromContentPresentation(
        stored,
        contentVersion: version,
        suggestionId: suggestionId,
        showSuggestionCard: suggestionId != null,
      );
    }
    return ReplyGuardProjection(
      contentIds: _order,
      byContentId: Map<String, ReplyPresentation>.unmodifiable(presentations),
      decidedContentIds: Set<String>.unmodifiable(decided),
      anchors: SuggestionAnchoring.recompute(buildNodes(_currentInputs())),
      generation: generation,
    );
  }

  /// The projection for [rows], after registering them.
  ///
  /// Equivalent to [buildNodes] followed by [projection], and preferred when the
  /// caller has just rebuilt its list: it cannot project a list it did not build
  /// nodes for.
  ReplyGuardProjection projectionFor(Iterable<CommentInput> rows) {
    buildNodes(rows);
    return projection();
  }

  /// Forgets every registered row, keeping the store.
  ///
  /// For a list that was replaced wholesale: the store's generation guard already
  /// drops the old presentations, this drops the row facts that go with them.
  /// [beginList] is the stronger call — it also moves the revision so an in-flight
  /// result cannot be accepted — and is what a refresh should use; this one
  /// exists for a caller that empties the list without changing revision.
  void clearRows() {
    _rows.clear();
    _attribution.clear();
    _order = const <String>[];
    _cardByContentId.clear();
  }

  /// Registered rows, reconstructed so [projection] can recompute anchors without
  /// the caller re-passing the list.
  Iterable<CommentInput> _currentInputs() {
    final inputs = <CommentInput>[];
    for (var i = 0; i < _order.length; i++) {
      final contentId = _order[i];
      final row = _rows[contentId];
      if (row == null) continue;
      inputs.add(
        CommentInput(
          contentId: contentId,
          contentVersion: row.contentVersion,
          stableOrderKey: row.stableOrderKey,
          authorUid: row.authorUid,
          threadId: row.threadId,
          depth: row.depth,
          countsAsViolation: row.countsAsViolation,
          isHiddenPlaceholder: row.isHiddenPlaceholder,
        ),
      );
    }
    return inputs;
  }

  @override
  String toString() =>
      'ReplyGuardBridge(rows: ${_order.length}, generation: $generation, '
      'cards: ${_cardByContentId.length})';
}
