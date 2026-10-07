import 'package:PiliPlus/pages/common/root_reply_controller.dart';

/// 测试用最小根评论控制器：只实现数据源 getter，不引入播放器/
/// 动态详情等页面依赖（那些需要 GetX 参数与真实 adapter）。
class TestRootReplyController extends RootReplyController {
  TestRootReplyController({required this.oid, required this.replyType});

  final int oid;
  final int replyType;

  @override
  int get rootOid => oid;

  @override
  int get rootReplyType => replyType;

  @override
  dynamic get sourceId => oid;
}
