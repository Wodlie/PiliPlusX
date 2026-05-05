import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_video_summary_settings_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDown(() async {
    await Future.wait([
      GStorage.setting.delete(SettingBoxKey.aiSummaryService),
      GStorage.setting.delete(SettingBoxKey.aiSummaryBaseUrl),
      GStorage.setting.delete(SettingBoxKey.aiSummaryApiKey),
      GStorage.setting.delete(SettingBoxKey.aiSummaryTextModel),
      GStorage.setting.delete(SettingBoxKey.aiSummaryMultimodalModel),
    ]);
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AI summary provider settings', () {
    test('baseUrl apiKey textModel and multimodalModel persist independently', () async {
      await Future.wait([
        GStorage.setting.put(
          SettingBoxKey.aiSummaryBaseUrl,
          'https://summary.example.com/v1',
        ),
        GStorage.setting.put(SettingBoxKey.aiSummaryApiKey, 'sk-initial'),
        GStorage.setting.put(SettingBoxKey.aiSummaryTextModel, 'qwen-text'),
        GStorage.setting.put(
          SettingBoxKey.aiSummaryMultimodalModel,
          'qwen-video',
        ),
      ]);

      expect(Pref.aiSummaryBaseUrl, 'https://summary.example.com/v1');
      expect(Pref.aiSummaryApiKey, 'sk-initial');
      expect(Pref.aiSummaryTextModel, 'qwen-text');
      expect(Pref.aiSummaryMultimodalModel, 'qwen-video');

      await GStorage.setting.put(
        SettingBoxKey.aiSummaryBaseUrl,
        'https://summary.example.com/v2',
      );
      expect(Pref.aiSummaryBaseUrl, 'https://summary.example.com/v2');
      expect(
        Pref.aiSummaryApiKey,
        'sk-initial',
        reason: 'Updating baseUrl must not overwrite apiKey.',
      );
      expect(
        Pref.aiSummaryTextModel,
        'qwen-text',
        reason: 'Updating baseUrl must not overwrite textModel.',
      );
      expect(
        Pref.aiSummaryMultimodalModel,
        'qwen-video',
        reason: 'Updating baseUrl must not overwrite multimodalModel.',
      );

      await GStorage.setting.put(SettingBoxKey.aiSummaryApiKey, 'sk-rotated');
      expect(Pref.aiSummaryApiKey, 'sk-rotated');
      expect(
        Pref.aiSummaryBaseUrl,
        'https://summary.example.com/v2',
        reason: 'Updating apiKey must not overwrite baseUrl.',
      );
      expect(Pref.aiSummaryTextModel, 'qwen-text');
      expect(Pref.aiSummaryMultimodalModel, 'qwen-video');

      await GStorage.setting.put(
        SettingBoxKey.aiSummaryTextModel,
        'deepseek-text',
      );
      expect(Pref.aiSummaryTextModel, 'deepseek-text');
      expect(
        Pref.aiSummaryApiKey,
        'sk-rotated',
        reason: 'Updating textModel must not overwrite apiKey.',
      );
      expect(
        Pref.aiSummaryMultimodalModel,
        'qwen-video',
        reason: 'Updating textModel must not overwrite multimodalModel.',
      );

      await GStorage.setting.put(
        SettingBoxKey.aiSummaryMultimodalModel,
        'gemini-video',
      );
      expect(Pref.aiSummaryMultimodalModel, 'gemini-video');
      expect(Pref.aiSummaryBaseUrl, 'https://summary.example.com/v2');
      expect(Pref.aiSummaryApiKey, 'sk-rotated');
      expect(Pref.aiSummaryTextModel, 'deepseek-text');
    });
  });
}
