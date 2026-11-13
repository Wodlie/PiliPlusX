import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply;
import 'package:PiliPlus/pages/common/reply/fold/reply_fold_mixin.dart';
import 'package:PiliPlus/pages/common/reply/reply_guard_mixin.dart';
import 'package:PiliPlus/pages/common/root_reply_controller.dart';
import 'package:get/get.dart';

class MainReplyController extends RootReplyController
    with
        BaseReplyFoldMixin<MainListReply>,
        ReplyFoldMixin,
        // Same ordering rule as VideoReplyController: the guard wraps folding.
        ReplyGuardListMixin<MainListReply> {
  late final int oid;
  @override
  late final int replyType;

  @override
  int get rootOid => oid;

  @override
  int get rootReplyType => replyType;

  @override
  int get sourceId => oid;

  @override
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    oid = args['oid'];
    replyType = args['replyType'];

    queryData();
  }
}
