import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/vote/reply_vote_mixin.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class VideoReplyController extends ReplyController<MainListReply>
    with ReplyVoteMixin {
  VideoReplyController({
    required this.aid,
    required this.videoType,
    required this.heroTag,
  });
  int aid;
  final VideoType videoType;
  late final isPugv = videoType == VideoType.pugv;

  final String heroTag;
  late final videoCtr = Get.find<VideoDetailController>(tag: heroTag);

  /// Cache of translated text keyed by reply id.
  /// null = no translation yet, "" = translating, non-empty = translated text.
  final RxMap<Int64, String> translatedReplies = <Int64, String>{}.obs;

  // ===== 官方折叠评论（根评论区）：mixed_cards[27] -> FoldCard -> Reply/FoldList =====
  final Rxn<FoldCard> foldCard = Rxn<FoldCard>();
  final foldedIds = <int>{};
  bool foldedLoaded = false;
  int _foldRank = 0;

  String get foldText {
    final t = foldCard.value?.bottomText;
    return (t != null && t.isNotEmpty) ? t : '已为您过滤部分不友善评论';
  }

  bool get canShowFoldEntry =>
      !Pref.autoShowFoldedReply && foldCard.value != null && !foldedLoaded;

  @override
  bool customHandleResponse(bool isRefresh, Success<MainListReply> response) {
    final handled = super.customHandleResponse(isRefresh, response);
    for (final mc in response.response.mixedCards) {
      // FOLD = 2：仓库 MixedCard_Type 只有 UNKNOWN/QUESTION，故按数值判定；
      // fold(5) 在仓库里是未知字段，从 unknownFields 取原始字节。
      if (!mc.hasType() || mc.type.value != 2) continue;
      final raw = mc.unknownFields.getField(5);
      if (raw == null || raw.lengthDelimited.isEmpty) continue;
      try {
        final card = FoldCard.fromBuffer(raw.lengthDelimited.first);
        if (card.foldPagination.offset.isNotEmpty) {
          foldCard.value = card;
          _foldRank = mc.hasDisplayRank() ? mc.displayRank.toInt() : 0;
          if (Pref.autoShowFoldedReply && !foldedLoaded) {
            loadFoldedReplies();
          }
        }
      } catch (_) {}
      break;
    }
    return handled;
  }

  /// 取官方折叠的根评论，按卡片 display_rank 插回列表（超出长度则追加）。
  Future<void> loadFoldedReplies() async {
    final card = foldCard.value;
    if (card == null || foldedLoaded) return;
    foldedLoaded = true;
    var offset = card.foldPagination.offset;
    for (var page = 0; page < 3 && offset.isNotEmpty; page++) {
      final res = await ReplyGrpc.foldList(
        type: videoType.replyType,
        oid: isPugv ? videoCtr.epId! : aid,
        offset: offset,
      );
      if (res case Success(:final response)) {
        final existing = loadingState.value.dataOrNull;
        if (existing != null && response.replies.isNotEmpty) {
          final seen = existing.map((e) => e.id).toSet();
          final added = response.replies.where((e) => seen.add(e.id)).toList();
          if (added.isNotEmpty) {
            foldedIds.addAll(added.map((e) => e.id.toInt()));
            final idx = _foldRank < 0
                ? 0
                : (_foldRank > existing.length ? existing.length : _foldRank);
            existing.insertAll(idx, added);
            loadingState.refresh();
          }
        }
        offset = response.paginationReply.nextOffset;
      } else {
        res.toast();
        break;
      }
    }
  }
  @override
  dynamic get sourceId => IdUtils.av2bv(aid);

  @override
  List<ReplyInfo>? getDataList(MainListReply response) {
    return response.replies;
  }

  @override
  Future<LoadingState<MainListReply>> customGetData() => ReplyGrpc.mainList(
    oid: isPugv ? videoCtr.epId! : aid,
    type: videoType.replyType,
    mode: mode,
    cursorNext: cursorNext,
    offset: paginationReply?.nextOffset,
  );

  /// Request AI translation for a single reply.
  Future<void> translateReply(ReplyInfo replyItem) async {
    final rpid = replyItem.id;
    if (translatedReplies.containsKey(rpid)) {
      // Already translated — toggle off
      translatedReplies.remove(rpid);
      return;
    }

    // Mark as translating
    translatedReplies[rpid] = '';

    final res = await ReplyGrpc.translateReply(
      oid: replyItem.oid.toInt(),
      type: replyItem.type.toInt(),
      rpids: [rpid.toInt()],
    );

    if (res case Success(:final response)) {
      final translatedInfo = response.translatedReplies[rpid];
      if (translatedInfo != null &&
          translatedInfo.hasTranslatedContent() &&
          translatedInfo.translatedContent.message.isNotEmpty) {
        translatedReplies[rpid] = translatedInfo.translatedContent.message;
      } else {
        translatedReplies.remove(rpid);
        SmartDialog.showToast('未获取到翻译结果');
      }
    } else {
      translatedReplies.remove(rpid);
      res.toast();
    }
  }
}
