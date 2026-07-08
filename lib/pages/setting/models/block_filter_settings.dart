import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/dynamics/result.dart' show DynamicsDataModel;
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/utils/recommend_filter.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

Future<void> _showReplyMinLevelDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final result = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '评论用户等级过滤',
      value: ReplyGrpc.minLevelForReply,
      values: List.generate(
        7, // lv0..lv6
        (i) => (i, i == 0 ? 'lv0（不过滤）' : 'lv$i'),
      ),
    ),
  );
  if (result != null) {
    ReplyGrpc.minLevelForReply = result;
    await GStorage.setting.put(SettingBoxKey.minLevelForReply, result);
    setState();
  }
}

List<SettingsModel> get blockFilterSettings => [
  // 评论过滤组
  getBanWordModel(
    title: '评论关键词过滤',
    key: SettingBoxKey.banWordForReply,
    onChanged: (value) {
      ReplyGrpc.replyRegExp = value;
      ReplyGrpc.enableFilter = value.pattern.isNotEmpty;
    },
  ),
  NormalModel(
    title: '评论用户等级过滤',
    leading: const Icon(Icons.person_off_outlined),
    getSubtitle: () => ReplyGrpc.minLevelForReply == 0
        ? '不过滤'
        : '屏蔽低于 lv${ReplyGrpc.minLevelForReply} 的评论',
    onTap: _showReplyMinLevelDialog,
  ),
  SplitModel(
    normalModel: const NormalModel.split(
      title: '@评论过滤',
      subtitle: '低质量 @ 评论过滤，点击配置',
      leading: Icon(Icons.alternate_email),
    ),
    switchModel: SwitchModel.split(
      defaultVal: false,
      setKey: SettingBoxKey.enableAtFilter,
      onTap: (context) => Get.toNamed('/atFilterSetting'),
    ),
  ),
  SwitchModel(
    title: '屏蔽带货评论',
    leading: const Icon(CustomIcons.shopping_bag_not_interested),
    setKey: SettingBoxKey.antiGoodsReply,
    defaultVal: false,
    onChanged: (value) => ReplyGrpc.antiGoodsReply = value,
  ),
  SwitchModel(
    title: '显示被屏蔽评论提示',
    subtitle: '被屏蔽的评论显示为提示横幅而非直接移除',
    leading: const Icon(Icons.block_outlined),
    setKey: SettingBoxKey.showBlockedReplyBanner,
    defaultVal: true,
    onChanged: (value) => ReplyGrpc.showBlockedReplyBanner = value,
  ),

  // 动态过滤组
  getBanWordModel(
    title: '动态关键词过滤',
    key: SettingBoxKey.banWordForDyn,
    onChanged: (value) {
      DynamicsDataModel.banWordForDyn = value;
      DynamicsDataModel.enableFilter = value.pattern.isNotEmpty;
    },
  ),
  SwitchModel(
    title: '屏蔽带货动态',
    leading: const Icon(CustomIcons.shopping_bag_not_interested),
    setKey: SettingBoxKey.antiGoodsDyn,
    defaultVal: false,
    onChanged: (value) => DynamicsDataModel.antiGoodsDyn = value,
  ),

  // 推荐过滤组
  getBanWordModel(
    title: '标题关键词过滤',
    key: SettingBoxKey.banWordForRecommend,
    onChanged: (value) {
      RecommendFilter.rcmdRegExp = value;
      RecommendFilter.enableFilter = value.pattern.isNotEmpty;
    },
  ),
  getBanWordModel(
    title: 'App推荐/热门/排行榜: 视频分区关键词过滤',
    key: SettingBoxKey.banWordForZone,
    onChanged: (value) {
      VideoHttp.zoneRegExp = value;
      VideoHttp.enableFilter = value.pattern.isNotEmpty;
    },
  ),
];
