import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages AI model files stored in `{getApplicationDocumentsDirectory()}/ai_models/`.
///
/// Provides helpers to detect, locate, enumerate, and delete model and
/// tokenizer files used by the CLIP-based image moderation pipeline.
abstract final class AiModelStorage {
  // ── Directory names ─────────────────────────────────────────────────
  static const _modelsDirName = 'ai_models';
  static const _tokenizerDirName = 'tokenizer';

  // ── Known model file names in priority order ────────────────────────
  // Vision encoder files (first match wins).
  static const _visionFileNames = <String>[
    'vision_model.onnx',
    'image_encoder.onnx',
    'vision_model.tflite',
    'image_encoder.tflite',
  ];

  // Text encoder files (first match wins).
  static const _textFileNames = <String>[
    'text_model.onnx',
    'text_encoder.onnx',
    'text_model.tflite',
    'text_encoder.tflite',
  ];

  // Tokenizer files (key = preferred single file; fallback pair).
  static const _tokenizerSingleFiles = <String>['tokenizer.json'];
  static const _tokenizerVocabFile = 'vocab.json';
  static const _tokenizerMergesFile = 'merges.txt';

  // ── Visible-for-testing override ────────────────────────────────────
  @visibleForTesting
  static String? debugBasePath;

  // ── Path helpers ────────────────────────────────────────────────────
  static Future<String> get _docsDir async {
    if (debugBasePath != null) return debugBasePath!;
    return (await getApplicationDocumentsDirectory()).path;
  }

  /// Root directory for all AI model files.
  static Future<String> get modelsDir async =>
      p.join(await _docsDir, _modelsDirName);

  /// Directory for tokenizer files (nested under [modelsDir]).
  static Future<String> get tokenizerDir async =>
      p.join(await modelsDir, _tokenizerDirName);

  // ── File discovery helpers ──────────────────────────────────────────
  /// Returns the path of the first existing file in [candidates] under
  /// [modelsDir], or `null` if none exist.
  static Future<String?> _firstExisting(Iterable<String> candidates) async {
    final base = await modelsDir;
    for (final name in candidates) {
      final file = File(p.join(base, name));
      if (await file.exists()) return file.path;
    }
    return null;
  }

  // ── Public API ──────────────────────────────────────────────────────

  /// Check if any model or tokenizer files exist on disk.
  static Future<bool> hasModelFiles() async {
    final dir = Directory(await modelsDir);
    if (!await dir.exists()) return false;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) return true;
    }
    return false;
  }

  /// Check if both a vision encoder and a text encoder file exist on disk.
  static Future<bool> hasBothEncoders() async {
    final vision = await getVisionPath();
    final text = await getTextPath();
    return vision != null && text != null;
  }

  /// Check if all files required by the AI pipeline are present.
  static Future<bool> hasAllRequiredFiles() async {
    final vision = await getVisionPath();
    final text = await getTextPath();
    return vision != null && text != null && await hasTokenizer();
  }

  /// Auto-detect model format by scanning files for known extensions.
  ///
  /// Returns `'onnx'`, `'tflite'`, or `''` (empty string if undetermined).
  static Future<String> detectFormat() async {
    final base = await modelsDir;
    final dir = Directory(base);
    if (!await dir.exists()) return '';

    await for (final entity in dir.list(recursive: false)) {
      if (entity is File) {
        final name = entity.path;
        if (name.endsWith('.onnx')) return 'onnx';
        if (name.endsWith('.tflite')) return 'tflite';
      }
    }
    return '';
  }

  /// Returns the path to a vision encoder model file, or `null` if missing.
  static Future<String?> getVisionPath() async =>
      _firstExisting(_visionFileNames);

  /// Returns the path to a text encoder model file, or `null` if missing.
  static Future<String?> getTextPath() async => _firstExisting(_textFileNames);

  /// Returns `true` if a tokenizer file is available.
  ///
  /// Checks for `tokenizer.json` first, then `vocab.json` + `merges.txt`.
  static Future<bool> hasTokenizer() async {
    final base = await tokenizerDir;
    for (final name in _tokenizerSingleFiles) {
      if (await File(p.join(base, name)).exists()) return true;
    }
    final vocabExists = await File(p.join(base, _tokenizerVocabFile)).exists();
    final mergesExists = await File(
      p.join(base, _tokenizerMergesFile),
    ).exists();
    return vocabExists && mergesExists;
  }

  /// Delete all AI model files (models + tokenizer) from disk.
  ///
  /// This removes the entire `ai_models/` directory tree.
  static Future<void> deleteAllModels() async {
    final dir = Directory(await modelsDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
