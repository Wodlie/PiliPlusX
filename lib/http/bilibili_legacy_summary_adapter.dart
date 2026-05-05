import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/data.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/service_result.dart';

abstract final class BilibiliLegacySummaryAdapter {
  static Future<AiSummaryServiceResult> summarizeUgcVideo({
    required String bvid,
    required int cid,
    int? upMid,
  }) async {
    final LoadingState<AiConclusionData> result = await VideoHttp.aiConclusion(
      bvid: bvid,
      cid: cid,
      upMid: upMid,
    );

    if (result case Success(:final response)) {
      final AiConclusionResult? conclusion = response.modelResult;
      if (_hasUsableConclusion(conclusion)) {
        return AiSummaryServiceSuccess(conclusion!);
      }
      return const AiSummaryServiceLegacyError('哔哩哔哩未返回可用的 AI 总结内容');
    }

    if (result case Error(:final errMsg, :final code)) {
      final String message = errMsg?.trim() ?? '';
      if (message.isNotEmpty) {
        return AiSummaryServiceLegacyError(message);
      }
      if (code != null) {
        return AiSummaryServiceLegacyError('哔哩哔哩 AI 总结请求失败（code: $code）');
      }
    }
    return const AiSummaryServiceLegacyError('哔哩哔哩 AI 总结生成失败');
  }

  static bool _hasUsableConclusion(AiConclusionResult? result) {
    return result?.summary?.trim().isNotEmpty == true ||
        result?.outline?.isNotEmpty == true;
  }
}
