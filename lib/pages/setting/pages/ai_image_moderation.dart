import 'dart:io';

import 'package:PiliPlus/pages/setting/widgets/normal_item.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/ai_image_moderation_service.dart';
import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/hf_model_downloader.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class AiImageModerationPage extends StatefulWidget {
  const AiImageModerationPage({super.key});

  @override
  State<AiImageModerationPage> createState() => _AiImageModerationPageState();
}

class _AiImageModerationPageState extends State<AiImageModerationPage> {
  bool _checkingFiles = true;
  bool _hasTokenizer = false;
  bool _hasVision = false;
  bool _hasText = false;
  bool _hasPreprocessorConfig = false;
  bool _hasTokenizerConfig = false;

  @override
  void initState() {
    super.initState();
    _refreshFileStatus();
  }

  Future<void> _refreshFileStatus() async {
    if (!mounted) return;
    final hasTokenizer = await AiModelStorage.hasTokenizer();
    final hasVision = await AiModelStorage.getVisionPath() != null;
    final hasText = await AiModelStorage.getTextPath() != null;
    final hasPreprocessorConfig = await AiModelStorage.hasPreprocessorConfig();
    final hasTokenizerConfig = await AiModelStorage.hasTokenizerConfig();
    if (!mounted) return;
    setState(() {
      _hasTokenizer = hasTokenizer;
      _hasVision = hasVision;
      _hasText = hasText;
      _hasPreprocessorConfig = hasPreprocessorConfig;
      _hasTokenizerConfig = hasTokenizerConfig;
      _checkingFiles = false;
    });
  }

  Future<void> _updateModelReadyFlag() async {
    Pref.aiModelDownloaded = await AiModelStorage.hasAllRequiredFiles();
  }

  @override
  void dispose() {
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

  // ── Per-file model management ─────────────────────────────────────────

  String _fileTypeLabel(AiModelFileType type) {
    return switch (type) {
      AiModelFileType.tokenizer => '分词器 (tokenizer.json)',
      AiModelFileType.vision => '视觉编码器 (vision_model.*)',
      AiModelFileType.text => '文本编码器 (text_model.*)',
      AiModelFileType.preprocessorConfig =>
        '图像预处理配置 (preprocessor_config.json)（可选）',
      AiModelFileType.tokenizerConfig => '分词器配置 (tokenizer_config.json)（可选）',
    };
  }

  List<String> _allowedExtensions(AiModelFileType type) {
    return switch (type) {
      AiModelFileType.tokenizer => const ['json'],
      AiModelFileType.vision => const ['onnx', 'tflite'],
      AiModelFileType.text => const ['onnx', 'tflite'],
      AiModelFileType.preprocessorConfig => const ['json'],
      AiModelFileType.tokenizerConfig => const ['json'],
    };
  }

  Future<void> _pickLocalFile(AiModelFileType type) async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions(type),
    );
    if (result == null) return;

    SmartDialog.showLoading(msg: '正在复制文件...');
    try {
      final saved = await HfModelDownloader.copyFromLocal(
        File(result.xFile.path),
        type,
      );
      SmartDialog.dismiss();
      if (saved == null) {
        SmartDialog.showToast('文件复制失败，请检查文件格式');
        return;
      }
      await _updateModelReadyFlag();
      await _refreshFileStatus();
      switch (type) {
        case AiModelFileType.vision:
        case AiModelFileType.preprocessorConfig:
          AiImageModerationService.disposeSession();
          AiImageModerationService.invalidateCache();
        case AiModelFileType.text:
          AiImageModerationService.disposeSession();
          AiImageModerationService.invalidateCache();
          AiImageModerationService.clearTextEmbeddings();
        case AiModelFileType.tokenizer:
        case AiModelFileType.tokenizerConfig:
          AiImageModerationService.clearTextEmbeddings();
      }
      SmartDialog.showToast('${_fileTypeLabel(type)}已导入');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('导入失败: $e');
    }
  }

  Future<void> _showNetworkUrlDialog(AiModelFileType type) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('下载${_fileTypeLabel(type)}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://hf-mirror.com/user/repo/resolve/main/file.onnx',
            border: OutlineInputBorder(),
            helperText: '支持 HuggingFace /resolve/main/ 直连地址',
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
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (url != null && url.isNotEmpty) {
      await _downloadNetworkFile(url, type);
    }
  }

  Future<void> _downloadNetworkFile(
    String url,
    AiModelFileType type,
  ) async {
    final progressNotifier = ValueNotifier<double>(0.0);
    final statusNotifier = ValueNotifier<String>('正在准备下载...');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text('下载${_fileTypeLabel(type)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: progressNotifier,
                builder: (context, value, child) =>
                    LinearProgressIndicator(value: value),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (context, value, child) => Text(value),
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
      final saved = await HfModelDownloader.downloadSingleFile(
        url,
        type,
        onProgress: (p, status) {
          progressNotifier.value = p;
          statusNotifier.value = status;
        },
      );

      if (mounted) Navigator.of(context).pop();

      if (saved != null) {
        await _updateModelReadyFlag();
        await _refreshFileStatus();
        switch (type) {
          case AiModelFileType.vision:
          case AiModelFileType.preprocessorConfig:
            AiImageModerationService.disposeSession();
            AiImageModerationService.invalidateCache();
          case AiModelFileType.text:
            AiImageModerationService.disposeSession();
            AiImageModerationService.invalidateCache();
            AiImageModerationService.clearTextEmbeddings();
          case AiModelFileType.tokenizer:
          case AiModelFileType.tokenizerConfig:
            AiImageModerationService.clearTextEmbeddings();
        }
        SmartDialog.showToast('${_fileTypeLabel(type)}下载完成');
      } else {
        SmartDialog.showToast('下载失败: 请检查地址是否有效');
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      SmartDialog.showToast('下载失败: $e');
    } finally {
      progressNotifier.dispose();
      statusNotifier.dispose();
    }
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
    final ready = _hasTokenizer && _hasVision && _hasText;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (_checkingFiles)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              ready ? Icons.check_circle : Icons.error,
              color: ready ? Colors.green : theme.colorScheme.error,
              size: 20,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ready ? '模型已就绪 (ONNX/TFLite)' : '模型文件不完整',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: ready ? Colors.green : theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Build per-file model files section ─────────────────────────────────
  Widget _buildModelFilesSection(ThemeData theme) {
    final files = [
      (
        AiModelFileType.tokenizer,
        _hasTokenizer,
        'tokenizer.json',
      ),
      (
        AiModelFileType.vision,
        _hasVision,
        'vision_model.onnx/tflite',
      ),
      (
        AiModelFileType.text,
        _hasText,
        'text_model.onnx/tflite',
      ),
      (
        AiModelFileType.preprocessorConfig,
        _hasPreprocessorConfig,
        'preprocessor_config.json',
      ),
      (
        AiModelFileType.tokenizerConfig,
        _hasTokenizerConfig,
        'tokenizer_config.json',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '模型文件',
            style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
          ),
        ),
        const Divider(height: 1),
        ...files.expand((file) {
          final (type, exists, canonicalName) = file;
          return [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    exists ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: exists ? Colors.green : theme.colorScheme.outline,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _fileTypeLabel(type),
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          exists ? '已导入' : canonicalName,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _pickLocalFile(type),
                    child: const Text('从本地选取'),
                  ),
                  TextButton(
                    onPressed: () => _showNetworkUrlDialog(type),
                    child: const Text('从网络下载'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ];
        }),
      ],
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

          // Section: Model files
          _buildModelFilesSection(theme),
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
            title: '模型输入尺寸（配置缺失时）',
            getSubtitle: () =>
                '当前: ${Pref.aiModelInputSize}px\n配置文件存在时优先使用配置文件',
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
