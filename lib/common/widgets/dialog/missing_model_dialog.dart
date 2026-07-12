import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Dialog shown when AI moderation is enabled but model files are missing.
class MissingModelDialog {
  /// Check condition and show dialog if needed.
  ///
  /// Returns `false` in all cases (dialog is shown asynchronously via
  /// post-frame callback). Safe to call during [Widget.build].
  static bool checkAndShow(BuildContext context) {
    if (!Pref.enableAiImageModeration) return false;
    if (_shownThisSession) return false;
    // Never configured a HF URL — no model expected.
    if (Pref.aiModelRepoUrl.isEmpty) return false;

    // Schedule async check — don't block the UI
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final hasFiles = await AiModelStorage.hasModelFiles();
      if (!hasFiles && context.mounted) {
        _shownThisSession = true;
        showMissingModelDialog(context);
      }
    });
    return false;
  }

  @visibleForTesting
  static bool get hasShownThisSession => _shownThisSession;

  static bool _shownThisSession = false;

  /// Reset the per-session flag so the dialog can be shown again.
  /// Useful in tests or when the user toggles AI moderation off/on.
  static void resetSessionFlag() {
    _shownThisSession = false;
  }

  /// Display the model-missing dialog. Not dismissible by tapping outside.
  static Future<void> showMissingModelDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('AI模型文件缺失'),
        content: const Text(
          '模型文件未找到。请重新下载或暂时关闭AI功能。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Pref.enableAiImageModeration = false;
              Navigator.pop(ctx);
              SmartDialog.showToast('已关闭AI功能');
            },
            child: const Text('关闭AI功能'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Get.toNamed('/aiImageModeration');
            },
            child: const Text('重新下载'),
          ),
        ],
      ),
    );
  }
}
