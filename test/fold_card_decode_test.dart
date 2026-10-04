import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart' as gen;
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:flutter_test/flutter_test.dart';

/// 官方折叠卡（`MixedCard.type == FOLD(2)`）的解码兼容层。
///
/// 生成物 `MixedCard_Type` 只声明了 `UNKNOWN(0)` / `QUESTION(1)`，线上 FOLD
/// 会被 protobuf 解码器丢进 `unknownFields`，因此**不能**用生成类的
/// `hasType()` / `type` 判定折叠卡 —— 这条用例把这个前提钉住，并验证兼容层
/// 能从生成类消息里正确还原卡片。
void main() {
  FoldCard foldCard(String offset) => FoldCard(
    bottomText: '已为您过滤部分不友善评论',
    foldPagination: FeedPagination(offset: offset),
  );

  /// 用**手写**（含 FOLD）的编码器造 wire 字节：与线上服务端下发的一致。
  List<int> encodeFold({required String offset}) => MixedCard(
    type: MixedCardType.FOLD,
    fold: foldCard(offset),
  ).writeToBuffer();

  group('生成类解码的既有前提', () {
    test('FOLD(2) 在生成类里落到 unknownFields，type 保持未设置', () {
      final raw = encodeFold(offset: 'fold-offset-1');
      final card = gen.MixedCard.fromBuffer(raw);

      // 这正是线上发生的事：枚举里没有 2，字段不会被设置。
      expect(card.hasType(), isFalse);
      expect(gen.MixedCard_Type.valueOf(2), isNull);
      // 生成物里根本没有 fold(5) 字段（oneof 只有 question），所以它一定是未知字段。
      expect(card.whichItem(), gen.MixedCard_Item.notSet);
      expect(card.unknownFields.getField(1)?.varints, isNotEmpty);
      expect(card.unknownFields.getField(5)?.lengthDelimited, isNotEmpty);

      // 用生成类的判定写折叠卡逻辑，永远匹配不到。
      expect(card.hasType() && card.type.value == 2, isFalse);
    });
  });

  group('decodeFoldCardFromMixedCard', () {
    test('从生成类消息还原折叠卡与游标', () {
      final card = gen.MixedCard.fromBuffer(
        encodeFold(offset: 'fold-offset-2'),
      );

      final fold = decodeFoldCardFromMixedCard(card);

      expect(fold, isNotNull);
      expect(fold!.bottomText, '已为您过滤部分不友善评论');
      expect(fold.hasFoldPagination(), isTrue);
      expect(fold.foldPagination.offset, 'fold-offset-2');
    });

    test('多张卡片时只看传入的那一张', () {
      final question = gen.MixedCard.fromBuffer(
        MixedCard(type: MixedCardType.QUESTION).writeToBuffer(),
      );
      final fold = gen.MixedCard.fromBuffer(
        encodeFold(offset: 'fold-offset-3'),
      );

      expect(decodeFoldCardFromMixedCard(question), isNull);
      expect(
        decodeFoldCardFromMixedCard(fold)?.foldPagination.offset,
        'fold-offset-3',
      );
    });

    test('非 FOLD / 无 fold / 非法输入都返回 null 而不是抛异常', () {
      // 枚举已声明的 QUESTION。
      expect(
        decodeFoldCardFromMixedCard(
          gen.MixedCard.fromBuffer(
            MixedCard(type: MixedCardType.QUESTION).writeToBuffer(),
          ),
        ),
        isNull,
      );
      // 未知枚举 3（HOTSPOT）——同样落在 unknownFields 里，但不该被当成折叠卡。
      expect(
        decodeFoldCardFromMixedCard(
          gen.MixedCard.fromBuffer(
            MixedCard(type: MixedCardType.HOTSPOT).writeToBuffer(),
          ),
        ),
        isNull,
      );
      // FOLD 但缺 fold 载荷。
      expect(
        decodeFoldCardFromMixedCard(
          gen.MixedCard.fromBuffer(
            MixedCard(type: MixedCardType.FOLD).writeToBuffer(),
          ),
        ),
        isNull,
      );
      // 空消息 / 非消息类型。
      expect(decodeFoldCardFromMixedCard(gen.MixedCard()), isNull);
      expect(decodeFoldCardFromMixedCard(null), isNull);
      expect(decodeFoldCardFromMixedCard('not-a-message'), isNull);
    });
  });

  group('decodeFoldCardFromUnknown（楼中楼路径）', () {
    test('从 unknownFields[11] 取出折叠卡', () {
      // DetailListReply 的 mixed_cards(11) 在仓库里仍是未知字段，手工拼一个
      // `11: <length-delimited MixedCard>` 来模拟线上的响应。
      final bytes = encodeFold(offset: 'fold-offset-4');
      final withField = gen.DetailListReply.fromBuffer([
        ..._tag(11, 2),
        ..._varint(bytes.length),
        ...bytes,
      ]);

      final fold = decodeFoldCardFromUnknown(withField);
      expect(fold, isNotNull);
      expect(fold!.foldPagination.offset, 'fold-offset-4');
    });

    test('没有该字段时返回 null', () {
      expect(decodeFoldCardFromUnknown(gen.DetailListReply()), isNull);
    });

    test('畸形、缺载荷和空游标卡不会挡住后面的有效卡', () {
      final cards = <List<int>>[
        [0x08],
        MixedCard(type: MixedCardType.FOLD).writeToBuffer(),
        encodeFold(offset: ''),
        encodeFold(offset: 'usable'),
      ];
      final message = gen.DetailListReply.fromBuffer([
        for (final card in cards) ...[
          ..._tag(11, 2),
          ..._varint(card.length),
          ...card,
        ],
      ]);
      expect(
        decodeFoldCardFromUnknown(message)?.foldPagination.offset,
        'usable',
      );
      expect(
        decodeFoldCardFromMixedCard(
          gen.MixedCard.fromBuffer(encodeFold(offset: '')),
        ),
        isNull,
      );
    });
  });
}

/// protobuf varint 编码（测试内自用）。
List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

List<int> _tag(int fieldNumber, int wireType) =>
    _varint((fieldNumber << 3) | wireType);
