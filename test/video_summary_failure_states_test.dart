import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/service_result.dart';
import 'package:PiliPlus/pages/video/ai_conclusion/view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AI summary failure mapping', () {
    test(
      'explicit failure states keep their own messages without fallback',
      () {
        expect(
          AiConclusionPanel.messageForResult(
            const AiSummaryServiceNoSubtitle('字幕链路缺失'),
          ),
          '字幕链路缺失',
        );
        expect(
          AiConclusionPanel.messageForResult(
            const AiSummaryServiceMisconfigured('请先配置 Provider'),
          ),
          '请先配置 Provider',
        );
        expect(
          AiConclusionPanel.messageForResult(
            const AiSummaryServiceProviderError('Provider 返回 429'),
          ),
          'Provider 返回 429',
        );
        expect(
          AiConclusionPanel.messageForResult(
            const AiSummaryServiceLegacyError('官方总结接口失败'),
          ),
          '官方总结接口失败',
        );
        expect(
          AiConclusionPanel.messageForResult(
            const AiSummaryServiceUnavailable('当前视频没有可用 MP4 durl'),
          ),
          '当前视频没有可用 MP4 durl',
        );
      },
    );

    test('default messages stay distinct for each failure class', () {
      expect(
        AiConclusionPanel.messageForResult(const AiSummaryServiceNoSubtitle()),
        '当前视频暂无可用字幕',
      );
      expect(
        AiConclusionPanel.messageForResult(
          const AiSummaryServiceMisconfigured(),
        ),
        '请先完成 AI 总结服务配置',
      );
      expect(
        AiConclusionPanel.messageForResult(
          const AiSummaryServiceProviderError(),
        ),
        'AI 总结生成失败',
      );
      expect(
        AiConclusionPanel.messageForResult(const AiSummaryServiceLegacyError()),
        '哔哩哔哩 AI 总结生成失败',
      );
      expect(
        AiConclusionPanel.messageForResult(const AiSummaryServiceUnavailable()),
        '当前视频暂不支持 AI 视频总结',
      );
    });

    test(
      'success without usable content does not masquerade as a failure type',
      () {
        expect(
          AiConclusionPanel.messageForResult(
            AiSummaryServiceSuccess(AiConclusionResult()),
          ),
          '当前视频暂不支持 AI 视频总结',
        );
        expect(
          AiConclusionPanel.messageForResult(
            AiSummaryServiceSuccess(AiConclusionResult(summary: '已有总结')),
          ),
          '',
        );
      },
    );
  });
}
