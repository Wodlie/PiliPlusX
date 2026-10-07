import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:fixnum/fixnum.dart';

/// REST 根评论（`/x/v2/reply/main`）→ 现有 gRPC UI 类型。
///
/// 为什么需要它：现有 REST 模型（`ReplyData` / `ReplyItemModel`）会丢掉表情、
/// @ 成员、正文链接的 goods/词搜 extra、卡片标签等字段，而这些字段被
/// `ReplyItemGrpc` 与 `ReplyGrpc` 的过滤逻辑直接消费，直接换成 REST 模型等于
/// 换一套 UI。这里把原始 JSON 显式映射成 `MainListReply`，让现有页面、
/// 图片屏蔽、@过滤、带货过滤全部继续生效。
///
/// 约束：
/// - 生成类（`*.pb.dart`）只读，全部用公开构造器显式构造；
/// - 不修改传入的 JSON；
/// - 未在 REST 提供的 gRPC 专属数据（mixed_cards / 全局 vote card / 装扮卡）
///   一律不伪造 presence。
abstract final class ReplyRestAdapter {
  /// 根评论响应 → `MainListReply`。
  ///
  /// [oid] / [type] 作为条目缺省值：REST 条目偶尔不带这两个字段，而回复、
  /// 点赞、翻译全部依赖它们。
  static MainListReply mainList(
    Map<String, dynamic> raw, {
    required int oid,
    required int type,
    Mode? mode,
  }) {
    final cursor = _map(raw['cursor']);
    final paginationReply = _map(cursor?['pagination_reply']);
    final nextOffset = paginationReply?['next_offset'];

    final replies = <ReplyInfo>[];
    final seen = <int>{};
    for (final item in _mapList(raw['replies'])) {
      final mapped = reply(item, oid: oid, type: type);
      if (seen.add(mapped.id.toInt())) replies.add(mapped);
    }

    final top = _map(raw['top']);
    ReplyInfo? upTop;
    final extraTops = <ReplyInfo>[];
    for (final key in const ['upper', 'admin', 'vote']) {
      final item = _map(top?[key]);
      if (item == null) continue;
      final mapped = reply(item, oid: oid, type: type);
      if (mapped.id.toInt() <= 0) continue;
      // 置顶项同时出现在 replies 里时只保留一份（放回复列表原位置，避免
      // 置顶条目在正文中重复显示）。
      if (key == 'upper') {
        // `is_up_top` 必须显式置位：ReplyController.customHandleResponse 会把它
        // 插到 replies[0] 当横幅，ReplyController.onToggleTop 也按它判断
        // 「当前是否已置顶」（取消置顶/重新置顶的意图全靠这个标志）。
        mapped.replyControl.isUpTop = true;
        upTop = mapped;
        replies.removeWhere((item) => item.id == mapped.id);
      } else if (seen.add(mapped.id.toInt())) {
        mapped.replyControl
          ..isAdminTop = key == 'admin'
          ..isVoteTop = key == 'vote';
        extraTops.add(mapped);
      }
    }
    replies.addAll(extraTops);

    return MainListReply(
      cursor: CursorReply(
        next: _int64(cursor?['next']),
        prev: _int64(cursor?['prev']),
        isBegin: cursor?['is_begin'] is bool
            ? cursor!['is_begin'] as bool
            : null,
        // 结束判据只有 offset：服务端可能仍回 is_end=false 但不再给游标。
        isEnd: nextOffset is! String || nextOffset.isEmpty,
        mode: mode,
      ),
      replies: replies,
      paginationReply: FeedPaginationReply(
        nextOffset: nextOffset is String ? nextOffset : '',
      ),
      subjectControl: _subjectControl(raw, cursor),
      upTop: upTop,
      topReplies: _mapList(
        raw['top_replies'],
      ).map((item) => reply(item, oid: oid, type: type)).toList(),
    );
  }

  /// 单条评论 → `ReplyInfo`。
  static ReplyInfo reply(
    Map<String, dynamic> raw, {
    required int oid,
    required int type,
  }) {
    final id = _requiredInt(raw['rpid'], 'rpid');
    final replies = <ReplyInfo>[];
    final seen = <int>{};
    for (final child in _mapList(raw['replies'])) {
      final mapped = reply(child, oid: oid, type: type);
      if (seen.add(mapped.id.toInt())) replies.add(mapped);
    }
    return ReplyInfo(
      id: Int64(id),
      oid: Int64(_int(raw['oid']) ?? oid),
      type: Int64(_int(raw['type']) ?? type),
      mid: _int64(raw['mid']),
      root: _int64(raw['root']),
      parent: _int64(raw['parent']),
      dialog: _int64(raw['dialog']),
      like: _int64(raw['like']),
      ctime: _int64(raw['ctime']),
      count: _int64(raw['count']),
      trackInfo: raw['track_info'] is String
          ? raw['track_info'] as String
          : null,
      content: _content(_map(raw['content'])),
      member: _member(_map(raw['member'])),
      memberV2: _memberV2(_map(raw['member'])),
      replyControl: _replyControl(raw),
      replies: replies,
    );
  }

  static SubjectControl _subjectControl(
    Map<String, dynamic> raw,
    Map<String, dynamic>? cursor,
  ) {
    final control = _map(raw['control']);
    final allCount = _int(cursor?['all_count']);
    return SubjectControl(
      upMid: _int64(_map(raw['upper'])?['mid']),
      // 未知总数用 -1：`ReplyController.checkIsEnd` 会按显示条数与 count 比较，
      // 误报小值会让 REST 列表提前显示「没有更多」。
      count: Int64(allCount != null && allCount >= 0 ? allCount : -1),
      title: cursor?['mode_text'] is String
          ? cursor!['mode_text'] as String
          : null,
      switcherType: Int64(cursor?['support_mode'] is List ? 1 : 0),
      inputDisable: _bool(control?['input_disable']),
      rootText: _string(control?['root_input_text']),
      childText: _string(control?['child_input_text']),
      giveupText: _string(control?['giveup_input_text']),
      bgText: _string(control?['bg_text']),
      disableJumpEmote: _bool(control?['disable_jump_emote']),
      enableCharged: _bool(control?['enable_charged']),
    );
  }

  static Content _content(Map<String, dynamic>? raw) {
    final emotes = <String, Emote>{};
    final rawEmote = _map(raw?['emote']);
    rawEmote?.forEach((token, value) {
      final item = _map(value);
      if (item == null) return;
      final meta = _map(item['meta']);
      emotes[token] = Emote(
        url: _string(item['url']),
        // 尺寸为 0 会让表情渲染不可见，缺 meta.size 时退化为 1。
        size: Int64(_int(meta?['size']) ?? 1),
        jumpUrl: _string(item['jump_url']),
        jumpTitle: _string(item['jump_title']),
        id: _int64(item['id']),
        packageId: _int64(item['package_id']),
        gifUrl: _string(item['gif_url']),
        text: _string(item['text']),
        webpUrl: _string(item['webp_url']),
      );
    });

    // @ 提及：REST 给的是 members 列表，protobuf 需要 name→mid 映射；
    // 名字键不带 `@`（UI 会自己拼）。
    final atNameToMid = <String, Int64>{};
    for (final item in _mapList(raw?['members'])) {
      final name = _string(item['uname']) ?? _string(item['name']);
      final mid = _int(item['mid']);
      if (name == null || name.isEmpty || mid == null || mid <= 0) continue;
      atNameToMid[name.replaceFirst(RegExp(r'^@+'), '')] = Int64(mid);
    }
    final explicitAt = _map(raw?['at_name_to_mid']);
    explicitAt?.forEach((name, value) {
      final mid = _int(value);
      if (mid == null || mid <= 0) return;
      atNameToMid[name.replaceFirst(RegExp(r'^@+'), '')] = Int64(mid);
    });

    final urls = <String, Url>{};
    final rawUrls = _map(raw?['jump_url']);
    rawUrls?.forEach((token, value) {
      final item = _map(value);
      if (item == null) return;
      urls[token] = _url(item, fallbackTitle: token);
    });

    final topics = <String, Topic>{};
    final rawTopics = _map(raw?['topic']);
    rawTopics?.forEach((name, value) {
      final item = _map(value);
      if (item == null) return;
      topics[name.replaceAll('#', '')] = Topic(
        link: _string(item['link']),
        id: _int64(item['id']),
      );
    });

    final pictures = _mapList(raw?['pictures'])
        .map(
          (item) => Picture(
            imgSrc: _string(item['img_src']),
            imgWidth: _double(item['img_width']),
            imgHeight: _double(item['img_height']),
            imgSize: _double(item['img_size']),
            topRightIcon: _string(item['top_right_icon']),
            playGifThumbnail: _bool(item['play_gif_thumbnail']),
          ),
        )
        .toList();

    final voteRaw = _map(raw?['vote']);
    final members = <String, Member>{
      for (final entry in atNameToMid.entries)
        entry.key: Member(mid: entry.value, name: entry.key),
    };
    return Content(
      message: _string(raw?['message']) ?? '',
      emotes: emotes.entries,
      members: members.entries,
      atNameToMid: atNameToMid.entries,
      urls: urls.entries,
      topics: topics.entries,
      pictures: pictures,
      pictureScale: _double(raw?['picture_scale']),
      vote: voteRaw == null
          ? null
          : Vote(
              id: _int64(voteRaw['id']),
              title: _string(voteRaw['title']),
              count: _int64(voteRaw['count']),
            ),
    );
  }

  static Member _member(Map<String, dynamic>? raw) {
    final levelInfo = _map(raw?['level_info']);
    final vip = _map(raw?['vip']);
    final official = _map(raw?['official_verify']);
    final pendant = _map(raw?['pendant']);
    final fansMedal = _map(raw?['fans_medal']);
    final medal = _map(fansMedal?['medal']) ?? fansMedal;
    return Member(
      mid: _int64(raw?['mid']),
      name: _string(raw?['uname']) ?? _string(raw?['name']),
      sex: _string(raw?['sex']),
      face: _string(raw?['avatar']) ?? _string(raw?['face']),
      level: _int64(levelInfo?['current_level']),
      // 缺认证必须显式 -1：protobuf 默认 0 会被 UI 当成个人认证。
      officialVerifyType: Int64(
        official == null ? -1 : (_int(official['type']) ?? -1),
      ),
      vipType: _int64(vip?['vipType'] ?? vip?['vip_type'] ?? vip?['type']),
      vipStatus: _int64(
        vip?['vipStatus'] ?? vip?['vip_status'] ?? vip?['status'],
      ),
      vipThemeType: _int64(vip?['vip_theme_type'] ?? vip?['theme_type']),
      vipNicknameColor: _string(vip?['nickname_color']),
      vipAvatarSubscript: _int(vip?['avatar_subscript']),
      vipLabelText: _string(_map(vip?['label'])?['text']),
      vipLabelTheme: _string(_map(vip?['label'])?['label_theme']),
      garbPendantImage: _string(pendant?['image']),
      isSeniorMember: _int(raw?['is_senior_member']),
      faceNftNew: _int(raw?['face_nft_new']),
      fansMedalName: _string(medal?['medal_name'] ?? medal?['name']),
      fansMedalLevel: _int64(medal?['level'] ?? medal?['medal_level']),
      fansMedalColor: _int64(medal?['color'] ?? medal?['medal_color']),
      fansMedalColorName: _int64(medal?['medal_color_name']),
    );
  }

  /// 只映射真实存在的装扮/勋章字段；没有就整块不设置。
  static MemberV2 _memberV2(Map<String, dynamic>? raw) {
    final basic = _member(raw);
    final garb = _map(raw?['garb']) ?? _map(raw?['card']);
    final medal = _map(raw?['fans_medal']) ?? _map(raw?['medal']);
    return MemberV2(
      basic: MemberV2_Basic(
        mid: basic.mid,
        name: basic.name,
        sex: basic.sex,
        face: basic.face,
        level: basic.level,
      ),
      vip: MemberV2_Vip(
        type: basic.vipType,
        status: basic.vipStatus,
        themeType: basic.vipThemeType,
        nicknameColor: basic.vipNicknameColor,
        avatarSubscript: basic.vipAvatarSubscript,
        labelText: basic.vipLabelText,
        vipLabelTheme: basic.vipLabelTheme,
      ),
      garb: garb == null
          ? null
          : MemberV2_Garb(
              pendantImage: _string(garb['pendant_image']),
              cardImage: _string(garb['card_image']),
              cardImageWithFocus: _string(garb['card_image_with_focus']),
              cardJumpUrl: _string(garb['card_jump_url']),
              cardNumber: _string(garb['card_number']),
              cardFanColor: _string(garb['card_fan_color']),
              cardIsFan: _bool(garb['card_is_fan']),
            ),
      medal: medal == null
          ? null
          : MemberV2_Medal(
              name: _string(medal['medal_name'] ?? medal['name']),
              level: _int64(medal['level'] ?? medal['medal_level']),
              colorName: _int64(medal['medal_color_name']),
            ),
    );
  }

  static ReplyControl _replyControl(Map<String, dynamic> raw) {
    final control = _map(raw['reply_control']);
    final upAction = _map(raw['up_action']);
    final folder = _map(raw['folder']);
    final voteOption =
        _map(raw['vote_option']) ?? _map(control?['vote_option']);
    final labels = _mapList(raw['card_label'] ?? control?['card_labels']);
    return ReplyControl(
      action: _int64(raw['action']),
      upLike: _bool(upAction?['like']),
      upReply: _bool(upAction?['reply']),
      isAssist: _int(raw['assist']) == 1 || _int(control?['is_assist']) == 1,
      invisible: _bool(raw['invisible']),
      hasFoldedReply: _bool(folder?['has_folded_reply']),
      isFoldedReply: _bool(folder?['is_folded_reply']),
      maxLine: _int64(control?['max_line']),
      timeDesc: _string(control?['time_desc']),
      bizScene: _string(control?['biz_scene']),
      location: _string(control?['location']),
      isNoteV2: _bool(control?['is_note_v2']),
      translationSwitch: _translationSwitch(control?['translation_switch']),
      cardLabels: labels
          .map(
            (item) => ReplyCardLabel(
              textContent: _string(item['text_content'] ?? item['text']),
              textColorDay: _string(item['text_color_day']),
              textColorNight: _string(item['text_color_night']),
              labelColorDay: _string(item['label_color_day']),
              labelColorNight: _string(item['label_color_night']),
              image: _string(item['image']),
              type: _cardLabelType(item['type']),
              background: _string(item['background']),
              backgroundWidth: _double(item['background_width']),
              backgroundHeight: _double(item['background_height']),
              jumpUrl: _string(item['jump_url']),
            ),
          )
          .toList(),
      voteOption: voteOption == null
          ? null
          : ReplyControl_VoteOption(
              labelKind: _voteLabelKind(voteOption['label_kind']),
              desc: _string(voteOption['desc']),
              idx: _int64(voteOption['idx']),
              voteId: _int64(voteOption['vote_id']),
            ),
    );
  }

  static Url _url(Map<String, dynamic> raw, {required String fallbackTitle}) {
    final extra = _map(raw['extra']);
    return Url(
      // 标题缺失时退回正文里的 token，否则链接在正文中不可见。
      title: _string(raw['title']) ?? fallbackTitle,
      state: _int64(raw['state']),
      prefixIcon: _string(raw['prefix_icon']),
      appUrlSchema: _string(raw['app_url_schema']),
      appName: _string(raw['app_name']),
      appPackageName: _string(raw['app_package_name']),
      clickReport: _string(raw['click_report']),
      isHalfScreen: _bool(raw['is_half_screen']),
      exposureReport: _string(raw['exposure_report']),
      underline: _bool(raw['underline']),
      matchOnce: _bool(raw['match_once']),
      pcUrl: _string(raw['pc_url']),
      // goods / 词搜 extra 是带货过滤与商品链接判断的依据，必须保留。
      extra: extra == null
          ? null
          : Url_Extra(
              goodsItemId: _int64(extra['goods_item_id']),
              goodsPrefetchedCache: _string(extra['goods_prefetched_cache']),
              goodsCmControl: _int64(extra['goods_cm_control']),
              goodsClickReport: _string(extra['goods_click_report']),
              goodsExposureReport: _string(extra['goods_exposure_report']),
              isWordSearch: _bool(extra['is_word_search']),
            ),
    );
  }

  static TranslationSwitch? _translationSwitch(Object? value) {
    final raw = _int(value);
    return raw == null
        ? null
        : switch (raw) {
            1 => TranslationSwitch.TRANSLATION_SWITCH_UNSUPPORTED,
            2 => TranslationSwitch.TRANSLATION_SWITCH_SHOW_TRANSLATION,
            3 => TranslationSwitch.TRANSLATION_SWITCH_SHOW_ORIGIN,
            _ => null,
          };
  }

  static ReplyControl_VoteOption_LabelKind? _voteLabelKind(Object? value) {
    final raw = _int(value);
    return raw == null
        ? null
        : switch (raw) {
            1 => ReplyControl_VoteOption_LabelKind.RED,
            2 => ReplyControl_VoteOption_LabelKind.BLUE,
            3 => ReplyControl_VoteOption_LabelKind.PLAIN,
            _ => null,
          };
  }

  static ReplyCardLabel_Type? _cardLabelType(Object? value) {
    final raw = _int(value);
    if (raw == null) return null;
    for (final candidate in ReplyCardLabel_Type.values) {
      if (candidate.value == raw) return candidate;
    }
    return null;
  }

  // ── 解析 helper：只接受安全形态，绝不把畸形结构悄悄变成 0 ──

  static int _requiredInt(Object? value, String field) {
    final parsed = _int(value);
    if (parsed == null || parsed <= 0) {
      throw FormatException('Invalid REST reply $field: $value');
    }
    return parsed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Int64? _int64(Object? value) {
    final parsed = _int(value);
    return parsed == null ? null : Int64(parsed);
  }

  static double? _double(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static bool? _bool(Object? value) {
    if (value is bool) return value;
    if (value is int) return value == 1;
    return null;
  }

  static String? _string(Object? value) {
    if (value is String) return value;
    if (value is num) return value.toString();
    return null;
  }

  static Map<String, dynamic>? _map(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static List<Map<String, dynamic>> _mapList(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value) ?_map(item),
    ];
  }
}
