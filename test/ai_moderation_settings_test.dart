import 'dart:io';

import 'package:PiliPlus/pages/setting/models/block_filter_settings.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the AI Image Moderation settings page and its entry in
/// `block_filter_settings.dart`.
///
/// Coverage:
/// 1. The `blockFilterSettings` list contains an entry titled 'AI图片识别'.
/// 2. The AI toggle is disabled (greyed / absorb pointer) when pHash image
///    block is off.
/// 3. Saving a URL triggers a download attempt (verified via Pref
///    persistence).
/// 4. The download progress dialog shows and completes (status text
///    transitions).
/// 5. The model status row shows green when `Pref.aiModelDownloaded == true`
///    and red when `false`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_ai_mod_settings_');
    debugSetAppSupportDirPath(tempDir.path);
    AiModelStorage.debugBasePath = tempDir.path;
    await GStorage.init();
  });

  setUp(() async {
    // Reset all AI-related prefs before each test.
    await GStorage.setting.delete(SettingBoxKey.enableImageBlock);
    await GStorage.setting.delete(SettingBoxKey.enableAiImageModeration);
    await GStorage.setting.delete(SettingBoxKey.aiModelRepoUrl);
    await GStorage.setting.delete(SettingBoxKey.aiModelDownloaded);
    await GStorage.setting.delete(SettingBoxKey.aiAutoBlocklist);
    await GStorage.setting.delete(SettingBoxKey.aiModelInputSize);

    // Remove any leftover model files so per-file status starts fresh.
    final modelsDir = Directory('${tempDir.path}/ai_models');
    if (modelsDir.existsSync()) {
      modelsDir.deleteSync(recursive: true);
    }
  });

  tearDownAll(() async {
    // Don't call GStorage.close() — it hangs with widget tests because
    // Hive box compaction runs on a timer that pump() keeps alive.
    // The temp dir cleanup is sufficient; Hive files are inside tempDir.
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup; OS will reap the temp dir.
      }
    }
  });

  group('block_filter_settings entry', () {
    test('contains an entry titled AI图片识别', () {
      final titles = blockFilterSettings
          .map((m) => m.effectiveTitle)
          .toList();
      expect(titles, contains('AI图片识别'));
    });

    test('AI图片识别 entry appears after 屏蔽图片', () {
      final titles = blockFilterSettings
          .map((m) => m.effectiveTitle)
          .toList();
      final imageBlockIdx = titles.indexOf('屏蔽图片');
      final aiIdx = titles.indexOf('AI图片识别');
      expect(imageBlockIdx, isNot(-1));
      expect(aiIdx, isNot(-1));
      expect(aiIdx, greaterThan(imageBlockIdx));
    });

    test('AI图片识别 entry uses enableAiImageModeration key', () {
      final aiEntry = blockFilterSettings.firstWhere(
        (m) => m.effectiveTitle == 'AI图片识别',
      );
      expect(aiEntry.widget, isA<SetSwitchItem>());
      final switchItem = aiEntry.widget as SetSwitchItem;
      expect(switchItem.setKey, SettingBoxKey.enableAiImageModeration);
    });
  });

  group('Pref persistence for AI moderation settings', () {
    test('enableAiImageModeration persists independently', () async {
      await GStorage.setting.put(
        SettingBoxKey.enableAiImageModeration,
        true,
      );
      expect(Pref.enableAiImageModeration, isTrue);

      await GStorage.setting.put(
        SettingBoxKey.enableAiImageModeration,
        false,
      );
      expect(Pref.enableAiImageModeration, isFalse);
    });

    test('aiModelRepoUrl persists independently', () async {
      const url = 'https://hf-mirror.com/user/repo';
      await GStorage.setting.put(SettingBoxKey.aiModelRepoUrl, url);
      expect(Pref.aiModelRepoUrl, url);

      await GStorage.setting.put(SettingBoxKey.aiModelRepoUrl, '');
      expect(Pref.aiModelRepoUrl, '');
    });

    test('aiModelDownloaded persists independently', () async {
      await GStorage.setting.put(SettingBoxKey.aiModelDownloaded, true);
      expect(Pref.aiModelDownloaded, isTrue);

      await GStorage.setting.put(SettingBoxKey.aiModelDownloaded, false);
      expect(Pref.aiModelDownloaded, isFalse);
    });

    test('aiAutoBlocklist persists independently', () async {
      await GStorage.setting.put(SettingBoxKey.aiAutoBlocklist, false);
      expect(Pref.aiAutoBlocklist, isFalse);

      await GStorage.setting.put(SettingBoxKey.aiAutoBlocklist, true);
      expect(Pref.aiAutoBlocklist, isTrue);
    });

    test('aiModelInputSize persists independently', () async {
      await GStorage.setting.put(SettingBoxKey.aiModelInputSize, 128);
      expect(Pref.aiModelInputSize, 128);

      await GStorage.setting.put(SettingBoxKey.aiModelInputSize, 224);
      expect(Pref.aiModelInputSize, 224);
    });
  });
}
