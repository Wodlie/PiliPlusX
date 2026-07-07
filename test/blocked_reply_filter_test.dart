import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the dual-mode reply filtering logic that lives inside
/// [ReplyGrpc.mainList]. Since mainList makes gRPC calls, we replicate
/// the post-response filtering logic here and verify outcomes directly.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir =
        await Directory.systemTemp.createTemp('pili_block_filter_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() {
    // Enable a simple keyword filter so we have deterministic block reasons.
    ReplyGrpc.enableFilter = true;
    ReplyGrpc.replyRegExp = RegExp('广告', caseSensitive: false);
    ReplyGrpc.antiGoodsReply = false;
    ReplyGrpc.minLevelForReply = 0;
    ReplyGrpc.clearBlockedReasons();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ── helpers ────────────────────────────────────────────────────────────

  ReplyInfo _blocked({int id = 100}) => ReplyInfo(
        id: Int64(id),
        content: Content()..message = '广告内容',
        member: Member()..level = Int64(6),
      );

  ReplyInfo _normal({int id = 200, String message = '正常评论'}) => ReplyInfo(
        id: Int64(id),
        content: Content()..message = message,
        member: Member()..level = Int64(6),
      );

  ReplyInfo _blockedUpTop({int id = 300}) => ReplyInfo(
        id: Int64(id),
        content: Content()..message = '广告置顶',
        member: Member()..level = Int64(6),
      );

  /// Replicates the banner-mode filtering path in ReplyGrpc.mainList.
  /// Returns the set of reply ids that were marked as blocked.
  Set<int> _applyBannerMode(MainListReply response) {
    final marked = <int>{};

    if (response.hasUpTop()) {
      final reason = ReplyGrpc.checkBlockReason(response.upTop);
      if (reason != null) {
        marked.add(response.upTop.id.toInt());
      }
      // Banner mode: upTop is NOT cleared – stays for rendering as banner.
    }

    for (final reply in response.replies) {
      final reason = ReplyGrpc.checkBlockReason(reply);
      if (reason != null) {
        marked.add(reply.id.toInt());
      }
      for (final subReply in reply.replies) {
        final subReason = ReplyGrpc.checkBlockReason(subReply);
        if (subReason != null) {
          marked.add(subReply.id.toInt());
        }
      }
    }
    return marked;
  }

  /// Replicates the remove-mode filtering path in ReplyGrpc.mainList.
  void _applyRemoveMode(MainListReply response) {
    if (response.hasUpTop()) {
      final reason = ReplyGrpc.checkBlockReason(response.upTop);
      if (reason != null) {
        response.clearUpTop();
      }
    }

    if (response.replies.isNotEmpty) {
      response.replies.removeWhere((item) {
        final hasMatch = ReplyGrpc.needRemoveGrpc(item);
        if (!hasMatch && item.replies.isNotEmpty) {
          item.replies.removeWhere(ReplyGrpc.needRemoveGrpc);
        }
        return hasMatch;
      });
    }
  }

  // ── banner mode ────────────────────────────────────────────────────────

  group('banner mode (showBlockedReplyBanner = true)', () {
    setUp(() => ReplyGrpc.showBlockedReplyBanner = true);

    test('blocked replies are kept in the list (not removed)', () {
      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [_blocked(), _normal()],
      );

      final marked = _applyBannerMode(response);

      // Replies stay in list.
      expect(response.replies, hasLength(2));
      // Blocked reply is marked.
      expect(marked, contains(100));
      // Normal reply is not marked.
      expect(marked, isNot(contains(200)));
    });

    test('upTop is preserved when blocked', () {
      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [_normal()],
        upTop: _blockedUpTop(),
      );

      final marked = _applyBannerMode(response);

      expect(response.hasUpTop(), isTrue,
          reason: 'Banner mode keeps upTop for rendering as banner');
      expect(marked, contains(300));
    });

    test('sub-replies are marked, not removed', () {
      final parent = _normal(id: 400)
        ..replies.addAll([_blocked(id: 401), _normal(id: 402)]);

      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [parent],
      );

      final marked = _applyBannerMode(response);

      // Parent stays; sub-replies stay.
      expect(response.replies.first.replies, hasLength(2));
      expect(marked, contains(401));
      expect(marked, isNot(contains(402)));
    });

    test('auto-page condition is NOT met (list is never empty)', () {
      // Even when ALL replies are blocked, banner mode keeps them.
      final response = MainListReply(
        cursor: CursorReply(isEnd: false),
        replies: [_blocked(id: 500), _blocked(id: 501)],
        paginationReply: FeedPaginationReply(nextOffset: 'next'),
      );

      _applyBannerMode(response);

      // The auto-page condition in mainList:
      //   !showBlockedReplyBanner && response.replies.isEmpty && …
      // !showBlockedReplyBanner is false → condition never met.
      final wouldAutoPage = !ReplyGrpc.showBlockedReplyBanner &&
          response.replies.isEmpty;
      expect(wouldAutoPage, isFalse);
    });
  });

  // ── remove mode ────────────────────────────────────────────────────────

  group('remove mode (showBlockedReplyBanner = false)', () {
    setUp(() => ReplyGrpc.showBlockedReplyBanner = false);

    test('blocked replies are removed from the list', () {
      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [_blocked(), _normal()],
      );

      _applyRemoveMode(response);

      expect(response.replies, hasLength(1));
      expect(response.replies.first.id.toInt(), equals(200));
    });

    test('upTop is cleared when blocked', () {
      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [_normal()],
        upTop: _blockedUpTop(),
      );

      _applyRemoveMode(response);

      expect(response.hasUpTop(), isFalse,
          reason: 'Remove mode clears blocked upTop');
    });

    test('blocked sub-replies are removed, parent stays', () {
      final parent = _normal(id: 600)
        ..replies.addAll([_blocked(id: 601), _normal(id: 602)]);

      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [parent],
      );

      _applyRemoveMode(response);

      // Parent stays.
      expect(response.replies, hasLength(1));
      // Blocked sub-reply removed; normal one stays.
      expect(response.replies.first.replies, hasLength(1));
      expect(response.replies.first.replies.first.id.toInt(), equals(602));
    });

    test('auto-page condition is met when all replies are filtered out', () {
      final response = MainListReply(
        cursor: CursorReply(isEnd: false),
        replies: [_blocked(id: 700), _blocked(id: 701)],
        paginationReply: FeedPaginationReply(nextOffset: 'next'),
      );

      _applyRemoveMode(response);

      // All replies removed → list empty.
      expect(response.replies, isEmpty);

      // Auto-page condition:
      //   !showBlockedReplyBanner && response.replies.isEmpty &&
      //   !response.cursor.isEnd && autoLoadDepth < 5 &&
      //   response.hasPaginationReply() &&
      //   response.paginationReply.nextOffset.isNotEmpty
      final wouldAutoPage = !ReplyGrpc.showBlockedReplyBanner &&
          response.replies.isEmpty &&
          !response.cursor.isEnd &&
          response.hasPaginationReply() &&
          response.paginationReply.nextOffset.isNotEmpty;
      expect(wouldAutoPage, isTrue,
          reason: 'Remove mode triggers auto-page when all replies filtered');
    });

    test('auto-page condition NOT met when cursor is end', () {
      final response = MainListReply(
        cursor: CursorReply(isEnd: true),
        replies: [_blocked(id: 800)],
        paginationReply: FeedPaginationReply(nextOffset: 'next'),
      );

      _applyRemoveMode(response);

      expect(response.replies, isEmpty);

      final wouldAutoPage = !ReplyGrpc.showBlockedReplyBanner &&
          response.replies.isEmpty &&
          !response.cursor.isEnd;
      expect(wouldAutoPage, isFalse,
          reason: 'isEnd = true prevents auto-page');
    });
  });
}
