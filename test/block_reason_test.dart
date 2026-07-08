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
    tempDir = await Directory.systemTemp.createTemp('pili_block_reason_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() {
    // Reset ReplyGrpc static fields to safe defaults
    ReplyGrpc.enableFilter = false;
    ReplyGrpc.replyRegExp = RegExp('', caseSensitive: false);
    ReplyGrpc.antiGoodsReply = false;
    ReplyGrpc.minLevelForReply = 0;
    ReplyGrpc.showBlockedReplyBanner = true;
    ReplyGrpc.clearBlockedReasons();
  });

  tearDown(() async {
    // Reset at-filter settings in Hive
    await GStorage.setting.put(SettingBoxKey.enableAtFilter, false);
    await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, false);
    await GStorage.setting.put(SettingBoxKey.enableAtFilterBodyLength, false);
    await GStorage.setting.put(SettingBoxKey.atFilterBodyLengthThreshold, 10);
    await GStorage.setting.put(SettingBoxKey.enableAtFilterAtCount, false);
    await GStorage.setting.put(SettingBoxKey.atFilterAtCountThreshold, 5);
    await GStorage.setting.put(SettingBoxKey.enableAtFilterLikeExempt, false);
    await GStorage.setting.put(SettingBoxKey.atFilterLikeExemptThreshold, 50);
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ── checkBlockReason ───────────────────────────────────────────────────

  group('checkBlockReason – keyword filter', () {
    test('returns reason when message matches ban-word regex', () {
      ReplyGrpc.enableFilter = true;
      ReplyGrpc.replyRegExp = RegExp('广告', caseSensitive: false);

      final reply = _makeReply(message: '这是广告内容');

      final reason = ReplyGrpc.checkBlockReason(reply);
      expect(reason, isNotNull);
      expect(reason, contains('关键词过滤'));
      expect(reason, contains('广告'));
    });

    test('returns null when message does not match regex', () {
      ReplyGrpc.enableFilter = true;
      ReplyGrpc.replyRegExp = RegExp('广告', caseSensitive: false);

      final reply = _makeReply(message: '正常评论');

      expect(ReplyGrpc.checkBlockReason(reply), isNull);
    });
  });

  group('checkBlockReason – goods reply', () {
    test('returns goods reason when message contains goods URL prefix', () {
      ReplyGrpc.antiGoodsReply = true;

      final reply = _makeReply(
        message: '快来看看 https://gaoneng.bilibili.com/tetris/123',
      );

      expect(ReplyGrpc.checkBlockReason(reply), equals('带货评论'));
    });

    test('returns null for normal message when anti-goods enabled', () {
      ReplyGrpc.antiGoodsReply = true;

      final reply = _makeReply(message: '正常评论无链接');

      expect(ReplyGrpc.checkBlockReason(reply), isNull);
    });
  });

  group('checkBlockReason – user level', () {
    test('returns level reason when member level below threshold', () {
      ReplyGrpc.minLevelForReply = 4;

      final reply = _makeReply(message: '普通评论', level: 2);

      final reason = ReplyGrpc.checkBlockReason(reply);
      expect(reason, isNotNull);
      expect(reason, contains('用户等级不足'));
      expect(reason, contains('Lv2'));
      expect(reason, contains('Lv4'));
    });

    test('returns null when member level meets threshold', () {
      ReplyGrpc.minLevelForReply = 4;

      final reply = _makeReply(message: '普通评论', level: 4);

      expect(ReplyGrpc.checkBlockReason(reply), isNull);
    });
  });

  group('checkBlockReason – @ pure-at filter', () {
    test('returns pure-at reason when comment is only @mentions', () async {
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, true);

      final reply = _makeReply(
        message: '@用户A @用户B',
        atMap: {'用户A': 100, '用户B': 200},
      );

      expect(
        ReplyGrpc.checkBlockReason(reply),
        equals('低质量@评论：纯@无正文'),
      );
    });
  });

  group('checkBlockReason – @ body-too-short filter', () {
    test('returns body-too-short reason for short effective body', () async {
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterBodyLength, true);
      await GStorage.setting.put(SettingBoxKey.atFilterBodyLengthThreshold, 10);

      final reply = _makeReply(
        message: '@用户A 哈',
        atMap: {'用户A': 100},
      );

      final reason = ReplyGrpc.checkBlockReason(reply);
      expect(reason, isNotNull);
      expect(reason, contains('低质量@评论'));
      expect(reason, contains('正文过短'));
    });
  });

  group('checkBlockReason – @ too-many-at filter', () {
    test('returns at-count reason when @ count exceeds threshold', () async {
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterAtCount, true);
      await GStorage.setting.put(SettingBoxKey.atFilterAtCountThreshold, 3);

      final reply = _makeReply(
        message: '@A @B @C @D 一些正文内容',
        atMap: {'A': 1, 'B': 2, 'C': 3, 'D': 4},
      );

      final reason = ReplyGrpc.checkBlockReason(reply);
      expect(reason, isNotNull);
      expect(reason, contains('低质量@评论'));
      expect(reason, contains('@数量过多'));
    });
  });

  group('checkBlockReason – like exemption', () {
    test('skips at filter when like count exceeds exempt threshold', () async {
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterLikeExempt, true);
      await GStorage.setting.put(SettingBoxKey.atFilterLikeExemptThreshold, 50);

      final reply = _makeReply(
        message: '@用户A @用户B',
        atMap: {'用户A': 100, '用户B': 200},
        like: 100,
      );

      expect(ReplyGrpc.checkBlockReason(reply), isNull);
    });
  });

  group('checkBlockReason – no strategy enabled', () {
    test('returns null when all strategies are disabled', () {
      final reply = _makeReply(message: '随便什么内容');

      expect(ReplyGrpc.checkBlockReason(reply), isNull);
    });
  });

  // ── needRemoveGrpc ─────────────────────────────────────────────────────

  group('needRemoveGrpc', () {
    test('returns true when checkBlockReason returns non-null', () {
      ReplyGrpc.enableFilter = true;
      ReplyGrpc.replyRegExp = RegExp('spam');

      final reply = _makeReply(message: 'this is spam');

      expect(ReplyGrpc.needRemoveGrpc(reply), isTrue);
    });

    test('returns false when checkBlockReason returns null', () {
      final reply = _makeReply(message: '正常评论');

      expect(ReplyGrpc.needRemoveGrpc(reply), isFalse);
    });
  });

  // ── isClientBlocked / getBlockReason / clearBlockedReasons ─────────────

  group('isClientBlocked and getBlockReason', () {
    test('return false and null after clearBlockedReasons', () {
      ReplyGrpc.clearBlockedReasons();

      final reply = _makeReply(id: 100, message: '任意');

      expect(ReplyGrpc.isClientBlocked(reply), isFalse);
      expect(ReplyGrpc.getBlockReason(reply), isNull);
    });
  });

  group('clearBlockedReasons', () {
    test('clears the internal blocked-reasons map', () {
      ReplyGrpc.clearBlockedReasons();

      // After clearing, any reply should appear unblocked.
      final reply = _makeReply(id: 200, message: '任意');

      expect(ReplyGrpc.isClientBlocked(reply), isFalse);
      expect(ReplyGrpc.getBlockReason(reply), isNull);
    });
  });

  group('checkBlockReason – reply prefix stripping', () {
    test(
      'strips "回复 @user:" prefix for replies before applying @ filter',
      () async {
        await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
        await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, true);

        // Reply with "回复 @user:" prefix and substantive content after
        final reply = _makeReply(
          message: '回复 @123456 :可是这个真的纯良[笑哭][笑哭]',
          atMap: {'123456': 100},
          root: 12345, // non-zero = reply
        );

        // Should NOT be filtered – the "回复 @" is system-generated
        expect(ReplyGrpc.checkBlockReason(reply), isNull);
      },
    );

    test(
      'filters reply with user-initiated @ after stripping prefix',
      () async {
        await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
        await GStorage.setting.put(SettingBoxKey.enableAtFilterAtCount, true);
        await GStorage.setting.put(SettingBoxKey.atFilterAtCountThreshold, 3);

        // Reply with prefix + user spamming @ mentions
        final reply = _makeReply(
          message: '回复 @111: @112 @113 @114 @115 快来看',
          atMap: {'111': 1, '112': 2, '113': 3, '114': 4, '115': 5},
          root: 12345, // non-zero = reply
        );

        // Should be filtered – user is spamming @ in a reply
        final reason = ReplyGrpc.checkBlockReason(reply);
        expect(reason, isNotNull);
        expect(reason, contains('@数量过多'));
      },
    );

    test(
      'does not filter reply with only system @ and body content with emote',
      () async {
        await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
        await GStorage.setting.put(SettingBoxKey.enableAtFilterBodyLength, true);
        await GStorage.setting.put(SettingBoxKey.atFilterBodyLengthThreshold, 10);

        // Reply like "回复 @123456 :好冷[吃瓜]" – only the system @
        final reply = _makeReply(
          message: '回复 @123456 :好冷[吃瓜]',
          atMap: {'123456': 100},
          root: 12345,
        );

        // Should NOT be filtered – "回复 @" is system, no user-initiated @
        expect(ReplyGrpc.checkBlockReason(reply), isNull);
      },
    );

    test('does not strip prefix for top-level comments', () async {
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, true);

      // Top-level comment with @ mention but no substantive body
      final reply = _makeReply(
        message: '@syocn',
        atMap: {'syocn': 100},
        root: 0, // zero = top-level comment
      );

      // Should be filtered – it's a top-level comment with only @ and no body
      final reason = ReplyGrpc.checkBlockReason(reply);
      expect(reason, isNotNull);
      expect(reason, contains('纯@无正文'));
    });
  });
}

// ── helpers ────────────────────────────────────────────────────────────────

ReplyInfo _makeReply({
  int id = 1,
  String message = '',
  int level = 6,
  Map<String, int> atMap = const {},
  int like = 0,
  int root = 0,
  int parent = 0,
}) {
  final content = Content()..message = message;
  if (atMap.isNotEmpty) {
    content.atNameToMid.addEntries(
      atMap.entries.map((e) => MapEntry(e.key, Int64(e.value))),
    );
  }
  return ReplyInfo(
    id: Int64(id),
    content: content,
    member: Member()..level = Int64(level),
    like: Int64(like),
    root: Int64(root),
    parent: Int64(parent),
  );
}
