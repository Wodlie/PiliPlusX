import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AI summary routing source contracts', () {
    test('router selects exactly one adapter implementation per service', () {
      final String source = File(
        'lib/http/ai_summary_service_router.dart',
      ).readAsStringSync();

      expect(
        source,
        contains(
          'final AiSummaryService selectedService = service ?? Pref.aiSummaryService;',
        ),
      );
      expect(source, contains('return switch (selectedService) {'));
      expect(
        RegExp(
          r'AiSummaryService\.subtitleAi\s*=>\s*BilibiliSubtitleSummaryAdapter\.summarizeUgcVideo',
        ).hasMatch(source),
        isTrue,
      );
      expect(
        RegExp(
          r'AiSummaryService\.multimodalAi\s*=>\s*BilibiliMultimodalSummaryAdapter\.summarizeUgcVideo',
        ).hasMatch(source),
        isTrue,
      );
      expect(
        RegExp(
          r'AiSummaryService\.bilibiliLegacyDeprecated\s*=>\s*BilibiliLegacySummaryAdapter\.summarizeUgcVideo',
        ).hasMatch(source),
        isTrue,
      );

      final Iterable<Match> routeCases = RegExp(
        r'AiSummaryService\.(subtitleAi|multimodalAi|bilibiliLegacyDeprecated)\s*=>',
      ).allMatches(source);
      expect(routeCases.length, 3);
      expect(
        source.contains('fallback'),
        isFalse,
        reason: 'Router must not silently fall back to another implementation.',
      );
    });

    test(
      'multimodal path reads MP4 durl helper instead of DASH video or audio urls',
      () {
        final String multimodalAdapter = File(
          'lib/http/bilibili_multimodal_summary_adapter.dart',
        ).readAsStringSync();
        final String videoHttp = File('lib/http/video.dart').readAsStringSync();
        final String providerModels = File(
          'lib/models/common/video/video_summary_provider.dart',
        ).readAsStringSync();

        expect(
          multimodalAdapter,
          contains('VideoHttp.ugcSummaryMp4Url('),
          reason: 'Multimodal summary must fetch a bilibili MP4 durl first.',
        );
        expect(
          multimodalAdapter,
          contains('OpenAiCompatibleMp4VideoInput.parse(mp4Result.response);'),
          reason:
              'The adapter must validate the returned URL against the MP4 input contract.',
        );
        expect(multimodalAdapter.contains('videoUrl'), isFalse);
        expect(multimodalAdapter.contains('audioUrl'), isFalse);
        expect(multimodalAdapter.contains('dash'), isFalse);

        expect(
          videoHttp,
          contains('final Durl? firstDurl = data.durl?.firstOrNull;'),
        );
        expect(videoHttp, contains('未获取到 bilibili 360P MP4 durl'));
        expect(videoHttp, contains('bilibili 360P MP4 durl 无有效 URL'));

        expect(providerModels, contains('class OpenAiCompatibleMp4VideoInput'));
        expect(
          providerModels,
          contains('视频输入必须是有效的 http/https URL'),
        );
        expect(providerModels, contains("'type': 'video_url'"));
      },
    );
  });
}
