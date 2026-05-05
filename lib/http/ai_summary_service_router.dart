import 'package:PiliPlus/http/bilibili_legacy_summary_adapter.dart';
import 'package:PiliPlus/http/bilibili_multimodal_summary_adapter.dart';
import 'package:PiliPlus/http/bilibili_subtitle_summary_adapter.dart';
import 'package:PiliPlus/models/common/video/ai_summary_service.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/service_result.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

abstract final class AiSummaryServiceRouter {
  static Future<AiSummaryServiceResult> summarizeUgcVideo({
    required String bvid,
    required int cid,
    String? title,
    int? upMid,
    AiSummaryService? service,
  }) {
    final AiSummaryService selectedService = service ?? Pref.aiSummaryService;
    return switch (selectedService) {
      AiSummaryService.subtitleAi =>
        BilibiliSubtitleSummaryAdapter.summarizeUgcVideo(
          bvid: bvid,
          cid: cid,
          title: title,
        ),
      AiSummaryService.multimodalAi =>
        BilibiliMultimodalSummaryAdapter.summarizeUgcVideo(
          bvid: bvid,
          cid: cid,
          title: title,
        ),
      AiSummaryService.bilibiliLegacyDeprecated =>
        BilibiliLegacySummaryAdapter.summarizeUgcVideo(
          bvid: bvid,
          cid: cid,
          upMid: upMid,
        ),
    };
  }
}
