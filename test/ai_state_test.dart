import 'dart:io';

import 'package:PiliPlus/utils/ai_image_state.dart';
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
      'pili_ai_state_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDown(() async {
    await Future.wait([
      GStorage.setting.delete(SettingBoxKey.enableAiImageModeration),
      GStorage.setting.delete(SettingBoxKey.aiModelRepoUrl),
      GStorage.setting.delete(SettingBoxKey.aiModelDownloaded),
      GStorage.setting.delete(SettingBoxKey.aiModelFormat),
      GStorage.setting.delete(SettingBoxKey.aiModelInputSize),
      GStorage.setting.delete(SettingBoxKey.aiPromptMalicious),
      GStorage.setting.delete(SettingBoxKey.aiPromptHighRisk),
      GStorage.setting.delete(SettingBoxKey.aiPromptNormal),
      GStorage.setting.delete(SettingBoxKey.aiTextEmbeddings),
      GStorage.setting.delete(SettingBoxKey.aiAutoBlocklist),
    ]);
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AiImageState enum', () {
    test('has 4 values', () {
      expect(AiImageState.values.length, 4);
    });

    test('contains blocked', () {
      expect(AiImageState.values, contains(AiImageState.blocked));
    });

    test('contains highRisk', () {
      expect(AiImageState.values, contains(AiImageState.highRisk));
    });

    test('contains normal', () {
      expect(AiImageState.values, contains(AiImageState.normal));
    });

    test('contains pending', () {
      expect(AiImageState.values, contains(AiImageState.pending));
    });
  });

  group('AI image moderation Pref defaults', () {
    test('enableAiImageModeration defaults to false', () {
      expect(Pref.enableAiImageModeration, false);
    });

    test('aiModelRepoUrl defaults to empty string', () {
      expect(Pref.aiModelRepoUrl, '');
    });

    test('aiModelDownloaded defaults to false', () {
      expect(Pref.aiModelDownloaded, false);
    });

    test('aiModelFormat defaults to empty string', () {
      expect(Pref.aiModelFormat, '');
    });

    test('aiModelInputSize defaults to 224', () {
      expect(Pref.aiModelInputSize, 224);
    });

    test('aiPromptMalicious defaults to malicious content prompt', () {
      expect(Pref.aiPromptMalicious, 'malicious content, harmful image');
    });

    test('aiPromptHighRisk defaults to high risk prompt', () {
      expect(Pref.aiPromptHighRisk, 'high risk content, potentially unsafe');
    });

    test('aiPromptNormal defaults to normal content prompt', () {
      expect(Pref.aiPromptNormal, 'normal content, safe image');
    });

    test('aiTextEmbeddings defaults to empty list', () {
      expect(Pref.aiTextEmbeddings, isEmpty);
    });

    test('aiAutoBlocklist defaults to true', () {
      expect(Pref.aiAutoBlocklist, true);
    });
  });

  group('AI image moderation Pref round-trip', () {
    test('enableAiImageModeration can be written and read back', () async {
      Pref.enableAiImageModeration = true;
      expect(Pref.enableAiImageModeration, true);
      Pref.enableAiImageModeration = false;
      expect(Pref.enableAiImageModeration, false);
    });

    test('aiModelRepoUrl can be written and read back', () async {
      Pref.aiModelRepoUrl = 'https://model.example.com/model.tflite';
      expect(Pref.aiModelRepoUrl, 'https://model.example.com/model.tflite');
    });

    test('aiModelDownloaded can be written and read back', () async {
      Pref.aiModelDownloaded = true;
      expect(Pref.aiModelDownloaded, true);
    });

    test('aiModelFormat can be written and read back', () async {
      Pref.aiModelFormat = 'tflite';
      expect(Pref.aiModelFormat, 'tflite');
    });

    test('aiModelInputSize can be written and read back', () async {
      Pref.aiModelInputSize = 128;
      expect(Pref.aiModelInputSize, 128);
    });

    test('aiPromptMalicious can be written and read back', () async {
      Pref.aiPromptMalicious = 'custom malicious prompt';
      expect(Pref.aiPromptMalicious, 'custom malicious prompt');
    });

    test('aiPromptHighRisk can be written and read back', () async {
      Pref.aiPromptHighRisk = 'custom high risk prompt';
      expect(Pref.aiPromptHighRisk, 'custom high risk prompt');
    });

    test('aiPromptNormal can be written and read back', () async {
      Pref.aiPromptNormal = 'custom normal prompt';
      expect(Pref.aiPromptNormal, 'custom normal prompt');
    });

    test('aiTextEmbeddings can be written and read back', () async {
      final embeddings = [0.1, 0.2, 0.3, 0.4, 0.5];
      Pref.aiTextEmbeddings = embeddings;
      expect(Pref.aiTextEmbeddings, embeddings);
    });

    test('aiAutoBlocklist can be written and read back', () async {
      Pref.aiAutoBlocklist = false;
      expect(Pref.aiAutoBlocklist, false);
      Pref.aiAutoBlocklist = true;
      expect(Pref.aiAutoBlocklist, true);
    });

    test('keys persist independently', () async {
      await Future.wait([
        GStorage.setting.put(SettingBoxKey.enableAiImageModeration, true),
        GStorage.setting.put(SettingBoxKey.aiAutoBlocklist, false),
        GStorage.setting.put(SettingBoxKey.aiModelInputSize, 512),
      ]);

      expect(
        Pref.enableAiImageModeration,
        true,
        reason: 'enableAiImageModeration must persist',
      );
      expect(
        Pref.aiAutoBlocklist,
        false,
        reason: 'aiAutoBlocklist must persist independently',
      );
      expect(
        Pref.aiModelInputSize,
        512,
        reason: 'aiModelInputSize must persist independently',
      );
    });
  });
}
