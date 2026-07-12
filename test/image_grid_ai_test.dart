import 'dart:io';

import 'package:PiliPlus/common/widgets/image/blocked_image_placeholder.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/image_grid/image_grid_builder.dart';
import 'package:PiliPlus/common/widgets/image_grid/image_grid_view.dart';
import 'package:PiliPlus/utils/ai_image_moderation_service.dart';
import 'package:PiliPlus/utils/ai_image_state.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_image_grid_ai_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() {
    ImageBlockService.invalidateResultCache();
    AiImageModerationService.invalidateCache();
    Pref.enableImageBlock = true;
    Pref.enableAiImageModeration = true;
    Pref.imageBlockHashList = <Map<String, dynamic>>[];
    Pref.imageBlockThreshold = 0;
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget _buildImageGridView(List<ImageModel> picArr) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImageGridView(picArr: picArr),
        ),
      ),
    );
  }

  group('ImageGridView AI states', () {
    testWidgets(
      'AI blocked shows BlockedImagePlaceholder',
      (tester) async {
        const url = 'https://example.com/ai-blocked.jpg';
        // pHash: not blocked
        ImageBlockService.setCachedResult(url, false);
        // AI: blocked
        AiImageModerationService.setCachedResult(url, AiImageState.blocked);

        await tester.pumpWidget(
          _buildImageGridView([
            ImageModel(width: 100, height: 100, url: url),
          ]),
        );

        // Pump to process deferred AI evaluation + setState rebuild
        await tester.pump();
        await tester.pump();

        expect(find.byType(BlockedImagePlaceholder), findsOneWidget);
        expect(find.byType(NetworkImgLayer), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets(
      'AI highRisk shows blurred NetworkImgLayer',
      (tester) async {
        const url = 'https://example.com/ai-lowres.jpg';
        // pHash: not blocked
        ImageBlockService.setCachedResult(url, false);
        // AI: highRisk
        AiImageModerationService.setCachedResult(url, AiImageState.highRisk);

        await tester.pumpWidget(
          _buildImageGridView([
            ImageModel(width: 100, height: 100, url: url),
          ]),
        );

        // Pump to process deferred AI evaluation + setState rebuild
        await tester.pump();
        await tester.pump();

        // highRisk wraps NetworkImgLayer in ImageFiltered blur with warning text
        expect(find.byType(ImageFiltered), findsOneWidget);
        expect(find.text('图片可能引起不适，点击后查看'), findsOneWidget);
        expect(find.byType(NetworkImgLayer), findsOneWidget);
        expect(find.byType(BlockedImagePlaceholder), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets(
      'AI normal shows NetworkImgLayer normally',
      (tester) async {
        const url = 'https://example.com/ai-normal.jpg';
        // pHash: not blocked
        ImageBlockService.setCachedResult(url, false);
        // AI: normal
        AiImageModerationService.setCachedResult(url, AiImageState.normal);

        await tester.pumpWidget(
          _buildImageGridView([
            ImageModel(width: 100, height: 100, url: url),
          ]),
        );

        // Pump to process deferred AI evaluation + setState rebuild
        await tester.pump();
        await tester.pump();

        expect(find.byType(NetworkImgLayer), findsOneWidget);
        expect(find.byType(BlockedImagePlaceholder), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets(
      'AI pending shows placeholder with CircularProgressIndicator',
      (tester) async {
        const url = 'https://example.com/ai-pending.jpg';
        // pHash: not blocked
        ImageBlockService.setCachedResult(url, false);
        // AI: cached as pending (async evaluation hasn't completed yet)
        AiImageModerationService.setCachedResult(url, AiImageState.pending);

        await tester.pumpWidget(
          _buildImageGridView([
            ImageModel(width: 100, height: 100, url: url),
          ]),
        );

        // Pump to process deferred AI evaluation → reads cached pending → rebuild
        await tester.pump();
        await tester.pump();

        // Pending → neutral placeholder with spinner, not the actual image
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(NetworkImgLayer), findsNothing);
        expect(find.byType(BlockedImagePlaceholder), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets(
      'pHash blocked takes priority over AI state',
      (tester) async {
        const url = 'https://example.com/phash-blocked.jpg';
        // pHash: blocked
        ImageBlockService.setCachedResult(url, true);
        // AI: normal (would show if pHash didn't block)
        AiImageModerationService.setCachedResult(url, AiImageState.normal);

        await tester.pumpWidget(
          _buildImageGridView([
            ImageModel(width: 100, height: 100, url: url),
          ]),
        );

        await tester.pump();

        expect(find.byType(BlockedImagePlaceholder), findsOneWidget);
        expect(find.byType(NetworkImgLayer), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets(
      'AI blocked with temp-unblock shows normal image',
      (tester) async {
        // Use tempUnblockedUrls to bypass all blocking
        const url = 'https://example.com/ai-blocked-but-unblocked.jpg';
        ImageBlockService.setCachedResult(url, false);
        AiImageModerationService.setCachedResult(url, AiImageState.blocked);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ImageGridView(
                  picArr: [ImageModel(width: 100, height: 100, url: url)],
                  tempUnblockedUrls: {url},
                ),
              ),
            ),
          ),
        );

        // Pump to process deferred AI evaluation + setState rebuild
        await tester.pump();
        await tester.pump();

        // tempUnblocked → normal render despite AI blocked
        expect(find.byType(NetworkImgLayer), findsOneWidget);
        expect(find.byType(BlockedImagePlaceholder), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );

    testWidgets(
      'AI highRisk tap adds URL to temp unblock and shows normal display',
      (tester) async {
        const url = 'https://example.com/ai-highrisk-tap.jpg';
        // pHash: not blocked
        ImageBlockService.setCachedResult(url, false);
        // AI: highRisk
        AiImageModerationService.setCachedResult(url, AiImageState.highRisk);

        await tester.pumpWidget(
          _buildImageGridView([
            ImageModel(width: 100, height: 100, url: url),
          ]),
        );

        // Pump to process deferred AI evaluation + setState rebuild
        await tester.pump();
        await tester.pump();

        // Verify highRisk state is shown
        expect(find.byType(ImageFiltered), findsOneWidget);
        expect(find.text('图片可能引起不适，点击后查看'), findsOneWidget);

        // Tap the warning text to temporarily unblock
        await tester.tap(find.text('图片可能引起不适，点击后查看'));
        await tester.pump();

        // After tap → temp unblocked → normal display (no blur)
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.text('图片可能引起不适，点击后查看'), findsNothing);
        expect(find.byType(NetworkImgLayer), findsOneWidget);
        expect(find.byType(BlockedImagePlaceholder), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      },
    );
  });
}
