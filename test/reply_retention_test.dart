import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('reply_retention_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    await GStorage.setting.put(SettingBoxKey.enableAtFilter, false);
  });

  setUp(() {
    ReplyGrpc.enableFilter = true;
    ReplyGrpc.replyRegExp = RegExp('blocked');
    ReplyGrpc.antiGoodsReply = false;
    ReplyGrpc.minLevelForReply = 0;
    ReplyGrpc.showBlockedReplyBanner = false;
    ReplyGrpc.clearBlockedReasons();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  ReplyInfo reply(int id, {bool blocked = false, List<ReplyInfo>? children}) =>
      ReplyInfo(
        id: Int64(id),
        content: Content(message: blocked ? 'blocked' : 'ordinary'),
        replies: children,
      );

  MainListReply response() => MainListReply(
    upTop: reply(1, blocked: true, children: [reply(2, blocked: true)]),
    topReplies: [
      reply(3, blocked: true, children: [reply(4, blocked: true)]),
    ],
    replies: [
      reply(5, blocked: true, children: [reply(6, blocked: true)]),
      reply(
        7,
        children: [
          reply(8, blocked: true, children: [reply(9, blocked: true)]),
        ],
      ),
    ],
  );

  test(
    'retention preserves all slots and recursively records real reasons',
    () {
      final data = response();
      final before = data.writeToBuffer();

      ReplyGrpc.filterMainList(data, retainBlockedReplies: true);

      expect(data.writeToBuffer(), orderedEquals(before));
      for (final id in [1, 2, 3, 4, 5, 6, 8, 9]) {
        final item = reply(id);
        expect(ReplyGrpc.isClientBlocked(item), isTrue);
        expect(ReplyGrpc.getBlockReason(item), contains('关键词过滤'));
      }
      expect(ReplyGrpc.isClientBlocked(reply(7)), isFalse);
      expect(ReplyGrpc.showBlockedReplyBanner, isFalse);
    },
  );

  test('default and explicit false retain legacy removal behavior', () {
    final implicit = response();
    final explicit = response();

    ReplyGrpc.filterMainList(implicit);
    ReplyGrpc.filterMainList(explicit, retainBlockedReplies: false);

    expect(implicit.writeToBuffer(), orderedEquals(explicit.writeToBuffer()));
    expect(implicit.hasUpTop(), isFalse);
    expect(implicit.topReplies, isEmpty);
    expect(implicit.replies.map((item) => item.id.toInt()), [7]);
    expect(implicit.replies.single.replies, isEmpty);
  });

  test('banner mode retains its existing behavior by default', () {
    ReplyGrpc.showBlockedReplyBanner = true;
    final data = MainListReply(
      upTop: reply(10, blocked: true),
      replies: [
        reply(11, children: [reply(12, blocked: true)]),
      ],
    );
    final before = data.writeToBuffer();

    ReplyGrpc.filterMainList(data);

    expect(data.writeToBuffer(), orderedEquals(before));
    expect(ReplyGrpc.getBlockReason(data.upTop), contains('关键词过滤'));
    expect(
      ReplyGrpc.getBlockReason(data.replies.single.replies.single),
      contains('关键词过滤'),
    );
    expect(ReplyGrpc.isClientBlocked(data.replies.single), isFalse);
  });

  test('retention does not persist into another filter invocation', () {
    ReplyGrpc.filterMainList(response(), retainBlockedReplies: true);
    final disabled = response();

    ReplyGrpc.filterMainList(disabled);

    expect(disabled.hasUpTop(), isFalse);
    expect(disabled.replies.map((item) => item.id.toInt()), [7]);
    expect(ReplyGrpc.showBlockedReplyBanner, isFalse);
  });
}
