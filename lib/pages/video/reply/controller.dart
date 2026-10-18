import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/dynamic/dyn_mention/item.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply_fold_mixin.dart';
import 'package:PiliPlus/pages/common/root_reply_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/vote/reply_vote_mixin.dart';
import 'package:PiliPlus/pages/video/reply_reply/view.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/reply_scheme_helper.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart' show BoxConstraints, WidgetsBinding;
import 'package:get/get.dart';

class VideoReplyController extends RootReplyController
    with
        ReplyVoteMixin,
        ReplyFoldMixin<MainListReply>,
        GetSingleTickerProviderStateMixin,
        ReplyLocateMixin<MainListReply>,
        MainReplyLocateMixin {
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

  MentionItem? get mentionItem {
    if (videoCtr.isUgc) {
      try {
        return videoCtr.ugcIntroCtr.videoDetail.value.owner?.mentionItem;
      } catch (_) {
        if (kDebugMode) rethrow;
      }
    }
    return null;
  }

  @override
  int get rootOid => isPugv ? videoCtr.epId! : aid;

  @override
  int get rootReplyType => videoType.replyType;

  // ===== 官方折叠评论（根评论区）：mixed_cards[27] -> FoldCard -> Reply/FoldList =====
  // 折叠卡的解码、状态与拉取流程在 ReplyFoldMixin 里（与楼中楼共用同一套），
  // 这里只提供「从哪个接口取」和「按 display_rank 插回根列表」两处差异。
  @override
  final foldCard = Rxn<FoldCard>();

  @override
  Future<LoadingState<FoldListResp>> fetchFoldList(String offset) =>
      ReplyGrpc.foldList(
        type: videoType.replyType,
        oid: rootOid,
        offset: offset,
      );

  /// Insert subsequent fold pages after the already inserted folded replies.
  @override
  bool insertFoldedReplies(FoldListResp response) {
    final existing = loadingState.value.dataOrNull;
    if (existing == null) return false;
    final lastFoldIndex = existing.lastIndexWhere(
      (reply) => foldedIds.contains(reply.id.toInt()),
    );
    final index = lastFoldIndex >= 0
        ? lastFoldIndex + 1
        : foldRank.clamp(0, existing.length).toInt();
    return absorbFoldedReplies(response, (existing, added) {
      existing.insertAll(index, added);
    });
  }

  @override
  dynamic get sourceId => IdUtils.av2bv(aid);

  @override
  void onAnimRootReply(ReplyInfo rootReply) {
    if (args[secondRpIdKey] case final int secondRpId) {
      clearTargetRootRpId();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => replyReply(rootReply, secondRpId),
      );
    } else {
      super.onAnimRootReply(rootReply);
    }
  }

  void replyReply(ReplyInfo replyItem, int? id) {
    videoCtr.childKey.currentState?.showBottomSheet(
      constraints: const BoxConstraints(),
      (context) => VideoReplyReplyPanel(
        id: id,
        oid: replyItem.oid.toInt(),
        rpid: replyItem.id.toInt(),
        firstFloor: replyItem.replyControl.isNote ? null : replyItem,
        replyType: videoCtr.videoType.replyType,
        isVideoDetail: true,
        isNested: videoCtr.scrollKey.currentContext != null,
        upMid: upMid,
      ),
    );
  }
}
