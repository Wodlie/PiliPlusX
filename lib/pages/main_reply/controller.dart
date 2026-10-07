import 'package:PiliPlus/pages/common/root_reply_controller.dart';
import 'package:get/get.dart';

class MainReplyController extends RootReplyController {
  late final int oid;
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
