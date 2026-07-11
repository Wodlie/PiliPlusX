import 'dart:io';

import 'package:PiliPlus/pages/setting/pages/ai_prompt_config.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [AiPromptConfigPage] — validation of empty prompts and
/// round-trip persistence of prompt texts and embeddings via [Pref].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_prompt_config_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() async {
    // Reset all prompt-related prefs before each test.
    await GStorage.setting.delete(SettingBoxKey.aiPromptMalicious);
    await GStorage.setting.delete(SettingBoxKey.aiPromptHighRisk);
    await GStorage.setting.delete(SettingBoxKey.aiPromptNormal);
    await GStorage.setting.delete(SettingBoxKey.aiTextEmbeddings);
    await GStorage.setting.delete(SettingBoxKey.aiModelDownloaded);
  });

  tearDown(() {
    // Dismiss any lingering SmartDialog toast overlay so it does not
    // interfere with subsequent tests.
    SmartDialog.dismiss();
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  });

  group('validation', () {
    testWidgets('empty prompts prevent save and leave prior values intact', (
      tester,
    ) async {
      // Pre-set some existing values to verify they don't change.
      Pref.aiPromptMalicious = 'original malicious';
      Pref.aiPromptHighRisk = 'original high-risk';
      Pref.aiPromptNormal = 'original normal';

      await tester.pumpWidget(
        const MaterialApp(home: AiPromptConfigPage()),
      );
      await tester.pump();

      // Verify the page structure before interaction.
      expect(find.text('MALICIOUS'), findsOneWidget);
      expect(find.text('high-risk'), findsOneWidget);
      expect(find.text('normal'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);

      // Clear all three text fields.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));

      await tester.enterText(fields.at(0), '');
      await tester.enterText(fields.at(1), '');
      await tester.enterText(fields.at(2), '');
      await tester.pump();

      // Tap the "保存" button.
      await tester.tap(find.text('保存'));
      await tester.pump();

      // Original values must be unchanged (save aborted because prompts
      // were empty — toast '提示词不能为空' is shown via SmartDialog).
      expect(Pref.aiPromptMalicious, 'original malicious');
      expect(Pref.aiPromptHighRisk, 'original high-risk');
      expect(Pref.aiPromptNormal, 'original normal');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('Pref', () {
    test('aiPromptMalicious persists round-trip', () async {
      await GStorage.setting.put(
        SettingBoxKey.aiPromptMalicious,
        'malicious content, harmful image',
      );
      expect(Pref.aiPromptMalicious, 'malicious content, harmful image');

      await GStorage.setting.put(SettingBoxKey.aiPromptMalicious, 'custom');
      expect(Pref.aiPromptMalicious, 'custom');
    });

    test('aiPromptHighRisk persists round-trip', () async {
      await GStorage.setting.put(
        SettingBoxKey.aiPromptHighRisk,
        'high risk content, potentially unsafe',
      );
      expect(
        Pref.aiPromptHighRisk,
        'high risk content, potentially unsafe',
      );

      await GStorage.setting.put(SettingBoxKey.aiPromptHighRisk, 'custom');
      expect(Pref.aiPromptHighRisk, 'custom');
    });

    test('aiPromptNormal persists round-trip', () async {
      await GStorage.setting.put(
        SettingBoxKey.aiPromptNormal,
        'normal content, safe image',
      );
      expect(Pref.aiPromptNormal, 'normal content, safe image');

      await GStorage.setting.put(SettingBoxKey.aiPromptNormal, 'custom');
      expect(Pref.aiPromptNormal, 'custom');
    });

    test('aiTextEmbeddings persists round-trip', () async {
      final embeddings = <double>[0.1, 0.2, 0.3, 0.4, 0.5];
      await GStorage.setting.put(
        SettingBoxKey.aiTextEmbeddings,
        embeddings,
      );
      expect(Pref.aiTextEmbeddings, embeddings);

      final empty = <double>[];
      await GStorage.setting.put(SettingBoxKey.aiTextEmbeddings, empty);
      expect(Pref.aiTextEmbeddings, empty);
    });

    test('aiModelDownloaded checked before save', () async {
      await GStorage.setting.put(SettingBoxKey.aiModelDownloaded, false);
      expect(Pref.aiModelDownloaded, isFalse);

      await GStorage.setting.put(SettingBoxKey.aiModelDownloaded, true);
      expect(Pref.aiModelDownloaded, isTrue);
    });
  });
}
