import 'dart:io';

import 'package:PiliPlus/pages/setting/widgets/normal_item.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/common/widgets/dialog/missing_model_dialog.dart';
import 'package:PiliPlus/utils/ai_image_moderation_service.dart';
import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/hf_model_downloader.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class AiImageModerationPage extends StatefulWidget {
  const AiImageModerationPage({super.key});

  @override
  State<AiImageModerationPage> createState() => _AiImageModerationPageState();
}

class _AiImageModerationPageState extends State<AiImageModerationPage> {
  late final TextEditingController _urlController;
  bool _modelReady = false;
  bool _checkingFiles = true;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: Pref.aiModelRepoUrl);
    _verifyModelFiles();
  }

  Future<void> _verifyModelFiles() async {
    if (!mounted) return;
    final ready = await AiModelStorage.hasModelFiles();
    if (!mounted) return;
    setState(() {
      _modelReady = ready;
      _checkingFiles = false;
    });
    // After model check, show dialog if AI is enabled but models missing.
    if (mounted &&
        Pref.enableAiImageModeration &&
        Pref.aiModelRepoUrl.isNotEmpty &&
        !ready) {
      MissingModelDialog.showMissingModelDialog(context);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // ── iOS version check for ONNX warning ────────────────────────────────
  bool get _showIosOnnxWarning {
    if (!Platform.isIOS) return false;
    // ONNX Runtime requires iOS 16+. We can't reliably read the exact OS
    // version in a pure Dart test environment, so we approximate: show the
    // warning on iOS unconditionally — the user can dismiss it. In production
    // a more precise check could use device_info_plus, but that dependency
    // is not guaranteed to be available here.
    return true;
  }

  /// Download with a self-contained progress dialog that uses a
  /// [ValueNotifier] to drive updates without needing external setState.
  Future<void> _startDownloadWithNotifier() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      SmartDialog.showToast('请输入HuggingFace仓库地址');
      return;
    }

    Pref.aiModelRepoUrl = url;

    final progressNotifier = ValueNotifier<double>(0.0);
    final statusNotifier = ValueNotifier<String>('正在准备下载...');

    // Show a non-dismissible progress dialog driven by ValueNotifiers.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('下载模型'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: progressNotifier,
                builder: (_, value, __) =>
                    LinearProgressIndicator(value: value),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (_, value, __) => Text(value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '取消',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          ],
        );
      },
    );

    try {
      final success = await HfModelDownloader.downloadFromRepo(
        url,
        onProgress: (p, status) {
          progressNotifier.value = p;
          // Translate internal English statuses to user-facing Chinese.
          statusNotifier.value = _translateStatus(status, p);
        },
      );

      if (mounted) Navigator.of(context).pop(); // close dialog

      if (success) {
        setState(() {
          _modelReady = true;
          Pref.aiModelDownloaded = true;
        });
        // Replacing the model invalidates all previous cached results.
        AiImageModerationService.invalidateCache();
        SmartDialog.showToast('模型下载完成');
      } else {
        SmartDialog.showToast('下载失败: 模型文件不完整');
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      SmartDialog.showToast('下载失败: $e');
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
  }

  /// Map internal download statuses to Chinese display text with percentage.
  String _translateStatus(String internal, double progress) {
    final pct = (progress * 100).round().clamp(0, 100);
    if (internal.contains('tokenizer')) {
      return '正在下载 tokenizer...';
    }
    if (internal.contains('vision')) {
      return '正在下载视觉模型 ($pct%)...';
    }
    if (internal.contains('text')) {
      return '正在下载文本模型 ($pct%)...';
    }
    if (internal.contains('complete')) {
      return '下载完成 ✓';
    }
    if (internal.contains('incomplete')) {
      return '下载不完整 — 缺少文件';
    }
    if (internal.contains('Invalid')) {
      return '无效的HuggingFace地址';
    }
    return internal;
  }

  // ── Model input size dialog ────────────────────────────────────────────
  Future<void> _showInputSizeDialog() async {
    final controller = TextEditingController(
      text: Pref.aiModelInputSize.toString(),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('模型输入尺寸'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入整数，默认224',
            suffixText: 'px',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              Navigator.pop(ctx, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result > 0) {
      Pref.aiModelInputSize = result;
      SmartDialog.showToast('已保存');
      setState(() {});
    }
  }

  // ── Build model status row ─────────────────────────────────────────────
  Widget _buildModelStatusRow(ThemeData theme) {
    final ready = _modelReady;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle : Icons.error,
            color: ready ? Colors.green : theme.colorScheme.error,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ready ? '模型已就绪 (ONNX/TFLite)' : '未下载模型',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ready ? Colors.green : theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Build HF repo URL row ───────────────────────────────────────────────
  Widget _buildUrlRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HuggingFace 仓库地址',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              hintText: 'https://huggingface.co/user/repo 或镜像站地址',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              onPressed: _startDownloadWithNotifier,
              child: const Text('保存并下载'),
            ),
          ),
        ],
      ),
    );
  }

  // ── iOS ONNX warning row ────────────────────────────────────────────────
  Widget _buildIosWarningRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: theme.colorScheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ONNX需要iOS 16+，请使用TFLite格式',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageBlockEnabled = Pref.enableImageBlock;

    return Scaffold(
      appBar: AppBar(title: const Text('AI图片识别')),
      body: ListView(
        children: [
          // Section: AI moderation toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'AI识别设置',
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
            ),
          ),
          const Divider(height: 1),
          Opacity(
            opacity: imageBlockEnabled ? 1.0 : 0.4,
            child: AbsorbPointer(
              absorbing: !imageBlockEnabled,
              child: SetSwitchItem(
                title: '启用AI自动识别',
                subtitle: imageBlockEnabled ? '使用CLIP模型自动识别评论图片内容' : '需先启用屏蔽图片',
                setKey: SettingBoxKey.enableAiImageModeration,
                defaultVal: false,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const Divider(height: 1),

          // Section: Model download
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '模型下载',
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
            ),
          ),
          const Divider(height: 1),
          _buildUrlRow(theme),
          const Divider(height: 1),
          _buildModelStatusRow(theme),
          const Divider(height: 1),

          // Section: Advanced settings
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '高级设置',
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
            ),
          ),
          const Divider(height: 1),
          NormalItem(
            title: '设置Prompt',
            subtitle: '配置AI识别的提示词',
            leading: const Icon(Icons.edit_note),
            onTap: (context, setState) => Get.toNamed('/aiPromptConfig'),
          ),
          const Divider(height: 1),
          SetSwitchItem(
            title: 'MALICIOUS自动加入屏蔽列表',
            subtitle: '识别为恶意的图片自动加入pHash屏蔽列表',
            setKey: SettingBoxKey.aiAutoBlocklist,
            defaultVal: true,
            onChanged: (_) => setState(() {}),
          ),
          const Divider(height: 1),
          NormalItem(
            title: '模型输入尺寸',
            getSubtitle: () => '当前: ${Pref.aiModelInputSize}px',
            leading: const Icon(Icons.crop_free),
            onTap: (context, setState) => _showInputSizeDialog(),
          ),
          const Divider(height: 1),

          // iOS-only warning
          if (_showIosOnnxWarning) ...[
            const SizedBox(height: 8),
            _buildIosWarningRow(theme),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
