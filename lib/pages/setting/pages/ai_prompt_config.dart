import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_image_moderation_service.dart';
import 'package:PiliPlus/utils/ai_inference_engine.dart';
import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/clip_similarity.dart';
import 'package:PiliPlus/utils/clip_tokenizer.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// Configuration page for the three AI image-moderation prompts.
///
/// Users edit three prompt texts (MALICIOUS, high-risk, normal). On save,
/// each prompt is tokenized via CLIPTokenizer, encoded through the text
/// encoder (InferenceSession.runText), L2-normalised, and the three 512‑
/// element embeddings are concatenated into a single 1536-element list
/// stored in [Pref.aiTextEmbeddings].
///
/// Encoding runs asynchronously so the UI thread is never blocked.
class AiPromptConfigPage extends StatefulWidget {
  const AiPromptConfigPage({super.key});

  @override
  State<AiPromptConfigPage> createState() => _AiPromptConfigPageState();
}

class _AiPromptConfigPageState extends State<AiPromptConfigPage> {
  late final TextEditingController _maliciousController;
  late final TextEditingController _highRiskController;
  late final TextEditingController _normalController;

  @override
  void initState() {
    super.initState();
    _maliciousController = TextEditingController(text: Pref.aiPromptMalicious);
    _highRiskController = TextEditingController(text: Pref.aiPromptHighRisk);
    _normalController = TextEditingController(text: Pref.aiPromptNormal);
  }

  @override
  void dispose() {
    _maliciousController.dispose();
    _highRiskController.dispose();
    _normalController.dispose();
    super.dispose();
  }

  // ── Save flow ──────────────────────────────────────────────────────────

  Future<void> _save() async {
    final malicious = _maliciousController.text.trim();
    final highRisk = _highRiskController.text.trim();
    final normal = _normalController.text.trim();

    // 1. Validate all three prompts are non-empty.
    if (malicious.isEmpty || highRisk.isEmpty || normal.isEmpty) {
      SmartDialog.showToast('提示词不能为空');
      return;
    }

    // 2. Check model has been downloaded.
    if (!Pref.aiModelDownloaded) {
      SmartDialog.showToast('请先下载模型');
      return;
    }

    // 3. Show loading dialog.
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在编码文本...'),
          ],
        ),
      ),
    );

    try {
      // 4. Load tokenizer & inference session.
      final tokenizerDir = await AiModelStorage.tokenizerDir;
      final tokenizer = await CLIPTokenizer.loadFromPath(tokenizerDir);
      final session = await AiInferenceEngine.create();

      if (session == null) {
        if (mounted) Navigator.of(context).pop();
        final detail = AiInferenceEngine.lastCreateError ?? '请确认模型文件完整且格式正确';
        SmartDialog.showToast('无法创建推理会话: $detail');
        return;
      }

      try {
        // 5a. Tokenize + encode each prompt.
        final embeddings = <Float32List>[];
        for (final text in [malicious, highRisk, normal]) {
          final tokenIds = tokenizer.tokenize(text);
          final rawEmbedding = await session.runText(tokenIds);

          // 5b. L2 normalise.
          double sumSq = 0.0;
          for (int i = 0; i < rawEmbedding.length; i++) {
            sumSq += rawEmbedding[i] * rawEmbedding[i];
          }
          final norm = ClipSimilarity.sqrt(sumSq);
          final normalized = Float32List(rawEmbedding.length);
          for (int i = 0; i < rawEmbedding.length; i++) {
            normalized[i] = norm > 0 ? rawEmbedding[i] / norm : 0.0;
          }
          embeddings.add(normalized);
        }

        // 6. Concat 3×512 → 1536 items.
        final concat = <double>[];
        for (final emb in embeddings) {
          concat.addAll(emb);
        }

        // 7. Persist to Pref.
        Pref.aiTextEmbeddings = concat;
        Pref.aiPromptMalicious = malicious;
        Pref.aiPromptHighRisk = highRisk;
        Pref.aiPromptNormal = normal;

        // 8. Invalidate downstream caches.
        AiImageModerationService.invalidateCache();
      } finally {
        session.dispose();
      }

      // 9. Dismiss loading, report success.
      if (mounted) Navigator.of(context).pop();
      SmartDialog.showToast('保存成功');
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      SmartDialog.showToast('编码失败: $e');
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置Prompt')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPromptField(
            controller: _maliciousController,
            label: 'MALICIOUS',
            indicatorColor: Colors.red,
          ),
          const SizedBox(height: 16),
          _buildPromptField(
            controller: _highRiskController,
            label: 'high-risk',
            indicatorColor: Colors.orange,
          ),
          const SizedBox(height: 16),
          _buildPromptField(
            controller: _normalController,
            label: 'normal',
            indicatorColor: Colors.green,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptField({
    required TextEditingController controller,
    required String label,
    required Color indicatorColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: indicatorColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: 2,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
