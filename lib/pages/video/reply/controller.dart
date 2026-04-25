import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/grpc/reply_translate.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class VideoReplyController extends ReplyController<MainListReply> {
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
    mode: mode.value,
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
        translatedReplies[rpid] =
            translatedInfo.translatedContent.message;
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
