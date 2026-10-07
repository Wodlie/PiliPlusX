import 'package:PiliPlus/pages/common/root_reply_controller.dart';
import 'package:PiliPlus/pages/video/reply/vote/reply_vote_mixin.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

abstract class CommonDynController extends RootReplyController
    with ReplyVoteMixin {
  CommonDynController({super.count});

  @override
  int get rootOid => oid;

  @override
  int get rootReplyType => replyType;

  int get oid;
  int get replyType;

  late final RxBool showTitle = false.obs;

  late final horizontalPreview = Pref.horizontalPreview;
  late final List<double> ratio = Pref.dynamicDetailRatio;

  late final showDynActionBar = Pref.showDynActionBar;
}
