/// The live filter configuration, read from the settings the legacy filter uses.
///
/// Lives in the page layer, not in the presenter layer, because reading it needs
/// `Pref`, `GlobalData` and `ReplyGrpc` — every one of which reaches
/// `package:get` and therefore `dart:ui`. The presenter barrel must stay
/// executable by a plain-Dart probe, so the *value object*
/// ([ReplyGuardPolicyFacts]) and its digest live there and only this reader
/// lives here.
///
/// ## One instance per list build
///
/// A caller builds the facts **once** and hands the same object to the
/// controller (which registers and evaluates rows) and to the row widgets (which
/// build the presentation). Both derive the payload revision from
/// [replyGuardVersionOfReply] over that one instance, so they cannot disagree:
/// two independent reads could straddle a settings change and leave every row
/// rendered as pending.
library;

import 'package:PiliPlus/grpc/reply.dart' show ReplyGrpc;
import 'package:PiliPlus/services/content_guard/presenter/reply_guard_policy_digest.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Snapshot of every setting the static reply filter reads.
///
/// Mirrors `ReplyGrpc.checkBlockReason` exactly, one field per fact it can act
/// on. Anything added to that function must be added here too: a fact the filter
/// reads and this snapshot omits is a verdict that silently outlives the setting
/// it was computed under.
ReplyGuardPolicyFacts replyGuardLivePolicyFacts() => ReplyGuardPolicyFacts(
  // Pattern AND flags, because `enableFilter` is `pattern.isNotEmpty` but the
  // compiled regexp also carries `caseSensitive`.
  keywordPattern: ReplyGrpc.replyRegExp.pattern,
  keywordCaseSensitive: ReplyGrpc.replyRegExp.isCaseSensitive,
  goodsFilter: ReplyGrpc.antiGoodsReply,
  minLevel: ReplyGrpc.minLevelForReply,
  atFilter: ReplyGrpc.enableAtFilter,
  atPureAt: ReplyGrpc.enableAtFilterPureAt,
  atBodyLength: ReplyGrpc.enableAtFilterBodyLength,
  atBodyLengthThreshold: ReplyGrpc.atFilterBodyLengthThreshold,
  atCount: ReplyGrpc.enableAtFilterAtCount,
  atCountThreshold: ReplyGrpc.atFilterAtCountThreshold,
  atLikeExempt: ReplyGrpc.enableAtFilterLikeExempt,
  atLikeExemptThreshold: ReplyGrpc.atFilterLikeExemptThreshold,
  // The local blacklist is a filter input: membership decides whether a row is
  // blocked, so it belongs in the revision. Read from the LIVE set, which
  // `Pref.setBlackMid` mutates in place — accepting a suggestion therefore
  // moves this revision and re-judges that author's rows on the next commit.
  blacklistMids: GlobalData().blackMids,
);
