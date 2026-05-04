import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/reply_translate.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';

final class ReplyNormalizedBody {
  const ReplyNormalizedBody({
    required this.bodyWithoutMentions,
    required this.normalizedBody,
    required this.effectiveBody,
  });

  final String bodyWithoutMentions;
  final String normalizedBody;
  final String effectiveBody;

  int get effectiveLength => effectiveBody.runes.length;

  bool get hasSubstantiveBody => effectiveBody.isNotEmpty;
}

abstract final class ReplyGrpc {
  static final RegExp _voteTokenRegExp = RegExp(r'\{vote:\d+?\}');
  static final RegExp _replyWhitespaceRegExp = RegExp(r'\s+');

  static bool antiGoodsReply = Pref.antiGoodsReply;
  static int minLevelForReply = Pref.minLevelForReply;
  static RegExp replyRegExp = RegExp(
    Pref.banWordForReply,
    caseSensitive: false,
  );
  static bool enableFilter = replyRegExp.pattern.isNotEmpty;

  static bool get enableAtFilter => Pref.enableAtFilter;

  static bool get enableAtFilterPureAt => Pref.enableAtFilterPureAt;

  static bool get enableAtFilterBodyLength => Pref.enableAtFilterBodyLength;

  static int get atFilterBodyLengthThreshold =>
      Pref.atFilterBodyLengthThreshold;

  static bool get enableAtFilterAtCount => Pref.enableAtFilterAtCount;

  static int get atFilterAtCountThreshold => Pref.atFilterAtCountThreshold;

  static bool get enableAtFilterLikeExempt => Pref.enableAtFilterLikeExempt;

  static int get atFilterLikeExemptThreshold =>
      Pref.atFilterLikeExemptThreshold;

  // static Future replyInfo({required int rpid}) {
  //   return _request(
  //     GrpcUrl.replyInfo,
  //     ReplyInfoReq(rpid: Int64(rpid)),
  //     ReplyInfoReply.fromBuffer,
  //     onSuccess: (response) => response.reply,
  //   );
  // }

  // ref BiliRoamingX
  static bool needRemoveGoodGrpc(ReplyInfo reply) {
    return (reply.content.urls.isNotEmpty &&
            reply.content.urls.values.any((url) {
              return url.hasExtra() &&
                  (url.extra.goodsCmControl == Int64.ONE ||
                      url.extra.hasGoodsItemId() ||
                      url.extra.hasGoodsPrefetchedCache());
        })) ||
        reply.content.message.contains(Constants.goodsUrlPrefix);
  }

  static bool needRemoveAtGrpc(ReplyInfo reply) {
    if (!enableAtFilter) {
      return false;
    }

    final content = reply.content;
    final int structuredAtCount = content.atNameToMid.length;
    if (structuredAtCount == 0) {
      return false;
    }

    final bool hasPureAtRule = enableAtFilterPureAt;
    final bool hasBodyLengthRule = enableAtFilterBodyLength;
    final bool hasAtCountRule = enableAtFilterAtCount;
    final bool hasLikeExemptRule = enableAtFilterLikeExempt;
    final int bodyLengthThreshold = atFilterBodyLengthThreshold;
    final int atCountThreshold = atFilterAtCountThreshold;
    final int likeExemptThreshold = atFilterLikeExemptThreshold;

    if (hasLikeExemptRule &&
        likeExemptThreshold > 0 &&
        reply.like.toInt() > likeExemptThreshold) {
      return false;
    }

    ReplyNormalizedBody? normalizedBody;
    ReplyNormalizedBody getNormalizedBody() =>
        normalizedBody ??= normalizeReplyBody(reply);

    if (hasPureAtRule) {
      final ReplyNormalizedBody normalized = getNormalizedBody();
      final bool isPureAtHit =
          normalized.bodyWithoutMentions.isEmpty ||
          _extractReplyEffectiveBody(normalized.bodyWithoutMentions).isEmpty;
      if (isPureAtHit) {
        return true;
      }
    }

    if (hasAtCountRule &&
        atCountThreshold > 0 &&
        structuredAtCount >= atCountThreshold) {
      return true;
    }

    if (hasBodyLengthRule) {
      final ReplyNormalizedBody normalizedBody = getNormalizedBody();
      if (normalizedBody.effectiveLength <= bodyLengthThreshold) {
        return true;
      }
    }

    return false;
  }

  static ReplyNormalizedBody normalizeReplyBody(ReplyInfo reply) {
    final Content content = reply.content;
    final String bodyWithoutMentions = _normalizeReplyWhitespace(
      _replaceReplyTokens(
        content.message,
        content.atNameToMid.keys.map((name) => '@$name'),
      ),
    );
    final String normalizedBody = _normalizeReplyWhitespace(
      _replaceReplyTokens(
            bodyWithoutMentions,
            _buildNonSubstantiveReplyTokens(content),
          )
          .replaceAll(_voteTokenRegExp, ' ')
          .replaceAll(Constants.urlRegex, ' '),
    );
    final String effectiveBody = _extractReplyEffectiveBody(normalizedBody);
    return ReplyNormalizedBody(
      bodyWithoutMentions: bodyWithoutMentions,
      normalizedBody: normalizedBody,
      effectiveBody: effectiveBody,
    );
  }

  static Iterable<String> _buildNonSubstantiveReplyTokens(
    Content content,
  ) sync* {
    yield* content.emotes.keys;
    yield* content.topics.keys.map((topic) => '#$topic#');
    yield* content.urls.keys;
  }

  static String _replaceReplyTokens(String message, Iterable<String> tokens) {
    final List<String> sortedTokens = tokens
        .where((token) => token.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var result = message;
    for (final token in sortedTokens) {
      result = result.replaceAll(token, ' ');
    }
    return result;
  }

  static String _normalizeReplyWhitespace(String value) =>
      value.replaceAll(_replyWhitespaceRegExp, ' ').trim();

  static String _extractReplyEffectiveBody(String value) {
    final StringBuffer buffer = StringBuffer();
    for (final int rune in value.runes) {
      if (_isReplySubstantiveRune(rune)) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static bool _isReplySubstantiveRune(int rune) {
    return (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0x00C0 && rune <= 0x02AF) ||
        (rune >= 0x0370 && rune <= 0x052F) ||
        (rune >= 0x0590 && rune <= 0x08FF) ||
        (rune >= 0x0900 && rune <= 0x0E7F) ||
        (rune >= 0x1100 && rune <= 0x11FF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0x3100 && rune <= 0x318F) ||
        (rune >= 0x31A0 && rune <= 0x31BF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0xFF10 && rune <= 0xFF19) ||
        (rune >= 0xFF21 && rune <= 0xFF3A) ||
        (rune >= 0xFF41 && rune <= 0xFF5A);
  }

  static bool needRemoveGrpc(ReplyInfo reply) {
    return (enableFilter && replyRegExp.hasMatch(reply.content.message)) ||
        (antiGoodsReply && needRemoveGoodGrpc(reply)) ||
        (minLevelForReply > 0 &&
            reply.member.level.toInt() < minLevelForReply) ||
        needRemoveAtGrpc(reply);
  }

  static Future<LoadingState<MainListReply>> mainList({
    int type = 1,
    required int oid,
    required Mode mode,
    required String? offset,
    required Int64? cursorNext,
    int autoLoadDepth = 0,
  }) async {
    final res = await GrpcReq.request(
      GrpcUrl.mainList,
      MainListReq(
        oid: Int64(oid),
        type: Int64(type),
        rpid: Int64.ZERO,
        // cursor: CursorReq(
        //   mode: mode,
        //   next: cursorNext,
        // ),
        mode: mode,
        pagination: offset == null ? null : FeedPagination(offset: offset),
      ),
      MainListReply.fromBuffer,
    );
    if (res case Success(:final response)) {
      // keyword filter
      if (response.hasUpTop() && needRemoveGrpc(response.upTop)) {
        response.clearUpTop();
      }

      if (response.replies.isNotEmpty) {
        response.replies.removeWhere((item) {
          final hasMatch = needRemoveGrpc(item);
          if (!hasMatch && item.replies.isNotEmpty) {
            item.replies.removeWhere(needRemoveGrpc);
          }
          return hasMatch;
        });
      }

      // When all replies on this page were filtered out but the server
      // indicates more pages exist, automatically load the next page so
      // the user is not stuck with an empty comment section.
      // Limit consecutive auto-loads to avoid excessive API calls.
      if (response.replies.isEmpty &&
          !response.cursor.isEnd &&
          autoLoadDepth < 5 &&
          response.hasPaginationReply() &&
          response.paginationReply.nextOffset.isNotEmpty) {
        final nextRes = await mainList(
          type: type,
          oid: oid,
          mode: mode,
          offset: response.paginationReply.nextOffset,
          cursorNext: response.cursor.next,
          autoLoadDepth: autoLoadDepth + 1,
        );
        if (nextRes case Success(response: final nextResponse)) {
          // Update cursor/pagination to reflect the furthest page fetched,
          // so subsequent loads continue from the correct position.
          response.cursor = nextResponse.cursor;
          response.paginationReply = nextResponse.paginationReply;
          response.replies.addAll(nextResponse.replies);
        }
      }
    }
    return res;
  }

  static Future<LoadingState<DetailListReply>> detailList({
    int type = 1,
    required int oid,
    required int root,
    required int rpid,
    required Mode mode,
    required String? offset,
  }) async {
    final res = await GrpcReq.request(
      GrpcUrl.detailList,
      DetailListReq(
        oid: Int64(oid),
        type: Int64(type),
        root: Int64(root),
        rpid: Int64(rpid),
        scene: DetailListScene.REPLY,
        mode: mode,
        pagination: offset == null ? null : FeedPagination(offset: offset),
      ),
      DetailListReply.fromBuffer,
    );
    return res..dataOrNull?.root.replies.removeWhere(needRemoveGrpc);
  }

  static Future<LoadingState<DialogListReply>> dialogList({
    int type = 1,
    required int oid,
    required int root,
    required int dialog,
    required String? offset,
  }) async {
    final res = await GrpcReq.request(
      GrpcUrl.dialogList,
      DialogListReq(
        oid: Int64(oid),
        type: Int64(type),
        root: Int64(root),
        dialog: Int64(dialog),
        pagination: offset == null ? null : FeedPagination(offset: offset),
      ),
      DialogListReply.fromBuffer,
    );
    return res..dataOrNull?.replies.removeWhere(needRemoveGrpc);
  }

  static Future<LoadingState<SearchItemReply>> searchItem({
    required int page,
    required SearchItemType itemType,
    required int oid,
    int type = 1,
    String? keyword,
  }) {
    return GrpcReq.request(
      GrpcUrl.searchItem,
      SearchItemReq(
        cursor: SearchItemCursorReq(
          next: Int64(page),
          itemType: itemType,
        ),
        oid: Int64(oid),
        type: Int64(type),
        keyword: keyword,
      ),
      SearchItemReply.fromBuffer,
    );
  }

  static Future<LoadingState<TranslateReplyResp>> translateReply({
    required int oid,
    required int type,
    required List<int> rpids,
  }) {
    return GrpcReq.request(
      GrpcUrl.translateReply,
      TranslateReplyReq(
        oid: Int64(oid),
        type: Int64(type),
        rpids: rpids.map((id) => Int64(id)),
      ),
      TranslateReplyResp.fromBuffer,
    );
  }
}
