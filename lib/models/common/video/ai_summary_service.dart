import 'package:PiliPlus/models/common/enum_with_label.dart';

enum AiSummaryService implements EnumWithLabel {
  subtitleAi('字幕 AI 总结'),
  multimodalAi('多模态 AI 总结'),
  bilibiliLegacyDeprecated('哔哩哔哩 AI 总结'),
  ;

  @override
  final String label;
  const AiSummaryService(this.label);
}
