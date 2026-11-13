/// ContentGuard lifecycle for one root comment list.
///
/// Holds this list's [ContentGuardOwner], the [ContentGuardLease] its bridge is
/// bound to, and the presentation state. One owner per list, never shared: the
/// ledger key is (account, comment id), so a shared owner would attribute one
/// list's verdicts to another's rows.
///
/// ## Disabled is the old path
///
/// With `Pref.contentGuardEnabled` false, [syncContentGuard] builds nothing, no
/// evaluation runs and no ledger write happens. The projection stays null, the
/// views render exactly as before, and the transport keeps its default
/// `retainBlockedReplies: false`.
///
/// ## Generation is owned by the owner, not by the bridge
///
/// [ReplyGuardBridge.beginList] bumps the pipeline generation. A lease captured
/// before that bump would fail `isCurrent` forever, so every replacement calls
/// [ContentGuardOwner.adoptCurrentGeneration] with the exact generation the
/// bridge just minted. The lease is never re-stamped onto an old result: a result
/// carries the generation it was computed under and the bridge compares it.
///
/// ## Attribution starts false
///
/// [CommentInput.countsAsViolation] is the caller's claim that a row may count
/// against its author, and the bridge trusts it only until a real decision lands.
/// It therefore starts **false** for every row. `ReplyGrpc.isClientBlocked` is
/// the wrong source for it: that map is the legacy *reason* cache — any reason,
/// including "keyword hit" and "user level too low" — and using it would make
/// every collapsed row an author violation and let the bridge pick a suggestion
/// anchor before the pipeline had judged anything. Attribution comes from the
/// applied decision and from nowhere else.
///
/// ## One policy facts object per build
///
/// The controller registers rows and the widgets render them; both derive the
/// payload revision through [replyGuardVersionOfReply] over the facts returned by
/// [guardPolicyFacts]. One instance serves the whole list build, so the two
/// sides cannot straddle a settings change and leave every row pending.
library;

import 'dart:async';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/grpc/reply.dart' show ReplyGrpc;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/reply/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply/reply_guard_live_policy.dart';
import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/account_scope_adapter.dart';
import 'package:PiliPlus/services/content_guard/model/content_context.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/media_ref.dart';
import 'package:PiliPlus/services/content_guard/owner/content_guard_owner.dart';
import 'package:PiliPlus/services/content_guard/presenter/presenter.dart';
import 'package:PiliPlus/services/content_guard/slice/content_guard_pipeline.dart'
    show PipelineResult;
import 'package:PiliPlus/services/content_guard/source/static_reply_source.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_anchor.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_policy.dart';
import 'package:PiliPlus/services/content_guard/violation/violation.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

mixin ReplyGuardListMixin<R> on ReplyController<R> {
  ContentGuardOwner? _owner;

  /// Static verdicts captured from the authoritative legacy filter.
  ///
  /// Keyed by content id and shared by reference with the source closure: a
  /// replacement clears the map instead of replacing it, because a new map would
  /// leave the closure reading the old one and every operator would answer
  /// `unknown` forever.
  final Map<String, StaticReplySnapshot> _guardSnapshots =
      <String, StaticReplySnapshot>{};
  ContentGuardLease? _lease;
  bool _guardSuggestionsEnabled = false;
  int _guardThreshold = 0;
  int _guardWindowDays = 0;
  String _guardFilterRevision = '';
  ReplyGuardListState<ReplyInfo>? _guardState;
  Worker? _guardWorker;
  AccountScope? _boundAccount;

  /// Display index per content id, rebuilt on every commit.
  ///
  /// The anchor scan sorts by [CommentInput.stableOrderKey], so that key must be
  /// the order the list is **displayed** in — otherwise "two contiguous comments"
  /// would mean two adjacent ids rather than two adjacent rows, and a card would
  /// render under a comment that is not first in its on-screen run.
  ///
  /// A position, not a timestamp: the root list is server-ordered (hot or by
  /// time) and client-sorted only for pinned rows, so creation time is not the
  /// display order. Indices are stable within one list revision because a fetch
  /// either replaces the list (a new revision) or appends to its tail.
  Map<String, String> _guardOrderKeys = <String, String>{};

  /// Display key of [row] in the list committed right now.
  String _guardOrderKeyOf(ReplyInfo row) =>
      _guardOrderKeys[row.id.toString()] ?? row.id.toString().padLeft(20, '0');

  void _reindexOrder(List<ReplyInfo> rows) {
    _guardOrderKeys = <String, String>{
      for (var index = 0; index < rows.length; index++)
        rows[index].id.toString(): index.toString().padLeft(8, '0'),
    };
  }

  /// The policy facts the current list build derives every row's revision from.
  ///
  /// Re-read on each commit and on each rebuild, never per row: one object makes
  /// the controller and the widgets agree by construction, and keeps the digest
  /// cost per build instead of per row. Null while the guard is inactive.
  ReplyGuardPolicyFacts? _guardPolicyFacts;

  /// Facts the views must pass to [replyGuardVersionOfReply] for this list.
  ///
  /// Non-null exactly while a live lease exists, so a widget can fall back to a
  /// fresh read only when the guard is inactive — and then no revision it derives
  /// can be compared against a projection, because there is none.
  ReplyGuardPolicyFacts? get guardPolicyFacts => _guardPolicyFacts;

  /// Suggestions currently renderable, by anchor node id.
  final RxMap<String, BlacklistSuggestion> guardSuggestions =
      <String, BlacklistSuggestion>{}.obs;

  /// Projection the views render, or null when the guard is inactive.
  ReplyGuardProjection? get contentGuardProjection => _guardState?.projection;

  ReplyGuardBridge? get contentGuardBridge => _guardState?.bridge;

  /// The live lease, or null.
  ///
  /// `isCurrent` alone is not enough: it only proves the owner has not been
  /// invalidated. A guest, a different account, or a disabled feature must also
  /// read as "no lease" here, otherwise a stale scope could still write into the
  /// ledger after the user switched account or turned the feature off.
  ContentGuardLease? get contentGuardLease {
    final lease = _lease;
    if (lease == null || !lease.isCurrent) return null;
    if (!Pref.contentGuardEnabled) return null;
    final account = contentGuardRequestScope;
    if (account == null || account != _boundAccount) return null;
    return lease;
  }

  bool get isContentGuardActive => contentGuardLease != null;

  /// Whether the transport must retain statically-filtered rows for this list.
  ///
  /// True only while the feature is enabled AND this list holds a live lease for
  /// a stable, non-guest account. Default false keeps the old transport path, so
  /// the five static filters still remove rows exactly as they did before.
  bool get contentGuardRetainFilteredRows =>
      Pref.contentGuardEnabled && isContentGuardActive;

  /// Scope of the account the CURRENT request runs under.
  ///
  /// Taken from the session that will actually fetch, never from `Accounts.main`
  /// at result time: an account switch between request and completion must not
  /// let one account's verdict be written into another account's ledger.
  AccountScope? get contentGuardRequestScope {
    final account = rootRequestAccount;
    if (account == null || account is NoAccount) return null;
    try {
      return scopeOf(account);
    } on Object {
      return null;
    }
  }

  /// The account this list's next request will run under, or null when unbound.
  ///
  /// Declared abstract: [RootReplyController] implements it from the fetch
  /// session, and a mixin default of null would shadow that.
  Account? get rootRequestAccount;

  ContentSurface get guardSurface => ContentSurface.rootComments;

  /// Keeps statically-filtered rows for the guard, and only for it.
  ///
  /// Overrides the plain-false getter on the root controller. When the feature is
  /// off - or no live lease exists - this reads false and the transport removes
  /// the rows exactly as before, so the default path is byte-identical.
  @override
  bool get retainBlockedReplies => contentGuardRetainFilteredRows;

  /// Reconciles the guard with the current settings and account.
  ///
  /// Called at the start of every replacing fetch, so a settings change or an
  /// account switch takes effect on the next refresh rather than on a timer.
  /// Returns true when a live lease exists afterwards.
  Future<bool> syncContentGuard() async {
    // Refreshed before every early return: the row widgets read it while they
    // build, and a stale object would make them derive a revision the controller
    // never registered.
    _guardPolicyFacts = replyGuardLivePolicyFacts();
    if (!Pref.contentGuardEnabled) {
      _retireGuard();
      return false;
    }
    final account = contentGuardRequestScope;
    if (account == null) {
      _retireGuard();
      return false;
    }
    final owner = _owner ??= ContentGuardOwner();
    final current = owner.current;
    final filterRevision = _guardPolicyFacts!.revision;
    final suggestionsEnabled = Pref.contentGuardSuggestionsEnabled;
    final threshold = Pref.contentGuardSuggestionThreshold;
    final windowDays = Pref.contentGuardSuggestionWindowDays;
    // Same account, live lease AND unchanged settings: keep the assembly and its
    // durable state. Comparing the settings is not optional — the threshold and
    // window decide whether a card may render at all, and the filter revision
    // decides whether a verdict still applies, so a user who changes any of them
    // must see the effect on the next refresh rather than on a restart.
    if (current != null &&
        _boundAccount == account &&
        _guardFilterRevision == filterRevision &&
        _guardSuggestionsEnabled == suggestionsEnabled &&
        _guardThreshold == threshold &&
        _guardWindowDays == windowDays) {
      return true;
    }
    final source = StaticReplySource(
      // Reads the LIVE map. Capturing the local `snapshots` copy instead would
      // make every operator see a missing snapshot and answer unknown forever,
      // which is exactly the collapse/count path never firing.
      lookup: (content) => _guardSnapshots[content.contentId],
    );
    final ContentGuardLease? lease;
    try {
      lease = await owner.rebuild(
        ContentGuardOwnerConfig(
          store: HiveKeyValueStore.fromAccessor(() => GStorage.localCache),
          account: account,
          source: source,
          rules: source.createRules(),
          featureEnabled: Pref.contentGuardEnabled,
          suggestionsEnabled: Pref.contentGuardSuggestionsEnabled,
          suggestionPolicy: SuggestionPolicy(
            threshold: Pref.contentGuardSuggestionThreshold,
            windowDays: Pref.contentGuardSuggestionWindowDays,
          ),
        ),
      );
    } on Object {
      _retireGuard();
      return false;
    }
    if (lease == null || isClosed) {
      _retireGuard();
      return false;
    }
    _lease = lease;
    _boundAccount = account;
    // A new owner/bridge means a new list: every snapshot belongs to the previous
    // revision. The map is CLEARED, never replaced, because the source closure
    // and captureGuardSnapshot must keep sharing this one instance.
    _guardSnapshots.clear();
    _guardFilterRevision = filterRevision;
    _guardSuggestionsEnabled = suggestionsEnabled;
    _guardThreshold = threshold;
    _guardWindowDays = windowDays;
    _guardState = ReplyGuardListState<ReplyInfo>(
      bridge: ReplyGuardBridge(
        account: account,
        surface: guardSurface,
        pipeline: lease.service.pipeline,
      ),
      inputOf: guardInputOf,
    );
    _guardWorker ??= ever<LoadingState<List<ReplyInfo>?>>(
      loadingState,
      _onGuardCommit,
    );
    return true;
  }

  void _retireGuard() {
    _guardWorker?.dispose();
    _guardWorker = null;
    _owner?.close();
    _owner = null;
    _lease = null;
    _boundAccount = null;
    _guardState?.reset();
    _guardState = null;
    _guardPolicyFacts = null;
    _guardFilterRevision = '';
    _guardSnapshots.clear();
    _guardOrderKeys = <String, String>{};
    guardSuggestions.clear();
  }

  void _onGuardCommit(LoadingState<List<ReplyInfo>?> state) {
    final guard = _guardState;
    // The PRE-bump lease reference, taken before commit(): commit() calls
    // beginList(), which advances the pipeline generation, and a lease read
    // after that would already fail isCurrent. adoptCurrentGeneration needs the
    // exact reference that bound this bridge.
    final boundLease = _lease;
    if (guard == null || boundLease == null) return;
    final rows = state.dataOrNull;
    if (rows == null) return;
    // A settings change between two commits is a new policy revision, and a
    // revision the facts do not reflect would make every registered row pending.
    _guardPolicyFacts ??= replyGuardLivePolicyFacts();
    // Order keys BEFORE commit: registration reads them to build the anchor scan's
    // sort key.
    _reindexOrder(rows);
    guard.commit(rows);
    _syncLeaseGeneration(boundLease);
    _refreshSuggestionCards();
    // Evaluate what is not yet decided. Detached on purpose: the listener runs
    // during a state notification and must not turn into a second fetch.
    if (Pref.contentGuardEnabled) {
      unawaited(evaluateGuardRows());
    }
  }

  /// Re-synchronizes the lease after the bridge minted a new generation.
  ///
  /// Without this the lease would be permanently stale: the bridge bumps the
  /// pipeline, so the lease captured before the bump fails every `isCurrent`.
  void _syncLeaseGeneration(ContentGuardLease lease) {
    final owner = _owner;
    if (owner == null) return;
    final generation = lease.service.pipeline.generation;
    try {
      _lease = owner.adoptCurrentGeneration(lease, generation: generation);
    } on Object {
      _lease = null;
    }
  }

  /// Re-reads renderable suggestions from durable state.
  ///
  /// Always re-read, never cached: another list may have accepted or rejected
  /// the same author, and a cached decision would keep showing a card that is
  /// no longer valid.
  void _refreshSuggestionCards() {
    final lease = contentGuardLease;
    final projection = _guardState?.projection;
    guardSuggestions.clear();
    if (lease == null || projection == null) return;
    if (!lease.suggestionsEnabled) return;
    final machine = lease.service.suggestions;
    final decisions = machine.applyTo(projection.anchors);
    for (final decision in decisions) {
      final suggestion = decision.suggestion;
      if (!decision.shouldRender || suggestion == null) continue;
      guardSuggestions[decision.anchor.nodeId] = suggestion;
    }
  }

  /// The suggestion card that belongs at [index], or null.
  ///
  /// Read by the views through an `Obx` so a card appears, disappears or moves
  /// as soon as [guardSuggestions] changes — accept, reject, a settings change or
  /// another list's decision all land here.
  BlacklistSuggestion? guardSuggestionAt(int index) {
    final projection = _guardState?.projection;
    if (projection == null) return null;
    if (index < 0 || index >= projection.length) return null;
    return guardSuggestions[projection.nodeIdFor(index)];
  }

  /// The anchor a card at [index] acts on, or null when none renders there.
  SuggestionAnchor? guardSuggestionAnchorAt(int index) {
    final projection = _guardState?.projection;
    if (projection == null) return null;
    if (index < 0 || index >= projection.length) return null;
    return projection.anchors.anchorAtNode(projection.nodeIdFor(index));
  }

  /// Evaluates every registered row that has no current verdict.
  ///
  /// Deduplicated by list generation plus payload version, so a redraw cannot
  /// re-evaluate a row whose verdict is already current.
  Future<void> evaluateGuardRows() async {
    final lease = contentGuardLease;
    final guard = _guardState;
    if (lease == null || guard == null) return;
    if (!Pref.contentGuardEnabled) return;
    final rows = guard.rows;
    if (rows == null) return;
    final generation = guard.generation;
    // Capture the static verdict for every CURRENT root row before judging any
    // of them: the source operator reads this map, and a row without a snapshot
    // answers unknown rather than being collapsed or counted.
    for (final row in rows) {
      captureGuardSnapshot(row);
    }
    final results = <ReplyDecision>[];
    for (final row in rows) {
      if (isClosed || generation != guard.generation) break;
      final input = guardInputOf(row);
      if (guard.isDecided(input.contentId, input.contentVersion)) continue;
      final content = guardContentOf(row);
      final result = await _owner?.evaluate(content);
      if (result == null) continue;
      // Promote a qualified candidate to visible. Without this the machine
      // never renders a card: a candidate is only a record until presented.
      await _lease?.presentSuggestion(result);
      // Re-validate: presentation is async, and the lease may have been
      // retired (account switch, disable, refresh) while it ran.
      final liveLease = contentGuardLease;
      if (liveLease == null || !liveLease.accepts(result)) continue;
      results.add(
        ReplyDecision.fromPipelineResult(
          result,
          contentVersion: input.contentVersion,
        ),
      );
    }
    if (results.isEmpty || isClosed || generation != guard.generation) return;
    // NOTE: `apply` re-registers the whole list through `guardInputOf`, which
    // now returns a fresh version (the local blacklist moved the facts), so a
    // refused verdict stays pending instead of being relabelled. That is the
    // mechanism the accept path relies on to re-judge the author's other rows.
    final report = guard.apply(results);
    if (report.applied > 0) {
      _refreshSuggestionCards();
      loadingState.refresh();
    }
  }

  /// Records a static snapshot for [row] from the authoritative legacy verdict.
  ///
  /// The five filters are NOT reimplemented here: the snapshot carries only the
  /// fact that the existing filter already decided, and the source operator maps
  /// it. An unmapped reason stays `unknown` — never `clear`.
  void captureGuardSnapshot(ReplyInfo row) {
    final guard = _guardState;
    if (guard == null) return;
    final input = guardInputOf(row);
    // Always overwritten for the version being captured: a comment that was
    // edited, whose like count crossed an exemption threshold, or whose filter
    // settings changed is a NEW version, and keeping the previous snapshot would
    // let a stale static verdict outlive the facts it judged.
    _guardSnapshots[input.contentId] = StaticReplySnapshot.fromLegacyReason(
      commentId: input.contentId,
      authorUid: input.authorUid,
      contentVersion: input.contentVersion,
      requestScopeId: _boundAccount?.id ?? '',
      legacyReason: ReplyGrpc.checkBlockReason(row),
    );
  }

  /// True while a card decision is in flight, so a double click cannot run
  /// two writes for one anchor.
  bool _decidingSuggestion = false;

  bool get isDecidingSuggestion => _decidingSuggestion;

  /// Accepts the suggestion rendered at [anchor]: adds the author to the LOCAL
  /// blacklist only, never the platform blacklist.
  Future<bool> acceptGuardSuggestion(SuggestionAnchor anchor) =>
      _decideGuardSuggestion(anchor, accept: true);

  /// Rejects the suggestion at [anchor]; unlike a snooze it does not come back.
  Future<bool> rejectGuardSuggestion(SuggestionAnchor anchor) =>
      _decideGuardSuggestion(anchor, accept: false);

  /// Shared accept/reject path.
  ///
  /// Validates against the ANCHOR, not a cached suggestion: the anchor is what
  /// the card was drawn for, and the machine's current state is re-read so a
  /// card another list already decided cannot be decided again here.
  Future<bool> _decideGuardSuggestion(
    SuggestionAnchor anchor, {
    required bool accept,
  }) async {
    if (_decidingSuggestion) return false;
    final lease = contentGuardLease;
    final guard = _guardState;
    if (lease == null || guard == null) return false;
    if (!Pref.contentGuardEnabled || !Pref.contentGuardSuggestionsEnabled) {
      return false;
    }
    // The account must still be the one this list was built for.
    final account = contentGuardRequestScope;
    if (account == null || account != _boundAccount) return false;
    // The anchor must still be a visible candidate for THIS list revision.
    final projection = guard.projection;
    if (projection == null) return false;
    final decisions = lease.service.suggestions.applyTo(projection.anchors);
    // Resolve the CURRENT anchor and compare every identity field, not just the
    // node id: a refresh can reuse a node id for a different author or slot, and
    // acting on the caller's stale object would then decide the wrong person.
    final live = decisions.where(
      (item) =>
          item.shouldRender &&
          item.anchor.nodeId == anchor.nodeId &&
          item.anchor.authorUid == anchor.authorUid &&
          item.anchor.contentId == anchor.contentId &&
          // Account and surface live on the RUN key, not on the anchor: an
          // anchor is one run of one author, and its scope is the run's.
          item.anchor.runKey.accountScopeId == anchor.runKey.accountScopeId &&
          item.anchor.runKey.surface == anchor.runKey.surface &&
          item.anchor.stableOrderKey == anchor.stableOrderKey,
    );
    if (live.isEmpty) return false;
    final resolved = live.first.anchor;
    final clickLease = lease;
    final clickGuard = guard;
    final clickGeneration = projection.generation;
    final clickFacts = _guardPolicyFacts;
    _decidingSuggestion = true;
    try {
      final result = accept
          ? await lease.service.suggestions.acceptAnchor(
              resolved,
              decidedBy: 'page',
            )
          : await lease.service.suggestions.rejectAnchor(
              resolved,
              decidedBy: 'page',
            );
      if (result == null) return false;
      // Re-validate AFTER the await: the account may have switched or the
      // feature been disabled while the write was in flight.
      if (!Pref.contentGuardEnabled || !Pref.contentGuardSuggestionsEnabled) {
        return false;
      }
      final nowAccount = contentGuardRequestScope;
      if (nowAccount == null || nowAccount != _boundAccount) return false;
      // The SAME lease, guard and list generation as the click: a refresh, or an
      // account A -> B -> A round trip, produces a new lease/generation, and a
      // non-null lease alone would happily accept the write into the new list.
      if (!identical(contentGuardLease, clickLease)) return false;
      if (!identical(_guardState, clickGuard)) return false;
      if (clickGuard.projection?.generation != clickGeneration) return false;
      if (!identical(_guardPolicyFacts, clickFacts)) return false;
      if (accept) {
        final mid = int.tryParse(anchor.authorUid);
        if (mid == null || mid <= 0) return false;
        // Local blacklist only. `Pref.setBlackMid` mutates `GlobalData().blackMids`
        // in place, which is a static-filter input, so this also moves every
        // row's revision for that author.
        Pref.setBlackMid(mid);
        // The local blacklist is now a filter input for this author's rows, so
        // re-derive the facts before re-judging them: their old verdicts and
        // their old static snapshots were computed for a configuration that no
        // longer exists.
        _guardPolicyFacts = replyGuardLivePolicyFacts();
        // Only an accept changes a filter input. A reject leaves the verdicts
        // exactly as they are, so re-judging would rewrite the whole list for
        // nothing.
        await _rejudgeAuthorRows(anchor.authorUid);
      }
      _refreshSuggestionCards();
      loadingState.refresh();
      return true;
    } finally {
      _decidingSuggestion = false;
    }
  }

  /// Re-judges every registered row of [authorUid] under the current policy.
  ///
  /// Accepting a suggestion adds the author to the local blacklist, which is one
  /// of the facts the static filter reads. Without this the author's other rows
  /// would keep their pre-accept verdicts: `isDecided` compares a version that
  /// no longer matches, so they would render as pending forever instead of
  /// becoming collapsed rows, and their suggestion anchors would survive a card
  /// the user already acted on.
  ///
  /// Rows of other authors are left exactly as they are — a decision about one
  /// author must not invalidate every other row in the list.
  Future<void> _rejudgeAuthorRows(String authorUid) async {
    final guard = _guardState;
    final owner = _owner;
    if (guard == null || owner == null) return;
    final rows = guard.rows;
    if (rows == null) return;
    _reindexOrder(rows);
    final generation = guard.generation;
    final results = <ReplyDecision>[];
    for (final row in rows) {
      if (isClosed || generation != guard.generation) break;
      if (row.mid.toString() != authorUid) continue;
      // Re-capture FIRST: the snapshot must describe the same revision the
      // content below is evaluated as, or the source operator answers with an
      // identity mismatch.
      captureGuardSnapshot(row);
      final input = guardInputOf(row);
      final result = await owner.evaluate(guardContentOf(row));
      if (result == null) continue;
      final liveLease = contentGuardLease;
      if (liveLease == null || !liveLease.accepts(result)) continue;
      results.add(
        ReplyDecision.fromPipelineResult(
          result,
          contentVersion: input.contentVersion,
        ),
      );
    }
    if (results.isEmpty || isClosed || generation != guard.generation) return;
    // Register the whole list again so the new revisions are what the bridge
    // compares against, then apply: only same-author rows carry new results, so
    // every other row's stored verdict survives by identity.
    guard.commit(rows);
    guard.apply(results);
  }

  /// [GuardContent] a row is evaluated as.
  GuardContent guardContentOf(ReplyInfo row) {
    final account = _boundAccount;
    if (account == null) {
      throw StateError('ContentGuard content built without a bound account');
    }
    final content = row.content;
    final input = guardInputOf(row);
    return GuardContent(
      contentId: input.contentId,
      contentType: ContentType.comment,
      surface: guardSurface,
      occurrenceKey: input.contentId,
      authorUid: input.authorUid,
      parentId: null,
      text: content.message,
      title: null,
      tags: const <String>[],
      media: <MediaRef>[
        for (final picture in content.pictures)
          if ((picture.imgSrc ?? '').isNotEmpty)
            MediaRef(
              id: picture.imgSrc!,
              type: MediaType.image,
              url: picture.imgSrc!,
              width: picture.imgWidth.toInt(),
              height: picture.imgHeight.toInt(),
            ),
        if (row.member.face.isNotEmpty)
          MediaRef(
            id: row.mid.toString(),
            type: MediaType.avatar,
            url: row.member.face,
          ),
      ],
      account: account,
      context: ContentContext(
        threadId: input.threadId,
        videoId: oid.toString(),
      ),
      contentVersion: input.contentVersion,
    );
  }

  /// The [CommentInput] a row is registered with.
  ///
  /// The payload revision is [replyGuardVersionOfReply] over this list's facts —
  /// the SAME call the row widget makes. Deriving it here independently (a local
  /// digest, a concatenation, a second settings read) is how the controller and
  /// the widget drift apart, and the symptom is silent: every row renders as
  /// pending forever because the two revisions never compare equal.
  ///
  /// `countsAsViolation` is deliberately **false**: attribution is a statement
  /// the pipeline makes, and the bridge reads it from the applied decision. The
  /// legacy reason map is not an attribution source — it holds "keyword hit" and
  /// "level too low" as readily as a genuine violation, and using it here would
  /// let a card anchor on an unjudged row.
  ///
  /// `isHiddenPlaceholder` is likewise false: the caller does not know yet
  /// whether this row will be collapsed, and the bridge derives the placeholder
  /// flag from the applied decision.
  CommentInput guardInputOf(ReplyInfo row) {
    final facts = _guardPolicyFacts ?? replyGuardLivePolicyFacts();
    _guardPolicyFacts = facts;
    return CommentInput(
      contentId: row.id.toString(),
      contentVersion: replyGuardVersionOfReply(row, facts),
      stableOrderKey: _guardOrderKeyOf(row),
      authorUid: row.mid.toString(),
    );
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    // Reconcile before the fetch, not after: the transport reads
    // [retainBlockedReplies] while the request is being built, and a settings
    // change or account switch must decide that request rather than the next.
    if (isRefresh) {
      await syncContentGuard();
    }
    await super.queryData(isRefresh);
  }

  @override
  void onClose() {
    _retireGuard();
    super.onClose();
  }
}
