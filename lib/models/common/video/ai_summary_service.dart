import 'package:PiliPlus/models/common/enum_with_label.dart';

enum AiSummaryService implements EnumWithLabel {
  subtitleAi('字幕 AI 总结'),
  multimodalAi('多模态 AI 总结（仅 bilibili UGC 视频详情页）'),
  bilibiliLegacyDeprecated('哔哩哔哩 AI 总结（即将弃用）'),
  ;

  @override
  final String label;
  const AiSummaryService(this.label);
}
