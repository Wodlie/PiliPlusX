/// Where an author-level blacklist suggestion is allowed to appear.
///
/// Spec section 7.4, verbatim: *only the first comment of a consecutive run by
/// the same author shows the suggestion; non-consecutive runs each get their
/// own.* Everything in this file exists to make that sentence implementable and
/// checkable rather than a rule of thumb.
///
/// ## Why a run, and not a comment
///
/// A suggestion card is an *author-level* artifact: there is one suggestion per
/// author, not one per violation. Rendering it next to every offending comment
/// would turn a 40-comment spam burst into 40 cards. Anchoring it to the first
/// comment of a run gives one card per contiguous stretch, which is what a reader
/// can act on, and still shows a second card when the same author reappears
/// further down the conversation.
///
/// That is the difference between the two ids this file carries:
///
/// * [SuggestionAnchor.authorSuggestionId] — **who**. Shared by every anchor of
///   one author, so accepting or rejecting any card addresses all of them.
/// * [SuggestionRunKey.runId] — **where**. One per contiguous run, so two runs of
///   one author stay two anchors instead of collapsing into one.
///
/// ## What resets a run
///
/// [SuggestionAnchoring.recompute] walks a snapshot once in stable order and
/// starts a new run whenever the [SuggestionRunKey] changes. Everything else
/// closes the current run without opening a new one:
///
/// * a node with no author uid;
/// * a node whose [GuardListNode.countsAsViolation] is false — a clean comment by
///   the same author ends the stretch, which is exactly what makes
///   `A, clean, A` two anchors instead of one.
///
/// A hidden comment keeps a collapsed placeholder [GuardListNode] so the run it
/// belongs to still has a first node: hiding a comment from the reader must never
/// move the card onto a different comment.
///
/// ## Order
///
/// Anchors come from a snapshot sorted by [GuardListNode.stableOrderKey], **never**
/// by arrival or completion order. An async status that lands late updates the
/// node in place, and the anchor stays where the list says it belongs.
///
/// ## Identity of one list slot
///
/// Two nodes describe the same slot only when account, surface, thread, depth,
/// stable order key **and** content id agree — see [GuardListNode.slotKey]. A
/// comment id alone is not an identity: the same platform comment can be listed
/// in two threads, at two depths, on two surfaces, or under two accounts, and
/// collapsing those into one entry would delete a whole run and move the card
/// wherever the input happened to be ordered.
///
/// When one slot does arrive twice (a pagination append re-sends the boundary
/// comment), exactly one copy survives: the newest [GuardListNode.listGeneration],
/// then the later [GuardListNode.rawIndex], then a fixed field order. Every step
/// reads node data, never input position, so reversing the snapshot cannot change
/// which copy is treated as current.
library;

import 'package:PiliPlus/services/content_guard/model/content_types.dart';

/// The identity of one contiguous run of comments by the same author.
///
/// Depth and thread are part of the key on purpose: a root comment and a nested
/// reply by the same author, or the same author in two threads of one page, are
/// different runs and must never share an anchor (spec section 7.4).
final class SuggestionRunKey {
  const SuggestionRunKey({
    required this.accountScopeId,
    required this.surface,
    required this.threadId,
    required this.depth,
    required this.authorUid,
  });

  final String accountScopeId;
  final ContentSurface surface;

  /// Thread the node belongs to; the empty string means "the surface's own top
  /// level" and is a real value, not a wildcard.
  final String threadId;

  /// Nesting depth. Two comments by one author at different depths are separate
  /// runs.
  final int depth;

  final String authorUid;

  /// Author-level suggestion id: **who** this card is about.
  ///
  /// Deliberately independent of thread, depth and run position, so every anchor
  /// of one author under one account shares it. Accept/reject uses this id to
  /// broadcast to all of them at once.
  String get authorSuggestionId =>
      authorSuggestionIdOf(accountScopeId, authorUid);

  /// Author-level suggestion id for [accountScopeId] + [authorUid].
  ///
  /// A static form as well, because the suggestion machine addresses an author
  /// without holding a run: the id must be derivable from who the card is about,
  /// not from where it happens to render.
  static String authorSuggestionIdOf(String accountScopeId, String authorUid) =>
      'cgbs1_${_encodeSegment(accountScopeId)}_${_encodeSegment(authorUid)}';

  /// Run-level anchor identity: **where** the card may appear.
  ///
  /// Derived from the whole key, so an anchor is stable across rebuilds of the
  /// same list — it is identified by who and where, never by a counter or a
  /// timestamp.
  String get runId =>
      '${authorSuggestionId}_${surface.wireName}_'
      '${_encodeSegment(threadId)}_$depth';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SuggestionRunKey &&
          accountScopeId == other.accountScopeId &&
          surface == other.surface &&
          threadId == other.threadId &&
          depth == other.depth &&
          authorUid == other.authorUid;

  @override
  int get hashCode =>
      Object.hash(accountScopeId, surface, threadId, depth, authorUid);

  @override
  String toString() =>
      'SuggestionRunKey(${surface.wireName}, thread: $threadId, '
      'depth: $depth, author: $authorUid)';
}

/// One node of a guard list snapshot.
///
/// This is the *input* to anchoring, not a UI model: it carries exactly what the
/// scan needs and nothing that could change between two recomputes of the same
/// list.
final class GuardListNode {
  const GuardListNode({
    required this.nodeId,
    required this.contentId,
    required this.accountScopeId,
    required this.surface,
    required this.threadId,
    required this.depth,
    required this.authorUid,
    required this.rawIndex,
    required this.stableOrderKey,
    this.countsAsViolation = false,
    this.isHiddenPlaceholder = false,
    this.listGeneration = 0,
  });

  /// Stable identity of this list node. Two rebuilds of the same comment reuse
  /// it; two comments never share it.
  final String nodeId;

  /// Platform content id (the comment id). Pagination de-duplicates on this.
  final String contentId;

  final String accountScopeId;
  final ContentSurface surface;

  /// Thread the node belongs to; `''` for the surface's own top level.
  final String threadId;

  /// Nesting depth.
  final int depth;

  /// Author as the platform reported it. Null/blank means "unknown", which ends
  /// the current run and anchors nothing.
  final String? authorUid;

  /// Position inside the page that produced the node, before sorting.
  final int rawIndex;

  /// Monotonic key the list is *displayed* in.
  ///
  /// The host sorts by whatever it already uses (pinned first, then a server
  /// rank, then a tie-break) and hands the resulting key in. Anchoring never
  /// re-derives it and never falls back to [rawIndex] on its own: sorting by
  /// arrival order is precisely the bug this field exists to prevent.
  final String stableOrderKey;

  /// Whether this node's decision allows the violation to be attributed to the
  /// author. A node that is merely filtered neither anchors a suggestion nor
  /// continues a run (spec section 7.1).
  final bool countsAsViolation;

  /// Whether this node stands in for hidden content.
  ///
  /// A hidden comment stays in the list as a collapsed placeholder so the run it
  /// belongs to keeps its first node. The flag is carried onto the anchor; it
  /// never causes a run to restart.
  final bool isHiddenPlaceholder;

  /// Generation of the list this node came from. Anchoring never reorders by it;
  /// it is exposed on the produced anchors so a caller can discard results of a
  /// superseded list.
  final int listGeneration;

  /// Trimmed author uid, or null when the platform gave none.
  String? get normalizedAuthorUid {
    final value = authorUid?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The run key this node belongs to, or null when it has no author.
  SuggestionRunKey? get runKey {
    final author = normalizedAuthorUid;
    if (author == null) {
      return null;
    }
    return SuggestionRunKey(
      accountScopeId: accountScopeId,
      surface: surface,
      threadId: threadId,
      depth: depth,
      authorUid: author,
    );
  }

  /// Whether this node can start a run.
  bool get canAnchor => runKey != null && countsAsViolation;

  /// Identity of the list slot this node occupies.
  ///
  /// Everything that makes two rows different rows is in the key: the account
  /// scope (two accounts may read the same comment id), the surface, the thread,
  /// the nesting depth, the position the list displays the row at, and the
  /// content id. [nodeId] and [listGeneration] are deliberately absent — nodeId
  /// is derived from position, and a generation is *which revision of a slot this
  /// is*, not which slot it is.
  String get slotKey =>
      '$accountScopeId\u0000${surface.wireName}\u0000$threadId\u0000'
      '$depth\u0000$stableOrderKey\u0000$contentId';

  /// Same node with its decision updated, used when an async status lands.
  GuardListNode copyWith({
    String? nodeId,
    String? contentId,
    String? accountScopeId,
    ContentSurface? surface,
    String? threadId,
    int? depth,
    String? authorUid,
    int? rawIndex,
    String? stableOrderKey,
    bool? countsAsViolation,
    bool? isHiddenPlaceholder,
    int? listGeneration,
  }) => GuardListNode(
    nodeId: nodeId ?? this.nodeId,
    contentId: contentId ?? this.contentId,
    accountScopeId: accountScopeId ?? this.accountScopeId,
    surface: surface ?? this.surface,
    threadId: threadId ?? this.threadId,
    depth: depth ?? this.depth,
    authorUid: authorUid ?? this.authorUid,
    rawIndex: rawIndex ?? this.rawIndex,
    stableOrderKey: stableOrderKey ?? this.stableOrderKey,
    countsAsViolation: countsAsViolation ?? this.countsAsViolation,
    isHiddenPlaceholder: isHiddenPlaceholder ?? this.isHiddenPlaceholder,
    listGeneration: listGeneration ?? this.listGeneration,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GuardListNode &&
          nodeId == other.nodeId &&
          contentId == other.contentId &&
          accountScopeId == other.accountScopeId &&
          surface == other.surface &&
          threadId == other.threadId &&
          depth == other.depth &&
          authorUid == other.authorUid &&
          rawIndex == other.rawIndex &&
          stableOrderKey == other.stableOrderKey &&
          countsAsViolation == other.countsAsViolation &&
          isHiddenPlaceholder == other.isHiddenPlaceholder &&
          listGeneration == other.listGeneration;

  @override
  int get hashCode => Object.hash(
    nodeId,
    contentId,
    accountScopeId,
    surface,
    threadId,
    depth,
    authorUid,
    rawIndex,
    stableOrderKey,
    countsAsViolation,
    isHiddenPlaceholder,
    listGeneration,
  );

  @override
  String toString() =>
      'GuardListNode($nodeId/$contentId, author: ${authorUid ?? 'none'}, '
      'violation: $countsAsViolation, hidden: $isHiddenPlaceholder)';
}

/// One place a suggestion may render: the first node of a run.
final class SuggestionAnchor {
  const SuggestionAnchor({
    required this.anchorId,
    required this.authorSuggestionId,
    required this.authorUid,
    required this.runKey,
    required this.nodeId,
    required this.contentId,
    required this.stableOrderKey,
    required this.rawIndex,
    required this.runStart,
    required this.runEnd,
    required this.firstNodeWasHidden,
    required this.listGeneration,
  });

  /// Anchor identity: the run id plus the node the card sits on.
  ///
  /// Both halves are needed. The run id alone would collide for one author with
  /// two runs in the same thread and depth (`A, clean, A`), and the node id
  /// alone would not say which author-level suggestion the anchor belongs to.
  /// Together they are unique inside one snapshot and stable across rebuilds of
  /// the same list, because both are derived from data rather than from a
  /// counter or a timestamp.
  final String anchorId;

  /// Author-level suggestion this anchor belongs to. Shared by every anchor of
  /// the same author, which is how accept/reject broadcasts.
  final String authorSuggestionId;

  final String authorUid;

  /// The run this anchor starts.
  final SuggestionRunKey runKey;

  /// The node the card renders at (the run's first node).
  final String nodeId;

  /// Platform content id of that node.
  final String contentId;

  final String stableOrderKey;

  /// Position of the run's first node inside the snapshot as it was handed in.
  final int rawIndex;

  /// Inclusive start of the run inside the sorted snapshot.
  final int runStart;

  /// Exclusive end of the run inside the sorted snapshot.
  final int runEnd;

  /// Whether the anchoring node is itself a collapsed placeholder for hidden
  /// content. The card still anchors there — hiding a comment must not move it.
  final bool firstNodeWasHidden;

  final int listGeneration;

  /// Number of nodes covered by this anchor's run.
  int get runLength => runEnd - runStart;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SuggestionAnchor &&
          anchorId == other.anchorId &&
          authorSuggestionId == other.authorSuggestionId &&
          authorUid == other.authorUid &&
          runKey == other.runKey &&
          nodeId == other.nodeId &&
          contentId == other.contentId &&
          stableOrderKey == other.stableOrderKey &&
          rawIndex == other.rawIndex &&
          runStart == other.runStart &&
          runEnd == other.runEnd &&
          firstNodeWasHidden == other.firstNodeWasHidden &&
          listGeneration == other.listGeneration;

  @override
  int get hashCode => Object.hash(
    anchorId,
    authorSuggestionId,
    authorUid,
    runKey,
    nodeId,
    contentId,
    stableOrderKey,
    rawIndex,
    runStart,
    runEnd,
    firstNodeWasHidden,
    listGeneration,
  );

  @override
  String toString() =>
      'SuggestionAnchor(${authorSuggestionId} at $nodeId, run: $runLength, '
      'hiddenFirst: $firstNodeWasHidden)';
}

/// The result of one [SuggestionAnchoring.recompute].
final class SuggestionAnchorIndex {
  const SuggestionAnchorIndex({
    required this.anchors,
    required this.order,
    required this.snapshotGeneration,
  });

  /// Anchor by [SuggestionAnchor.anchorId] — one entry per **run start**.
  ///
  /// Keyed per run start, not per author: one author legitimately has several
  /// runs (another thread, another depth, or two separated stretches), and
  /// collapsing them onto one entry would silently drop all but the last. Use
  /// [anchorsByAuthor] for the author-keyed view.
  final Map<String, SuggestionAnchor> anchors;

  /// Sorted node order the scan ran over. Exposed for the UI and for checks that
  /// assert "arrival order did not decide this".
  final List<String> order;

  /// Highest [GuardListNode.listGeneration] seen in the snapshot, or 0.
  final int snapshotGeneration;

  /// Every anchor, in list order.
  List<SuggestionAnchor> get inListOrder {
    final list = anchors.values.toList()
      ..sort((a, b) {
        final byKey = a.stableOrderKey.compareTo(b.stableOrderKey);
        return byKey != 0 ? byKey : a.anchorId.compareTo(b.anchorId);
      });
    return List<SuggestionAnchor>.unmodifiable(list);
  }

  /// Anchors of [authorUid], in list order. Non-consecutive runs each appear.
  List<SuggestionAnchor> anchorsForAuthor(String authorUid) => [
    for (final anchor in inListOrder)
      if (anchor.authorUid == authorUid) anchor,
  ];

  /// Anchors grouped by author, in list order — the shape a card list consumes.
  Map<String, List<SuggestionAnchor>> get anchorsByAuthor {
    final grouped = <String, List<SuggestionAnchor>>{};
    for (final anchor in inListOrder) {
      grouped
          .putIfAbsent(anchor.authorUid, () => <SuggestionAnchor>[])
          .add(
            anchor,
          );
    }
    return Map<String, List<SuggestionAnchor>>.unmodifiable(grouped);
  }

  /// Anchor rendered at [nodeId], or null.
  SuggestionAnchor? anchorAtNode(String nodeId) {
    for (final anchor in anchors.values) {
      if (anchor.nodeId == nodeId) {
        return anchor;
      }
    }
    return null;
  }

  /// Number of anchors emitted (= number of runs).
  int get length => anchors.length;

  bool get isEmpty => anchors.isEmpty;

  @override
  String toString() =>
      'SuggestionAnchorIndex(${anchors.length} anchors over '
      '${order.length} nodes)';
}

/// The anchoring algorithm.
///
/// A stateless value type: [recompute] takes a snapshot and returns an index.
/// Keeping it stateless is what makes "recompute on refresh, sort change, account
/// switch, pagination append, async status update and revoke" one code path
/// instead of six subtly different ones.
abstract final class SuggestionAnchoring {
  /// Scans [nodes] and emits one anchor per run start.
  ///
  /// Steps, in order:
  ///
  /// 1. Collapse one list slot onto one node. A slot is
  ///    [GuardListNode.slotKey] — account, surface, thread, depth, stable order
  ///    key and content id — so the same comment listed in two threads or at two
  ///    depths stays two nodes instead of one, and a pagination re-send of one
  ///    slot stays one node. [currentOf] picks the surviving copy by node data
  ///    alone, so the choice does not depend on arrival order.
  /// 2. Sort the survivors by [GuardListNode.stableOrderKey], tie-broken by
  ///    content id then node id. Sorting happens *after* de-duplication so the
  ///    run scan walks the displayed order, not the order that happened to win.
  /// 3. Walk once: a node opens a run when it has an author and counts as a
  ///    violation and its run key differs from the open one; a node with no
  ///    author, or one that does not count, closes the open run and opens nothing.
  static SuggestionAnchorIndex recompute(Iterable<GuardListNode> nodes) {
    final deduped = <String, GuardListNode>{};
    for (final node in nodes) {
      final previous = deduped[node.slotKey];
      deduped[node.slotKey] = previous == null
          ? node
          : currentOf(previous, node);
    }
    final sorted = deduped.values.toList()..sort(compareOrder);

    var maxGeneration = 0;
    for (final node in sorted) {
      if (node.listGeneration > maxGeneration) {
        maxGeneration = node.listGeneration;
      }
    }

    final anchors = <String, SuggestionAnchor>{};
    final order = <String>[];
    SuggestionRunKey? runKey;
    var runStart = -1;

    void closeRun(int endExclusive) {
      final start = runStart;
      final key = runKey;
      if (start < 0 || key == null) {
        return;
      }
      final first = sorted[start];
      final anchorId = '${key.runId}@${first.nodeId}';
      anchors[anchorId] = SuggestionAnchor(
        anchorId: anchorId,
        authorSuggestionId: key.authorSuggestionId,
        authorUid: key.authorUid,
        runKey: key,
        nodeId: first.nodeId,
        contentId: first.contentId,
        stableOrderKey: first.stableOrderKey,
        rawIndex: first.rawIndex,
        runStart: start,
        runEnd: endExclusive,
        firstNodeWasHidden: first.isHiddenPlaceholder,
        listGeneration: first.listGeneration,
      );
    }

    for (var i = 0; i < sorted.length; i++) {
      final node = sorted[i];
      order.add(node.nodeId);
      final key = node.runKey;
      if (key == null || !node.countsAsViolation) {
        // Ends the stretch: whatever comes next opens a new run, even for the
        // same author. This is the line that turns A, clean, A into two anchors.
        closeRun(i);
        runKey = null;
        runStart = -1;
        continue;
      }
      if (runKey == key) {
        continue;
      }
      closeRun(i);
      runKey = key;
      runStart = i;
    }
    closeRun(sorted.length);

    return SuggestionAnchorIndex(
      anchors: Map<String, SuggestionAnchor>.unmodifiable(anchors),
      order: List<String>.unmodifiable(order),
      snapshotGeneration: maxGeneration,
    );
  }

  /// The copy of one list slot that survives de-duplication.
  ///
  /// The newest list revision wins, because a pagination append re-sends a
  /// boundary comment precisely so its fresher status replaces the old one. Ties
  /// fall back to the later arrival index, then to the node id, so the answer is
  /// total: reversing the input cannot hand the slot to a different copy, and a
  /// generation-1 clean duplicate can never erase a generation-2 violation.
  static GuardListNode currentOf(GuardListNode a, GuardListNode b) {
    if (a.listGeneration != b.listGeneration) {
      return a.listGeneration > b.listGeneration ? a : b;
    }
    if (a.rawIndex != b.rawIndex) {
      return a.rawIndex > b.rawIndex ? a : b;
    }
    return a.nodeId.compareTo(b.nodeId) <= 0 ? a : b;
  }

  /// Displayed order of two nodes: stable order key, then content id, then node
  /// id. Total and content-derived, so the scan is reproducible from data alone.
  static int compareOrder(GuardListNode a, GuardListNode b) {
    final byKey = a.stableOrderKey.compareTo(b.stableOrderKey);
    if (byKey != 0) {
      return byKey;
    }
    final byContent = a.contentId.compareTo(b.contentId);
    return byContent != 0 ? byContent : a.nodeId.compareTo(b.nodeId);
  }

  /// Convenience alias with the vocabulary of the machine.
  static SuggestionAnchorIndex indexOf(Iterable<GuardListNode> nodes) =>
      recompute(nodes);
}

String _encodeSegment(String value) {
  if (value.isEmpty) {
    return '~';
  }
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final isSafe =
        (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        rune == 0x2D ||
        rune == 0x5F;
    if (isSafe) {
      buffer.writeCharCode(rune);
    } else {
      buffer.write('%');
      buffer.write(rune.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}
