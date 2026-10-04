import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply_fold_mixin.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/vote/reply_vote_mixin.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:get/get.dart';

class VideoReplyController extends ReplyController<MainListReply>
    with ReplyVoteMixin, ReplyFoldMixin<MainListReply> {
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

  // ===== 官方折叠评论（根评论区）：mixed_cards[27] -> FoldCard -> Reply/FoldList =====
  // 折叠卡的解码、状态与拉取流程在 ReplyFoldMixin 里（与楼中楼共用同一套），
  // 这里只提供「从哪个接口取」和「按 display_rank 插回根列表」两处差异。
  @override
  final foldCard = Rxn<FoldCard>();

  @override
  Future<LoadingState<FoldListResp>> fetchFoldList(String offset) =>
      ReplyGrpc.foldList(
        type: videoType.replyType,
        oid: isPugv ? videoCtr.epId! : aid,
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
}
