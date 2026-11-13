import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/fold_list_req_ext.dart' as fold_ext;
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/global_data.dart';
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
  static bool showBlockedReplyBanner = Pref.showBlockedReplyBanner;
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

  static final Map<int, String> _blockedReasons = {};

  // static Future replyInfo({required int rpid}) {
  //   return _request(
  //     GrpcUrl.replyInfo,
  //     ReplyInfoReq(rpid: Int64(rpid)),
  //     ReplyInfoReply.fromBuffer,
  //     onSuccess: (response) => response.reply,
  //   );
  // }

  static bool _hasGoods(Url url) =>
      url.hasExtra() &&
      (url.extra.goodsCmControl == Int64.ONE ||
          url.extra.hasGoodsItemId() ||
          url.extra.hasGoodsPrefetchedCache());

  // ref BiliRoamingX
  @pragma('vm:prefer-inline')
  static bool _needRemoveGoodGrpc(ReplyInfo reply) {
    return (reply.content.urls.isNotEmpty &&
            reply.content.urls.values.any(_hasGoods)) ||
        reply.content.message.contains(Constants.goodsUrlPrefix);
  }

  static bool needRemoveAtGrpc(ReplyInfo reply) {
    if (!enableAtFilter) {
      return false;
    }

    final int structuredAtCount = _getUserAtCount(reply);
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

  static final RegExp _replyPrefixRegExp = RegExp(r'^回复 @\S+?\s*:\s*');

  static String _stripReplyPrefix(String message, ReplyInfo reply) {
    // Only strip for replies (root != 0), not top-level comments
    if (reply.root.toInt() == 0) {
      return message;
    }
    return message.replaceFirst(_replyPrefixRegExp, '');
  }

  /// Returns the count of user-initiated @ mentions, excluding the system-
  /// generated reply target from the "回复 @user:" prefix for replies.
  static int _getUserAtCount(ReplyInfo reply) {
    final Map<String, Int64> atMap = reply.content.atNameToMid;
    if (atMap.isEmpty) {
      return 0;
    }
    // For replies, exclude the system @ from "回复 @user:" prefix
    if (reply.root.toInt() != 0) {
      final String stripped = _stripReplyPrefix(
        reply.content.message,
        reply,
      );
      return atMap.keys.where((name) => stripped.contains('@$name')).length;
    }
    return atMap.length;
  }

  static ReplyNormalizedBody normalizeReplyBody(ReplyInfo reply) {
    final Content content = reply.content;
    // Strip "回复 @username:" prefix for replies before processing
    final String message = _stripReplyPrefix(content.message, reply);
    final String bodyWithoutMentions = _normalizeReplyWhitespace(
      _replaceReplyTokens(
        message,
        content.atNameToMid.keys.map((name) => '@$name'),
      ),
    );
    final String normalizedBody = _normalizeReplyWhitespace(
      _replaceReplyTokens(
        bodyWithoutMentions,
        _buildNonSubstantiveReplyTokens(content),
      ).replaceAll(_voteTokenRegExp, ' ').replaceAll(Constants.urlRegex, ' '),
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
    final List<String> sortedTokens =
        tokens.where((token) => token.isNotEmpty).toSet().toList()
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

  static String? checkBlockReason(ReplyInfo reply) {
    // Strategy 1: Keyword filter
    if (enableFilter && replyRegExp.hasMatch(reply.content.message)) {
      return '关键词过滤：命中 $replyRegExp';
    }

    // Strategy 2: Goods (带货)
    if (antiGoodsReply && _needRemoveGoodGrpc(reply)) {
      return '带货评论';
    }

    // Strategy 3: Level
    final level = reply.member.level.toInt();
    if (minLevelForReply > 0 && level < minLevelForReply) {
      return '用户等级不足：Lv$level < Lv$minLevelForReply';
    }

    // Strategy 4: @ filter
    if (enableAtFilter) {
      final int structuredAtCount = _getUserAtCount(reply);
      if (structuredAtCount > 0) {
        final bool hasLikeExemptRule = enableAtFilterLikeExempt;
        final int likeExemptThreshold = atFilterLikeExemptThreshold;

        if (!(hasLikeExemptRule &&
            likeExemptThreshold > 0 &&
            reply.like.toInt() > likeExemptThreshold)) {
          final bool hasPureAtRule = enableAtFilterPureAt;
          final bool hasBodyLengthRule = enableAtFilterBodyLength;
          final bool hasAtCountRule = enableAtFilterAtCount;
          final int bodyLengthThreshold = atFilterBodyLengthThreshold;
          final int atCountThreshold = atFilterAtCountThreshold;

          if (hasPureAtRule) {
            final ReplyNormalizedBody normalized = normalizeReplyBody(reply);
            final bool isPureAtHit =
                normalized.bodyWithoutMentions.isEmpty ||
                _extractReplyEffectiveBody(
                  normalized.bodyWithoutMentions,
                ).isEmpty;
            if (isPureAtHit) {
              return '低质量@评论：纯@无正文';
            }
          }

          if (hasAtCountRule &&
              atCountThreshold > 0 &&
              structuredAtCount >= atCountThreshold) {
            return '低质量@评论：@数量过多($structuredAtCount)';
          }

          if (hasBodyLengthRule) {
            final ReplyNormalizedBody normalizedBody = normalizeReplyBody(
              reply,
            );
            if (normalizedBody.effectiveLength <= bodyLengthThreshold) {
              return '低质量@评论：正文过短';
            }
          }
        }
      }
    }
    // Strategy 5: Local blacklist
    final mid = reply.mid.toInt();
    if (mid > 0 && GlobalData().blackMids.contains(mid)) {
      return '黑名单用户';
    }

    return null;
  }

  static bool isClientBlocked(ReplyInfo reply) =>
      _blockedReasons.containsKey(reply.id.toInt());

  static String? getBlockReason(ReplyInfo reply) =>
      _blockedReasons[reply.id.toInt()];

  /// 返回被屏蔽的简洁原因（拆分出 '：' 之前的部分），用于折叠态横幅显示。
  /// 例如: '关键词过滤：命中 xxx' → '关键词过滤'
  /// 若无法获取原因，返回 '被屏蔽'。
  static String getBriefBlockReason(ReplyInfo reply) {
    final detailed = _blockedReasons[reply.id.toInt()];
    if (detailed == null) return '被屏蔽';
    final colonIndex = detailed.indexOf('：');
    if (colonIndex == -1) return detailed;
    return detailed.substring(0, colonIndex);
  }

  static void clearBlockedReasons() => _blockedReasons.clear();

  /// Mark a reply as locally blocked (e.g. after user blocks the commenter).
  /// The reply will immediately show as blocked in the UI when
  /// [Pref.showBlockedReplyBanner] is true.
  static void blockReply(ReplyInfo reply) {
    _blockedReasons[reply.id.toInt()] = '黑名单用户';
  }

  static bool needRemoveGrpc(ReplyInfo reply) =>
      checkBlockReason(reply) != null;

  static Future<LoadingState<MainListReply>> mainList({
    required int type,
    required int oid,
    Int64? rpid,

    // 定位评论：服务端把「包含该 rpid 的根评论」放到首条，并把该回复放进
    // 它的 `replies` 预览域。传入楼中楼的 rpid 即可一次点查询命中，无需翻页。
    Int64? seekRpid,
    required Mode mode,
    required String? offset,
    required Int64? cursorNext,
    int autoLoadDepth = 0,
    Account? account,
    AccountHealthIdentity? expectedIdentity,
    bool filter = true,
    bool autoPaginate = true,
    bool retainBlockedReplies = false,
  }) async {
    final res = await GrpcReq.request(
      GrpcUrl.mainList,
      MainListReq(
        oid: Int64(oid),
        type: Int64(type),
        rpid: rpid,
        seekRpid: seekRpid,
        cursor: CursorReq(
          mode: mode,
          next: cursorNext,
        ),
        // mode: mode,
        // pagination: offset == null ? null : FeedPagination(offset: offset),
      ),
      MainListReply.fromBuffer,
      account: account,
      expectedIdentity: expectedIdentity,
    );
    if (res case Success(:final response)) {
      if (filter) {
        filterMainList(response, retainBlockedReplies: retainBlockedReplies);
      }

      // When all replies on this page were filtered out but the server
      // indicates more pages exist, automatically load the next page so
      // the user is not stuck with an empty comment section.
      // Limit consecutive auto-loads to avoid excessive API calls.
      // Banner mode: 不自动翻页（列表非空，含横幅评论）
      //
      // `autoPaginate: false` 时调用方（根评论会话）自己负责追页：它需要
      // 每条链各自的游标语义（REST offset / gRPC cursor 严格分开），
      // 并且必须能在飞行中重新核对账号与健康状态。
      // 定位查询只取锚点所在的那一页：自动追页会把锚点页混进普通分页。
      if (seekRpid == null &&
          autoPaginate &&
          filter &&
          !showBlockedReplyBanner &&
          response.replies.isEmpty &&
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
          account: account,
          expectedIdentity: expectedIdentity,
          retainBlockedReplies: retainBlockedReplies,
        );
        if (nextRes case Success(response: final nextResponse)) {
          // Update cursor/pagination to reflect the furthest page fetched,
          // so subsequent loads continue from the correct position.
          response.cursor = nextResponse.cursor;
          response.paginationReply = nextResponse.paginationReply;
          response.replies.addAll(nextResponse.replies);
        } else {
          // 自动追页失败必须向上传递：吞掉鉴权错误会让整页变成「空成功」。
          return nextRes;
        }
      }
    }
    return res;
  }

  /// 根评论后处理：UP 置顶 + 主列表 + 嵌套子回复的屏蔽规则。
  ///
  /// 从 [mainList] 原样抽出，gRPC 与 REST 回退共用同一套判定（关键词、等级、
  /// 带货、@、黑名单与横幅原因表），避免两套过滤逐渐分叉。
  static void filterMainList(
    MainListReply response, {
    bool retainBlockedReplies = false,
  }) {
    if (retainBlockedReplies) {
      if (response.hasUpTop()) _markBlockedReplies([response.upTop]);
      _markBlockedReplies(response.topReplies);
      _markBlockedReplies(response.replies);
      return;
    }

    // UP 置顶评论过滤
    if (response.hasUpTop()) {
      final topReply = response.upTop;
      final reason = checkBlockReason(topReply);
      if (reason != null) {
        if (showBlockedReplyBanner) {
          _blockedReasons[topReply.id.toInt()] = reason;
          // 不 clearUpTop — 让控制器插入 replies[0]，渲染为横幅
        } else {
          response.clearUpTop(); // 移除模式：保持原行为
        }
      } else if (!showBlockedReplyBanner && topReply.replies.isNotEmpty) {
        // 上游 fix filter top reply：置顶评论保留时，其预览子回复同样过滤
        topReply.replies.removeWhere(needRemoveGrpc);
      }
    }

    // 主评论列表过滤
    if (response.replies.isNotEmpty) {
      if (showBlockedReplyBanner) {
        // 标记模式：不移除，标记被屏蔽的评论
        for (final reply in response.replies) {
          final reason = checkBlockReason(reply);
          if (reason != null) {
            _blockedReasons[reply.id.toInt()] = reason;
          }
          // 标记嵌套子评论
          for (final subReply in reply.replies) {
            final subReason = checkBlockReason(subReply);
            if (subReason != null) {
              _blockedReasons[subReply.id.toInt()] = subReason;
            }
          }
        }
      } else {
        // 移除模式：保持原行为
        response.replies.removeWhere((item) {
          final hasMatch = needRemoveGrpc(item);
          if (!hasMatch && item.replies.isNotEmpty) {
            item.replies.removeWhere(needRemoveGrpc);
          }
          return hasMatch;
        });
      }
    }
  }

  static void _markBlockedReplies(Iterable<ReplyInfo> replies) {
    for (final reply in replies) {
      final reason = checkBlockReason(reply);
      if (reason != null) _blockedReasons[reply.id.toInt()] = reason;
      _markBlockedReplies(reply.replies);
    }
  }

  static Future<LoadingState<DetailListReply>> detailList({
    required int type,
    required int oid,
    required int root,
    required int rpid,
    required Mode mode,
    required String? offset,
    Map<Int64, ReplyInfo>? removed,
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
    if (showBlockedReplyBanner) {
      final data = res.dataOrNull;
      if (data != null) {
        for (final reply in data.root.replies) {
          final reason = checkBlockReason(reply);
          if (reason != null) _blockedReasons[reply.id.toInt()] = reason;
        }
      }
    } else {
      res.dataOrNull?.root.replies.removeWhere(
        removed == null
            ? needRemoveGrpc
            : (i) {
                final flag = needRemoveGrpc(i);
                if (flag) removed[i.id] = i;
                return flag;
              },
      );
    }
    return res;
  }

  static Future<LoadingState<DialogListReply>> dialogList({
    required int type,
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
    if (showBlockedReplyBanner) {
      final data = res.dataOrNull;
      if (data != null) {
        for (final reply in data.replies) {
          final reason = checkBlockReason(reply);
          if (reason != null) _blockedReasons[reply.id.toInt()] = reason;
        }
      }
    } else {
      res.dataOrNull?.replies.removeWhere(needRemoveGrpc);
    }
    return res;
  }

  /// 官方折叠的二级评论（Reply/FoldList）。
  /// 游标来自 DetailListReply.mixed_cards[11].fold.fold_pagination.offset
  /// （见 fold_list_req_ext.dart 的 decodeFoldCardFromUnknown）。
  static Future<LoadingState<FoldListResp>> foldList({
    required int type,
    required int oid,
    String? offset,
    String extra = '',
    FeedPagination? pagination,
    bool retainBlockedReplies = false,
  }) async {
    assert(offset != null || pagination != null);
    FeedPagination? page = pagination;
    if (page == null && offset != null) {
      page = FeedPagination(offset: offset);
    }
    final res = await GrpcReq.request(
      GrpcUrl.foldList,
      FoldListReq(
        oid: Int64(oid),
        type: Int64(type),
        extra: extra,
        pagination: page,
      ),
      FoldListResp.fromBuffer,
    );
    if (retainBlockedReplies) {
      final data = res.dataOrNull;
      if (data != null) _markBlockedReplies(data.replies);
    } else if (showBlockedReplyBanner) {
      final data = res.dataOrNull;
      if (data != null) {
        for (final reply in data.replies) {
          final reason = checkBlockReason(reply);
          if (reason != null) _blockedReasons[reply.id.toInt()] = reason;
        }
      }
    } else {
      res.dataOrNull?.replies.removeWhere(needRemoveGrpc);
    }
    return res;
  }

  /// fork 的 ReplyFoldMixin 用的是 fold_list_req_ext.dart 里手写的 FoldListResp。
  /// 上游 2.2.0 已生成同构消息，故复用上面的取数与屏蔽逻辑，只把返回消息按线
  /// 格式换成 fork 类型，避免两套 FoldList 取数实现逐渐分叉。
  static Future<LoadingState<fold_ext.FoldListResp>> foldListForMixin({
    required int type,
    required int oid,
    required String offset,
    String extra = '',
    bool retainBlockedReplies = false,
  }) async {
    final res = await foldList(
      type: type,
      oid: oid,
      offset: offset,
      extra: extra,
      retainBlockedReplies: retainBlockedReplies,
    );
    return switch (res) {
      Success(:final response) => Success(
        fold_ext.FoldListResp.fromBuffer(response.writeToBuffer()),
      ),
      Error(:final errMsg, :final code) => Error(errMsg, code: code),
      _ => LoadingState.loading(),
    };
  }

  static Future<LoadingState<SearchItemReply>> searchItem({
    required int page,
    required SearchItemType itemType,
    required int oid,
    required int type,
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
