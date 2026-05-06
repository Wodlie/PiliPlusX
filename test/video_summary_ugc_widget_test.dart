import 'package:PiliPlus/models/common/video/ai_summary_service.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/model_result.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/outline.dart';
import 'package:PiliPlus/models_new/video/video_ai_conclusion/part_outline.dart';
import 'package:PiliPlus/pages/video/ai_conclusion/view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UGC AI summary widgets', () {
    test('legacy service label keeps deprecated wording', () {
      expect(AiSummaryService.bilibiliLegacyDeprecated.label, contains('哔哩哔哩'));
      expect(
        AiSummaryService.bilibiliLegacyDeprecated.label,
        contains('即将弃用'),
      );
    });

    testWidgets('existing AI conclusion container shows summary and outline content', (
      WidgetTester tester,
    ) async {
      final AiConclusionResult result = AiConclusionResult(
        summary: '这里是总结正文',
        outline: <Outline>[
          Outline(
            title: '章节一',
            partOutline: <PartOutline>[
              PartOutline(timestamp: 12, content: '关键片段'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                return AiConclusionPanel.buildContent(
                  context,
                  Theme.of(context),
                  result,
                  tap: false,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('这里是总结正文'), findsOneWidget);
      expect(find.text('章节一'), findsOneWidget);
      expect(find.text('关键片段'), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(AiConclusionPanel.hasContent(result), isTrue);
    });
  });
}
