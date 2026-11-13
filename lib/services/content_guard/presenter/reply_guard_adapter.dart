/// Page-side adapter between a platform comment and the ContentGuard bridge.
///
/// Two responsibilities, both deliberately free of Flutter and of the platform
/// reply model:
///
/// * [replyGuardContentVersionOf] derives the opaque payload revision the bridge
///   compares for equality. The reply model carries no server-side version, so
///   the revision is derived from the facts a verdict actually depends on.
/// * [replyGuardCommentInputOf] builds the [CommentInput] the controller
///   registers, so the controller and the row widget cannot disagree about
///   identity.
///
/// ## Why this file exists instead of two copies
///
/// The row widget needs the revision to decide whether a projection slot still
/// describes the reply it is about to draw, and the controller needs the same
/// revision to register that reply. Two independent derivations would drift the
/// moment one side changed, and the drift is silent: every row would simply read
/// as pending forever. One function, called from both sides, makes that
/// impossible.
///
/// The input is plain values rather than `ReplyInfo` on purpose (same reason as
/// [CommentInput]): importing the platform model here would pull the transport
/// and the Flutter graph into a file the presenter layer is supposed to be
/// executable without.
library;

import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, Url;
import 'package:PiliPlus/services/content_guard/presenter/reply_guard_bridge.dart';
import 'package:PiliPlus/services/content_guard/presenter/reply_guard_policy_digest.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:crypto/crypto.dart' show sha256;

/// Opaque revision of one comment payload.
///
/// ## Why the whole payload is hashed and never concatenated
///
/// This value is PERSISTED VERBATIM: the violation ledger writes it into every
/// record it stores (violation_record.dart, toJson -> contentVersion). A version
/// built by joining its parts with a separator would therefore put the comment
/// body and its media URLs on disk - exactly the raw content the guard exists to
/// judge without retaining.
///
/// So the payload is JSON-encoded and SHA-256'd, and only a fixed-width digest
/// leaves this function. JSON is used rather than delimiter joining because a
/// delimiter can occur inside a message: with joining, ('a|b', '') and ('a', 'b')
/// collide; with JSON encoding they cannot.
///
/// ## What participates
///
/// Every fact a decision can depend on: id, author, creation time, message, media
/// URLs, and [policyInputs]. A change to any of them makes an older verdict
/// inapplicable, which the bridge turns into ReplyPresentation.pending for that
/// row, never into a verdict relabelled with the new revision.
///
/// Counters that churn on every refresh (like count, reply count) are excluded on
/// purpose: they would discard a verdict that is still exactly right about the
/// payload it judged. [policyInputs] must not fold such counters in except where
/// a filter genuinely reads them.
///
/// The result is compared for equality and never parsed.
String replyGuardContentVersionOf({
  required String contentId,
  required String authorUid,
  required int createTimeSeconds,
  required String message,
  required List<String> pictureUrls,
  String policyInputs = '',
}) {
  final payload = jsonEncode(<String, Object?>{
    'v': 3,
    'id': contentId,
    'author': authorUid,
    'ctime': createTimeSeconds,
    'message': message,
    'pictures': pictureUrls,
    'policy': policyInputs,
  });
  return 'v3.' + sha256.convert(utf8.encode(payload)).toString();
}

/// The bridge input for one comment row.
///
/// [stableOrderKey] is the key the list is displayed in, not an arrival index: a
/// comment list re-sorts, pins and paginates while decisions are in flight, and
/// the suggestion anchor scan needs the displayed order to be stable across those
/// events.
///
/// [threadId] and [depth] scope the anchor so the same comment listed in two
/// threads stays two nodes. [isHiddenPlaceholder] lets a row the caller already
/// knows is withheld be a hidden placeholder from the first scan instead of only
/// once its verdict arrives.
CommentInput replyGuardCommentInputOf({
  required String contentId,
  required String authorUid,
  required int createTimeSeconds,
  required String message,
  required List<String> pictureUrls,
  required String stableOrderKey,
  String threadId = '',
  int depth = 0,
  bool countsAsViolation = false,
  bool isHiddenPlaceholder = false,
  String policyInputs = '',
}) => CommentInput(
  contentId: contentId,
  contentVersion: replyGuardContentVersionOf(
    contentId: contentId,
    authorUid: authorUid,
    createTimeSeconds: createTimeSeconds,
    message: message,
    pictureUrls: pictureUrls,
    policyInputs: policyInputs,
  ),
  stableOrderKey: stableOrderKey,
  authorUid: authorUid,
  threadId: threadId,
  depth: depth,
  countsAsViolation: countsAsViolation,
  isHiddenPlaceholder: isHiddenPlaceholder,
);

/// The ONE production derivation of a reply's version.
///
/// Both the controller that registers a row and the widget that renders it call
/// this with the SAME [ReplyGuardPolicyFacts] instance, so the two can never
/// disagree about which revision a verdict describes. The facts object is the
/// only place the filter configuration enters, and it carries every setting the
/// legacy filter reads — pattern and flags, goods toggle, minimum level, all
/// five @-filter sub-rules with their thresholds, and the local blacklist.
///
/// Passing a different revision on one side would make the payload digest differ
/// and every row would read as pending forever.
String replyGuardVersionOfReply(ReplyInfo reply, ReplyGuardPolicyFacts facts) {
  final content = reply.content;
  return replyGuardContentVersionOf(
    contentId: reply.id.toString(),
    authorUid: reply.mid.toString(),
    createTimeSeconds: reply.ctime.toInt(),
    message: content.message,
    pictureUrls: content.pictures
        .map((item) => item.imgSrc ?? '')
        .toList(growable: false),
    policyInputs: replyGuardPolicyDigestOf(
      level: reply.member.level.toInt(),
      // Participates ONLY because the @-filter's like exemption reads it.
      likeCount: reply.like.toInt(),
      // A reply strips its "回复 @user:" prefix before counting mentions, so the
      // same @ map means different things at root 0 and elsewhere.
      rootId: reply.root.toInt(),
      atNameCount: content.atNameToMid.length,
      atNamesDigest: replyGuardTokenDigestOf(content.atNameToMid.keys),
      emoteDigest: replyGuardTokenDigestOf(content.emotes.keys),
      topicDigest: replyGuardTokenDigestOf(content.topics.keys),
      urlDigest: replyGuardTokenDigestOf(content.urls.keys),
      hasGoods: replyGuardHasGoodsOf(reply),
      authorBlacklisted: facts.isBlacklisted(reply.mid.toInt()),
      filterRevision: facts.revision,
    ),
  );
}

/// Mirrors [Constants.goodsUrlPrefix] without importing the identity layer.
const String _goodsUrlPrefix = 'https://gaoneng.bilibili.com/tetris';

/// Goods predicate identical to the legacy static filter.
///
/// `url.hasGoods()` is only protobuf presence and disagrees with the real filter,
/// which also accepts a goods control flag, a goods item id or a prefetched goods
/// cache. A version on the weaker predicate would not move when the stronger one
/// starts matching.
bool replyGuardHasGoodsOf(ReplyInfo reply) {
  for (final url in reply.content.urls.values) {
    if (url.hasExtra() &&
        (url.extra.goodsCmControl == Int64.ONE ||
            url.extra.hasGoodsItemId() ||
            url.extra.hasGoodsPrefetchedCache())) {
      return true;
    }
  }
  // Mirrors Constants.goodsUrlPrefix. Repeated here rather than imported:
  // constants.dart pulls identity generators, which this layer must not depend on.
  return reply.content.message.contains(_goodsUrlPrefix);
}
