import 'dart:convert';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/openai_compatible_summary_provider.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_summary_provider.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/outline.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/part_outline.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/service_result.dart';
import 'package:PiliPlus/models_new/video/video_play_info/data.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';

abstract final class BilibiliSubtitleSummaryAdapter {
  static const String _systemPrompt =
      '你是一个视频字幕总结助手。请只基于用户提供的字幕 transcript 生成总结，不要虚构未出现的信息。输出必须是合法 JSON，且不要使用 Markdown 代码块。';
  static const String _outputSchema =
      '{"summary":"字符串","outline":[{"title":"字符串","part_outline":[{"timestamp":123,"content":"字符串"}]}]}';

  static Future<AiSummaryServiceResult> summarizeUgcVideo({
    required String bvid,
    required int cid,
    String? title,
  }) async {
    final LoadingState<PlayInfoData> playInfo = await VideoHttp.playInfo(
      bvid: bvid,
      cid: cid,
    );
    if (playInfo is! Success<PlayInfoData>) {
      return const AiSummaryServiceUnavailable('获取字幕信息失败');
    }
    final PlayInfoData response = playInfo.response;

    final Subtitle? subtitle = _pickSubtitle(response.subtitle?.subtitles);
    if (subtitle == null) {
      return const AiSummaryServiceNoSubtitle('当前视频暂无可用字幕');
    }

    final String subtitleUrl =
        subtitle.subtitleUrl?.trim().isNotEmpty == true
        ? subtitle.subtitleUrl!.trim()
        : subtitle.subtitleUrlV2?.trim() ?? '';
    if (subtitleUrl.isEmpty) {
      return const AiSummaryServiceNoSubtitle('当前视频暂无可用字幕');
    }

    final String? transcript = await VideoHttp.transcriptSubtitles(subtitleUrl);
    if (transcript == null || transcript.trim().isEmpty) {
      return const AiSummaryServiceUnavailable('字幕整理失败，暂时无法生成总结');
    }

    final VideoSummaryProviderResult<OpenAiCompatibleSummaryResponse>
    providerResult = await OpenAiCompatibleSummaryProvider.summarizeText(
      OpenAiCompatibleTextSummaryRequest(
        systemPrompt: _systemPrompt,
        title: title,
        prompt: _buildPrompt(
          bvid: bvid,
          cid: cid,
          subtitle: subtitle,
          transcript: transcript.trim(),
        ),
      ),
    );

    if (providerResult case VideoSummaryProviderSuccess(:final data)) {
      final AiConclusionResult parsed = _parseSummaryResponse(data.text);
      if (_hasUsableConclusion(parsed)) {
        return AiSummaryServiceSuccess(parsed);
      }
      return const AiSummaryServiceProviderError('Provider 返回内容无法解析为有效总结');
    }

    final VideoSummaryProviderFailure failure = providerResult.errorOrNull!;
    return switch (failure.type) {
      VideoSummaryProviderErrorType.misconfigured => AiSummaryServiceMisconfigured(
        failure.message,
      ),
      _ => AiSummaryServiceProviderError(failure.message),
    };
  }

  static Subtitle? _pickSubtitle(List<Subtitle>? subtitles) {
    if (subtitles == null || subtitles.isEmpty) {
      return null;
    }
    for (final subtitle in subtitles) {
      if (!subtitle.isAi &&
          (subtitle.subtitleUrl?.trim().isNotEmpty == true ||
              subtitle.subtitleUrlV2?.trim().isNotEmpty == true)) {
        return subtitle;
      }
    }
    for (final subtitle in subtitles) {
      if (subtitle.subtitleUrl?.trim().isNotEmpty == true ||
          subtitle.subtitleUrlV2?.trim().isNotEmpty == true) {
        return subtitle;
      }
    }
    return null;
  }

  static String _buildPrompt({
    required String bvid,
    required int cid,
    required Subtitle subtitle,
    required String transcript,
  }) {
    final String language = subtitle.lanDoc?.trim().isNotEmpty == true
        ? subtitle.lanDoc!.trim()
        : subtitle.lan;
    return '''
请基于以下 bilibili 视频字幕 transcript 生成中文总结。

要求：
1. 输出必须是合法 JSON，对象结构必须严格符合：$_outputSchema
2. summary 需要概括核心内容，使用自然中文
3. outline 可为空数组；如果能从字幕中提炼结构，请按主题拆分，并尽量给出秒级 timestamp
4. 不要输出 JSON 之外的任何说明
5. 不要臆造字幕里没有出现的信息

视频信息：
- BVID: $bvid
- CID: $cid
- 字幕语言: $language

字幕 transcript：
$transcript
''';
  }

  static AiConclusionResult _parseSummaryResponse(String text) {
    final String trimmed = text.trim();
    final Map<String, dynamic>? json = _tryParseConclusionJson(trimmed);
    if (json != null) {
      final AiConclusionResult result = AiConclusionResult(
        summary: json['summary']?.toString().trim(),
        outline: _parseOutline(json['outline']),
      );
      if (_hasUsableConclusion(result)) {
        return result;
      }
    }
    return AiConclusionResult(summary: trimmed);
  }

  static Map<String, dynamic>? _tryParseConclusionJson(String text) {
    final List<String> candidates = <String>[
      text,
      _stripMarkdownCodeFence(text),
      _extractJsonObject(text),
    ].where((item) => item.trim().isNotEmpty).toList();

    for (final candidate in candidates) {
      try {
        final dynamic decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return decoded.map(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value),
          );
        }
      } catch (_) {}
    }
    return null;
  }

  static String _stripMarkdownCodeFence(String text) {
    final String trimmed = text.trim();
    final RegExp pattern = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    final Match? match = pattern.firstMatch(trimmed);
    return match?.group(1)?.trim() ?? trimmed;
  }

  static String _extractJsonObject(String text) {
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      return '';
    }
    return text.substring(start, end + 1).trim();
  }

  static List<Outline>? _parseOutline(dynamic rawOutline) {
    if (rawOutline is! List) {
      return null;
    }
    final List<Outline> outlines = <Outline>[];
    for (final item in rawOutline) {
      if (item is! Map) {
        continue;
      }
      final String? title = item['title']?.toString().trim();
      final List<PartOutline> parts = <PartOutline>[];
      final dynamic rawPartOutline = item['part_outline'] ?? item['partOutline'];
      if (rawPartOutline is List) {
        for (final rawPart in rawPartOutline) {
          if (rawPart is! Map) {
            continue;
          }
          final String? content = rawPart['content']?.toString().trim();
          final int? timestamp = _parseTimestamp(rawPart['timestamp']);
          if ((content?.isNotEmpty ?? false) || timestamp != null) {
            parts.add(PartOutline(timestamp: timestamp, content: content));
          }
        }
      }
      if ((title?.isNotEmpty ?? false) || parts.isNotEmpty) {
        outlines.add(Outline(title: title, partOutline: parts));
      }
    }
    return outlines.isEmpty ? null : outlines;
  }

  static int? _parseTimestamp(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static bool _hasUsableConclusion(AiConclusionResult result) {
    return result.summary?.trim().isNotEmpty == true ||
        result.outline?.isNotEmpty == true;
  }
}
