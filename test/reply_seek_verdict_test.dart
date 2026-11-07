import 'package:PiliPlus/utils/reply_seek_verdict.dart';
import 'package:flutter_test/flutter_test.dart';

/// 评论自查判定表。
///
/// 背景：旧实现用「列表没扫到」推结论，正常评论会被误报。seek 化之后，
/// 判定必须先把「没定位到」和「定位到了但没有它」分开 —— 前者永远不能
/// 推出 deleted / shadowBan。
void main() {
  group('decide：不需要探活就能定论', () {
    test('游客可见 → 正常（旧实现误报场景的回归）', () {
      expect(
        ReplySeekVerdict.decide(
          tourist: ReplySeat.present,
          account: ReplySeat.present,
        ),
        ReplyCheckVerdict.normal,
      );
      // 账号视角怎么变都不影响「公开可见」这个结论。
      for (final self in ReplySeat.values) {
        expect(
          ReplySeekVerdict.decide(tourist: ReplySeat.present, account: self),
          ReplyCheckVerdict.normal,
        );
      }
    });

    test('游客可见但被标记 invisible → invisible', () {
      expect(
        ReplySeekVerdict.decide(
          tourist: ReplySeat.invisible,
          account: ReplySeat.present,
        ),
        ReplyCheckVerdict.invisible,
      );
    });

    test('游客看不到、账号能看到 → shadowBan', () {
      for (final tourist in [ReplySeat.absent, ReplySeat.seatMiss]) {
        expect(
          ReplySeekVerdict.decide(
            tourist: tourist,
            account: ReplySeat.present,
          ),
          ReplyCheckVerdict.shadowBan,
          reason: '游客 $tourist + 账号可见',
        );
      }
    });

    test('账号视角也不可见（invisible 标记）→ invisible 优先于 shadowBan', () {
      expect(
        ReplySeekVerdict.decide(
          tourist: ReplySeat.absent,
          account: ReplySeat.invisible,
        ),
        ReplyCheckVerdict.invisible,
      );
    });

    test('游客请求失败时绝不下 shadowBan', () {
      expect(
        ReplySeekVerdict.decide(
          tourist: ReplySeat.failed,
          account: ReplySeat.present,
        ),
        ReplyCheckVerdict.unknown,
      );
    });

    test('账号请求失败时也绝不下 deleted', () {
      expect(
        ReplySeekVerdict.decide(
          tourist: ReplySeat.absent,
          account: ReplySeat.failed,
        ),
        ReplyCheckVerdict.unknown,
      );
    });

    test('两个视角都缺席 → 需要探活（返回 null）', () {
      for (final tourist in [ReplySeat.absent, ReplySeat.seatMiss]) {
        for (final self in [ReplySeat.absent, ReplySeat.seatMiss]) {
          expect(
            ReplySeekVerdict.decide(tourist: tourist, account: self),
            isNull,
            reason: '游客 $tourist / 账号 $self',
          );
        }
      }
    });
  });

  group('fromProbe：两视角缺席后的终态', () {
    test('根评论不可用 → deleted', () {
      expect(
        ReplySeekVerdict.fromProbe(ReplyRootProbe.unavailable),
        ReplyCheckVerdict.deleted,
      );
    });

    test('根评论存活 → underReview', () {
      expect(
        ReplySeekVerdict.fromProbe(ReplyRootProbe.alive),
        ReplyCheckVerdict.underReview,
      );
    });

    test('探活失败 → unknown（不猜 deleted）', () {
      expect(
        ReplySeekVerdict.fromProbe(ReplyRootProbe.failed),
        ReplyCheckVerdict.unknown,
      );
    });
  });

  group('回归：seek 未命中不得变成结论', () {
    test('两侧都是 seatMiss 时需要探活，且探活失败只能是 unknown', () {
      final decided = ReplySeekVerdict.decide(
        tourist: ReplySeat.seatMiss,
        account: ReplySeat.seatMiss,
      );
      expect(decided, isNull);
      expect(
        ReplySeekVerdict.fromProbe(ReplyRootProbe.failed),
        isNot(ReplyCheckVerdict.deleted),
      );
      expect(
        ReplySeekVerdict.fromProbe(ReplyRootProbe.failed),
        isNot(ReplyCheckVerdict.shadowBan),
      );
    });
  });

  group('worthRetry：只对「可能还没落库」的结论重试', () {
    test('scanLimited / underReview 值得再试', () {
      expect(ReplySeekVerdict.worthRetry(ReplyCheckVerdict.scanLimited), isTrue);
      expect(ReplySeekVerdict.worthRetry(ReplyCheckVerdict.underReview), isTrue);
    });

    test('定论与失败都不重试', () {
      for (final verdict in [
        ReplyCheckVerdict.normal,
        ReplyCheckVerdict.invisible,
        ReplyCheckVerdict.shadowBan,
        ReplyCheckVerdict.deleted,
        ReplyCheckVerdict.unknown,
      ]) {
        expect(
          ReplySeekVerdict.worthRetry(verdict),
          isFalse,
          reason: '$verdict 不该重试',
        );
      }
    });
  });
}
