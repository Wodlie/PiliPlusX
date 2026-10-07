import 'package:PiliPlus/http/reply_rest_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// REST 根评论 JSON → 现有 protobuf UI 类型。
///
/// 目的：REST 回退必须把 UI 真正消费的字段带过去（表情、@、链接 goods extra、
/// 图片、卡片标签、置顶），否则回退路径会静默丢功能。生成类只读，这里只做
/// 纯函数断言，不发请求。
void main() {
  Map<String, dynamic> replyJson({
    int rpid = 1001,
    List<int>? childIds,
    Map<String, dynamic>? content,
    Map<String, dynamic>? member,
    Map<String, dynamic>? control,
    Object? action,
  }) => {
    'rpid': rpid,
    'oid': 555,
    'type': 1,
    'mid': 42,
    'like': 7,
    'ctime': 1700000000,
    'count': 3,
    'action': action,
    'content': content ?? {'message': 'hello'},
    'member':
        member ??
        {
          'mid': '42',
          'uname': 'tester',
          'avatar': 'https://example.invalid/face.png',
          'level_info': {'current_level': 5},
          'vip': {'vipStatus': 1, 'vipType': 2},
        },
    if (control != null) 'reply_control': control,
    if (childIds != null)
      'replies': [
        for (final id in childIds)
          {
            'rpid': id,
            'oid': 555,
            'type': 1,
            'content': {'message': 'child $id'},
            'member': {'mid': '7', 'uname': 'child', 'avatar': 'x'},
          },
      ],
  };

  test('身份字段：rpid→id、字符串 mid 归一、子回复递归', () {
    final reply = ReplyRestAdapter.reply(
      replyJson(childIds: [2001, 2002]),
      oid: 555,
      type: 1,
    );
    expect(reply.id.toInt(), 1001);
    expect(reply.oid.toInt(), 555);
    expect(reply.type.toInt(), 1);
    expect(reply.mid.toInt(), 42);
    expect(reply.like.toInt(), 7);
    expect(reply.ctime.toInt(), 1700000000);
    expect(reply.count.toInt(), 3);
    expect(reply.member.mid.toInt(), 42);
    expect(reply.member.name, 'tester');
    expect(reply.member.face, 'https://example.invalid/face.png');
    expect(reply.member.level.toInt(), 5);
    expect(reply.member.vipStatus.toInt(), 1);
    expect(reply.member.vipType.toInt(), 2);
    expect(reply.replies.map((r) => r.id.toInt()), [2001, 2002]);
    expect(reply.hasReplyControl(), isTrue);
  });

  test('缺少 rpid 视为转换错误，不悄悄变成 0', () {
    expect(
      () => ReplyRestAdapter.reply(
        {
          'content': {'message': 'x'},
        },
        oid: 1,
        type: 1,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('表情：size 取 meta.size，缺尺寸退化为 1（不能渲染成 0 尺寸）', () {
    final reply = ReplyRestAdapter.reply(
      replyJson(
        content: {
          'message': 'hi [doge]',
          'emote': {
            '[doge]': {
              'url': 'https://example.invalid/doge.png',
              'meta': {'size': 20},
              'jump_url': 'https://example.invalid/doge',
            },
            '[noSize]': {'url': 'https://example.invalid/n.png'},
          },
        },
      ),
      oid: 555,
      type: 1,
    );
    expect(reply.content.emotes.keys, containsAll(['[doge]', '[noSize]']));
    expect(reply.content.emotes['[doge]']!.size.toInt(), 20);
    expect(
      reply.content.emotes['[doge]']!.jumpUrl,
      'https://example.invalid/doge',
    );
    expect(reply.content.emotes['[noSize]']!.size.toInt(), 1);
  });

  test('@ 成员：members 列表 → atNameToMid，名字去掉 @ 前缀', () {
    final reply = ReplyRestAdapter.reply(
      replyJson(
        content: {
          'message': '@alice @bob 你好',
          'members': [
            {'uname': 'alice', 'mid': '11'},
            {'uname': '@bob', 'mid': 22},
            {'uname': 'bad', 'mid': 0},
          ],
        },
      ),
      oid: 555,
      type: 1,
    );
    expect(reply.content.atNameToMid.keys, containsAll(['alice', 'bob']));
    expect(reply.content.atNameToMid['alice']!.toInt(), 11);
    expect(reply.content.atNameToMid['bob']!.toInt(), 22);
    expect(reply.content.atNameToMid.containsKey('bad'), isFalse);
  });

  test('链接：jump_url → urls，并保留 goods / 词搜 extra（带货过滤依赖它）', () {
    final reply = ReplyRestAdapter.reply(
      replyJson(
        content: {
          'message': '商品 https://example.invalid/g',
          'jump_url': {
            'https://example.invalid/g': {
              'title': '商品',
              'pc_url': 'https://example.invalid/pc',
              'extra': {
                'goods_item_id': 99,
                'goods_cm_control': 1,
                'is_word_search': true,
              },
            },
            'https://example.invalid/no-title': const <String, dynamic>{},
          },
        },
      ),
      oid: 555,
      type: 1,
    );
    final goods = reply.content.urls['https://example.invalid/g']!;
    expect(goods.title, '商品');
    expect(goods.pcUrl, 'https://example.invalid/pc');
    expect(goods.extra.hasGoodsItemId(), isTrue);
    expect(goods.extra.goodsItemId.toInt(), 99);
    expect(goods.extra.goodsCmControl.toInt(), 1);
    expect(goods.extra.isWordSearch, isTrue);
    // 没有标题时用 token 兜底，否则链接在正文里不可见。
    expect(
      reply.content.urls['https://example.invalid/no-title']!.title,
      'https://example.invalid/no-title',
    );
  });

  test('图片与卡片标签、投票选项', () {
    final reply = ReplyRestAdapter.reply(
      replyJson(
        content: {
          'message': '带图',
          'picture_scale': 1.5,
          'pictures': [
            {
              'img_src': 'https://example.invalid/1.jpg',
              'img_width': 100,
              'img_height': '200',
              'img_size': 12.5,
            },
          ],
        },
        control: {
          'time_desc': '1天前',
          'card_labels': [
            {'text_content': '热评', 'text_color_day': '#fff'},
          ],
          'vote_option': {'label_kind': 1, 'desc': 'A', 'idx': 2, 'vote_id': 9},
        },
      ),
      oid: 555,
      type: 1,
    );
    expect(reply.content.pictureScale, 1.5);
    expect(
      reply.content.pictures.single.imgSrc,
      'https://example.invalid/1.jpg',
    );
    expect(reply.content.pictures.single.imgWidth, 100);
    expect(reply.content.pictures.single.imgHeight, 200);
    expect(reply.content.pictures.single.imgSize, 12.5);
    expect(reply.replyControl.cardLabels.single.textContent, '热评');
    expect(reply.replyControl.voteOption.desc, 'A');
    expect(reply.replyControl.voteOption.idx.toInt(), 2);
    expect(reply.replyControl.timeDesc, '1天前');
  });

  test('缺少 official_verify 时显式 -1，避免默认 0 被当成个人认证', () {
    final reply = ReplyRestAdapter.reply(
      replyJson(
        member: {
          'mid': '42',
          'uname': 'tester',
          'avatar': 'x',
          'level_info': {'current_level': 3},
        },
      ),
      oid: 555,
      type: 1,
    );
    expect(reply.member.officialVerifyType.toInt(), -1);
  });

  test('主响应：offset 决定是否结束，count 缺失记 -1（不提前截断）', () {
    final page = ReplyRestAdapter.mainList(
      {
        'cursor': {
          'pagination_reply': {'next_offset': 'next-1'},
          'mode_text': '热门',
          'support_mode': [2, 3],
        },
        'control': {'input_disable': false, 'root_input_text': '发条友善的评论'},
        'upper': {'mid': 777},
        'replies': [replyJson(rpid: 1)],
      },
      oid: 555,
      type: 1,
    );
    expect(page.cursor.isEnd, isFalse);
    expect(page.paginationReply.nextOffset, 'next-1');
    expect(page.subjectControl.count.toInt(), -1);
    expect(page.subjectControl.upMid.toInt(), 777);
    expect(page.subjectControl.title, '热门');
    expect(page.subjectControl.switcherType.toInt(), 1);
    expect(page.replies.single.id.toInt(), 1);

    final last = ReplyRestAdapter.mainList(
      {
        'cursor': {
          'pagination_reply': {'next_offset': ''},
          'all_count': 12,
        },
        'replies': [replyJson(rpid: 2)],
      },
      oid: 555,
      type: 1,
    );
    expect(last.cursor.isEnd, isTrue);
    expect(last.paginationReply.nextOffset, isEmpty);
    expect(last.subjectControl.count.toInt(), 12);
  });

  test('置顶：UP 置顶单独取用并从列表去重，其它置顶只出现一次', () {
    final page = ReplyRestAdapter.mainList(
      {
        'cursor': {
          'pagination_reply': {'next_offset': ''},
        },
        'top': {
          'upper': replyJson(rpid: 9001),
          'admin': replyJson(rpid: 9002),
        },
        'replies': [replyJson(rpid: 9001), replyJson(rpid: 9003)],
      },
      oid: 555,
      type: 1,
    );
    expect(page.hasUpTop(), isTrue);
    expect(page.upTop.id.toInt(), 9001);
    // 9001 不应在普通列表里重复出现；9002 作为置顶出现在列表一次。
    expect(
      page.replies.map((r) => r.id.toInt()),
      [9003, 9002],
    );
    final adminTop = page.replies.firstWhere((r) => r.id.toInt() == 9002);
    expect(adminTop.replyControl.isAdminTop, isTrue);
    // `is_up_top` 必须真的置位：ReplyController.customHandleResponse 用它决定
    // 是否插入头像横幅，onToggleTop 用它决定「置顶 / 取消置顶」的意图。
    expect(
      page.upTop.replyControl.isUpTop,
      isTrue,
      reason: 'REST 回退路径不置位会让取消置顶的意图反掉',
    );
    expect(adminTop.replyControl.isUpTop, isFalse);
  });

  test('不修改传入的 JSON（适配必须是纯转换）', () {
    final raw = replyJson(
      content: {
        'message': 'x',
        'members': [
          {'uname': 'a', 'mid': '1'},
        ],
      },
    );
    final before = raw.toString();
    ReplyRestAdapter.reply(raw, oid: 555, type: 1);
    expect(raw.toString(), before);
  });
}
