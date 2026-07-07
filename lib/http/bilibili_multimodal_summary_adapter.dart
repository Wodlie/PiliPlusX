import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/openai_compatible_summary_provider.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_summary_provider.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/service_result.dart';

abstract final class BilibiliMultimodalSummaryAdapter {
  static const String _prompt =
      '请只基于输入的完整 bilibili 视频内容生成中文总结，不要虚构未出现的信息。输出自然中文正文即可。';

  static Future<AiSummaryServiceResult> summarizeUgcVideo({
    required String bvid,
    required int cid,
    String? title,
  }) async {
    final LoadingState<String> mp4Result = await VideoHttp.ugcSummaryMp4Url(
      bvid: bvid,
      cid: cid,
    );
    if (mp4Result is! Success<String>) {
      final String message = mp4Result.toString().trim();
      return AiSummaryServiceUnavailable(
        message.isEmpty ? '未获取到可用的 bilibili 360P MP4 视频地址' : message,
      );
    }

    final OpenAiCompatibleMp4VideoInput video;
    try {
      video = OpenAiCompatibleMp4VideoInput.parse(mp4Result.response);
    } on FormatException catch (error) {
      return AiSummaryServiceUnavailable(error.message);
    }

    final providerResult =
        await OpenAiCompatibleSummaryProvider.summarizeMultimodal(
          OpenAiCompatibleMultimodalSummaryRequest(
            prompt: _prompt,
            title: title,
            bvid: bvid,
            cid: cid,
            video: video,
          ),
        );

    if (providerResult case VideoSummaryProviderSuccess(:final data)) {
      final String summary = data.text.trim();
      if (summary.isEmpty) {
        return const AiSummaryServiceProviderError('Provider 未返回可用总结内容');
      }
      return AiSummaryServiceSuccess(AiConclusionResult(summary: summary));
    }

    final VideoSummaryProviderFailure failure = providerResult.errorOrNull!;
    return switch (failure.type) {
      VideoSummaryProviderErrorType.misconfigured =>
        AiSummaryServiceMisconfigured(
          failure.message,
        ),
      VideoSummaryProviderErrorType.unsupportedCapability =>
        AiSummaryServiceProviderError(
          failure.message.isEmpty ? '当前 Provider 不支持视频多模态输入' : failure.message,
        ),
      _ => AiSummaryServiceProviderError(
        failure.message.isEmpty ? 'AI 总结生成失败' : failure.message,
      ),
    };
  }
}
