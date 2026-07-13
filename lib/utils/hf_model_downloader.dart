import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// Identifies one of the model/configuration files the AI pipeline needs.
enum AiModelFileType {
  tokenizer,
  vision,
  text,
  preprocessorConfig,
  tokenizerConfig,
}

/// Downloads CLIP model and tokenizer files from a HuggingFace repo using
/// Dio with progress reporting and automatic retry.
///
/// Supports both `huggingface.co` and mirror sites like `hf-mirror.com`.
class HfModelDownloader {
  HfModelDownloader._();

  // ── Known file names in download priority order ─────────────────────
  static const _tokenizerPriority = <String>['tokenizer.json'];
  static const _visionPriority = <String>[
    'vision_model.onnx',
    'image_encoder.onnx',
    'vision_model.tflite',
    'image_encoder.tflite',
  ];
  static const _textPriority = <String>[
    'text_model.onnx',
    'text_encoder.onnx',
    'text_model.tflite',
    'text_encoder.tflite',
  ];

  /// The total number of file-groups we may attempt.
  /// 3 groups: tokenizer, vision, text.
  static const int _fileGroupCount = 3;

  /// Max retry attempts per individual file download.
  static const int _maxRetries = 3;

  // ── Public entry-point ──────────────────────────────────────────────

  /// Validates whether [repoUrl] contains the files required by this
  /// downloader. Returns `null` if valid, otherwise a Chinese error message
  /// describing what is missing.
  static Future<String?> validateRepoFiles(String repoUrl) async {
    final base = _parseBase(repoUrl);
    if (base == null) return '无效的 HuggingFace 地址';

    final (host, ownerRepo) = base;
    final apiUrl = 'https://$host/api/models/$ownerRepo';

    try {
      final response = await Dio().get(apiUrl);
      final data = response.data;
      if (data is! Map<String, dynamic>) return '无法解析仓库信息';

      final siblings = data['siblings'] as List<dynamic>?;
      if (siblings == null) return '无法获取仓库文件列表';

      final files = siblings
          .whereType<Map<String, dynamic>>()
          .map((e) => e['rfilename'] as String?)
          .whereType<String>()
          .toSet();

      final hasTokenizer =
          _tokenizerPriority.any(files.contains) ||
          (files.contains('vocab.json') && files.contains('merges.txt'));
      final hasVision = _visionPriority.any(files.contains);
      final hasText = _textPriority.any(files.contains);

      if (hasTokenizer && hasVision && hasText) return null;

      final missing = <String>[];
      if (!hasTokenizer)
        missing.add('tokenizer.json（或 vocab.json + merges.txt）');
      if (!hasVision)
        missing.add('vision_model.onnx/tflite 或 image_encoder.onnx/tflite');
      if (!hasText)
        missing.add('text_model.onnx/tflite 或 text_encoder.onnx/tflite');

      return '该仓库缺少必要文件：${missing.join('、')}';
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return '仓库不存在或无法访问';
      }
      return '检查仓库文件失败：${e.message}';
    } catch (e) {
      return '检查仓库文件失败：$e';
    }
  }

  /// Download all required files from a HuggingFace repo.
  ///
  /// [repoUrl] can be any HuggingFace URL pattern:
  ///   - `https://huggingface.co/username/repo`
  ///   - `https://huggingface.co/username/repo/tree/main`
  ///   - `https://hf-mirror.com/username/repo`
  ///
  /// The method auto-detects the repo owner, name, and base domain, then
  /// attempts known file names in priority order. Already-existing files
  /// are skipped.
  ///
  /// Returns `true` if at least one vision encoder AND one text encoder
  /// were downloaded successfully (tokenizer is preferred but not
  /// strictly required for success).
  ///
  /// [onProgress] is called with a value in `[0.0, 1.0]` and a status
  /// message for UI display.
  static Future<bool> downloadFromRepo(
    String repoUrl, {
    void Function(double progress, String status)? onProgress,
  }) async {
    // 1. Parse URL
    final base = _parseBase(repoUrl);
    if (base == null) {
      onProgress?.call(0.0, 'Invalid HuggingFace URL');
      return false;
    }

    final (host, ownerRepo) = base;
    final downloadBase = 'https://$host/$ownerRepo/resolve/main';

    // 2. Ensure directories exist
    final modelsDir = await AiModelStorage.modelsDir;
    final tokenizerDir = await AiModelStorage.tokenizerDir;
    await Directory(modelsDir).create(recursive: true);
    await Directory(tokenizerDir).create(recursive: true);

    // 3. Track results
    bool visionOk = false;
    bool textOk = false;

    // Track overall progress — we divide the total into [_fileGroupCount]
    // segments, one per file-group.
    int completedGroups = 0;

    // 4. Tokenizer (single file preferred, fallback pair)
    final tokenizerFile = await _downloadFirstExisting(
      downloadBase,
      tokenizerDir,
      _tokenizerPriority,
      onProgress: (groupProgress) {
        _reportGroupProgress(
          onProgress,
          completedGroups,
          groupProgress,
          0,
        );
      },
    );
    if (tokenizerFile == null) {
      // Try vocab.json + merges.txt pair as fallback.
      await _downloadFileWithRetry(
        '$downloadBase/vocab.json',
        p.join(tokenizerDir, 'vocab.json'),
      );
      await _downloadFileWithRetry(
        '$downloadBase/merges.txt',
        p.join(tokenizerDir, 'merges.txt'),
      );
    }
    completedGroups++;

    // 5. Vision encoder
    final visionFile = await _downloadFirstExisting(
      downloadBase,
      modelsDir,
      _visionPriority,
      onProgress: (groupProgress) {
        _reportGroupProgress(
          onProgress,
          completedGroups,
          groupProgress,
          1,
        );
      },
    );
    if (visionFile != null) {
      visionOk = true;
    }
    completedGroups++;

    // 6. Text encoder
    final textFile = await _downloadFirstExisting(
      downloadBase,
      modelsDir,
      _textPriority,
      onProgress: (groupProgress) {
        _reportGroupProgress(
          onProgress,
          completedGroups,
          groupProgress,
          2,
        );
      },
    );
    if (textFile != null) {
      textOk = true;
    }
    completedGroups++;

    // 7. Persist state on partial or full success
    if (visionOk && textOk) {
      final detectedFormat = await AiModelStorage.detectFormat();
      Pref.aiModelDownloaded = true;
      Pref.aiModelFormat = detectedFormat;
      onProgress?.call(1.0, 'Download complete');
      return true;
    }

    if (visionOk || textOk) {
      // Partial download — still safe to use whatever was saved.
      final detectedFormat = await AiModelStorage.detectFormat();
      if (detectedFormat.isNotEmpty) {
        Pref.aiModelDownloaded = true;
        Pref.aiModelFormat = detectedFormat;
      }
    }

    onProgress?.call(
      1.0,
      'Download incomplete — missing files. '
      'Repository must contain: '
      'tokenizer.json (or vocab.json + merges.txt), '
      'vision_model.onnx/tflite, '
      'text_model.onnx/tflite',
    );
    return false;
  }

  // ── Per-file model management ───────────────────────────────────────

  /// Canonical destination name for a picked/downloaded file of [type].
  ///
  /// The extension is preserved so [AiModelStorage] can detect the format.
  static String _canonicalNameFor(AiModelFileType type, String extension) {
    final ext = extension.toLowerCase();
    return switch (type) {
      AiModelFileType.tokenizer => 'tokenizer.$ext',
      AiModelFileType.vision => 'vision_model.$ext',
      AiModelFileType.text => 'text_model.$ext',
      AiModelFileType.preprocessorConfig => 'preprocessor_config.$ext',
      AiModelFileType.tokenizerConfig => 'tokenizer_config.$ext',
    };
  }

  /// Copies a user-picked local file into the app model directory under
  /// a canonical name.
  ///
  /// Returns the saved canonical path on success, `null` on failure.
  static Future<String?> copyFromLocal(
    File source,
    AiModelFileType type,
  ) async {
    // p.extension returns ".onnx" with leading dot. Strip it so that
    // _canonicalNameFor produces "vision_model.onnx" not "vision_model..onnx".
    var ext = p.extension(source.path);
    if (ext.startsWith('.')) ext = ext.substring(1);
    if (ext.isEmpty) return null;

    // Validate JSON for config files before overwriting any existing file.
    if (type == AiModelFileType.preprocessorConfig ||
        type == AiModelFileType.tokenizerConfig) {
      try {
        final content = await source.readAsString();
        json.decode(content); // throws if invalid JSON
      } catch (_) {
        throw FormatException('无效的 JSON 配置文件: ${source.path}');
      }
    }

    final modelsDir = await AiModelStorage.modelsDir;
    final tokenizerDir = await AiModelStorage.tokenizerDir;
    await Directory(modelsDir).create(recursive: true);
    await Directory(tokenizerDir).create(recursive: true);

    final destDir = switch (type) {
      AiModelFileType.tokenizer ||
      AiModelFileType.tokenizerConfig => tokenizerDir,
      _ => modelsDir,
    };
    final destName = _canonicalNameFor(type, ext);
    final destPath = p.join(destDir, destName);

    await source.copy(destPath);
    return destPath;
  }

  /// Downloads a single model file from [url] and saves it under a canonical
  /// name in the app model directory.
  ///
  /// [url] may be a direct file URL or a HuggingFace `/resolve/main/...`
  /// URL. The file extension is taken from the URL path when possible,
  /// falling back to inspecting the HTTP response or the original filename.
  ///
  /// Returns the saved canonical path on success, `null` on failure.
  static Future<String?> downloadSingleFile(
    String url,
    AiModelFileType type, {
    void Function(double progress, String status)? onProgress,
  }) async {
    final ext = _extensionFromUrl(url) ?? _defaultExtensionFor(type);
    final modelsDir = await AiModelStorage.modelsDir;
    final tokenizerDir = await AiModelStorage.tokenizerDir;
    await Directory(modelsDir).create(recursive: true);
    await Directory(tokenizerDir).create(recursive: true);

    final destDir = switch (type) {
      AiModelFileType.tokenizer ||
      AiModelFileType.tokenizerConfig => tokenizerDir,
      _ => modelsDir,
    };
    final destName = _canonicalNameFor(type, ext);
    final destPath = p.join(destDir, destName);

    onProgress?.call(0.0, 'Downloading $destName...');
    final ok = await _downloadFileWithRetry(
      url,
      destPath,
      onProgress: (p) => onProgress?.call(p, 'Downloading $destName...'),
    );
    if (!ok) return null;

    // Validate JSON for config files after download.
    if (type == AiModelFileType.preprocessorConfig ||
        type == AiModelFileType.tokenizerConfig) {
      try {
        final content = await File(destPath).readAsString();
        json.decode(content); // throws if invalid JSON
      } catch (_) {
        await File(destPath).delete();
        return null;
      }
    }

    return destPath;
  }

  static String? _extensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final ext = p.extension(path);
      if (ext.isNotEmpty && ext.length <= 6) return ext.substring(1);
    } catch (_) {
      // ignore
    }
    return null;
  }

  static String _defaultExtensionFor(AiModelFileType type) {
    return switch (type) {
      AiModelFileType.tokenizer => 'json',
      AiModelFileType.vision => 'onnx',
      AiModelFileType.text => 'onnx',
      AiModelFileType.preprocessorConfig => 'json',
      AiModelFileType.tokenizerConfig => 'json',
    };
  }

  // ── URL parsing ─────────────────────────────────────────────────────

  /// Parses [url] and returns `(baseDomain, "owner/repo")` or `null`.
  ///
  /// Examples:
  ///   `https://huggingface.co/user/my-repo` → `(huggingface.co, user/my-repo)`
  ///   `https://hf-mirror.com/user/repo`      → `(hf-mirror.com, user/repo)`
  static (String, String)? _parseBase(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;

      // Validate domain
      if (!host.contains('huggingface.co') && !host.contains('hf-mirror.com')) {
        return null;
      }

      // Path should be /owner/repo[/...]
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;

      final owner = segments[0];
      final repo = segments[1];
      return (host, '$owner/$repo');
    } catch (_) {
      return null;
    }
  }

  // ── Download helpers ────────────────────────────────────────────────

  /// Try [candidates] in order; return the local path of the first
  /// successfully downloaded file, or `null` if all failed.
  ///
  /// Skips files that already exist on disk.
  static Future<String?> _downloadFirstExisting(
    String downloadBase,
    String destDir,
    List<String> candidates, {
    void Function(double progress)? onProgress,
  }) async {
    for (final name in candidates) {
      final destPath = p.join(destDir, name);

      // Skip if already exists
      if (await File(destPath).exists()) {
        onProgress?.call(1.0);
        return destPath;
      }

      final url = '$downloadBase/$name';
      final ok = await _downloadFileWithRetry(
        url,
        destPath,
        onProgress: onProgress,
      );
      if (ok) return destPath;
    }
    return null;
  }

  /// Download a single file with up to [_maxRetries] retries.
  ///
  /// After a successful HTTP download the file is validated: HTML error
  /// pages (e.g. from an incorrect URL) are rejected and deleted.
  static Future<bool> _downloadFileWithRetry(
    String url,
    String savePath, {
    void Function(double progress)? onProgress,
  }) async {
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        await Dio().download(
          url,
          savePath,
          onReceiveProgress: (int received, int total) {
            if (onProgress != null) {
              if (total > 0) {
                onProgress(received / total);
              }
            }
          },
        );
        // Validate: reject HTML pages that were served instead of the model.
        final file = File(savePath);
        final bytes = await file.openRead(0, 64).expand((e) => e).toList();
        final header = String.fromCharCodes(bytes).trim().toLowerCase();
        if (header.startsWith('<!doctype') ||
            header.startsWith('<html') ||
            header.isEmpty) {
          await file.delete();
          return false;
        }
        return true;
      } on DioException {
        if (attempt == _maxRetries - 1) return false;
        // Brief delay before retry
        await Future.delayed(Duration(seconds: 1 << attempt));
      }
    }
    return false;
  }

  /// Report combined progress for all file groups.
  ///
  /// [completedGroups] = number of groups already done (0..2).
  /// [groupProgress] = progress within the current group (0.0..1.0).
  /// [groupIndex] = which group we're currently in (0=tokenizer, 1=vision, 2=text).
  static void _reportGroupProgress(
    void Function(double, String)? onProgress,
    int completedGroups,
    double groupProgress,
    int groupIndex,
  ) {
    if (onProgress == null) return;

    const groupWeight = 1.0 / _fileGroupCount;
    final overall =
        (completedGroups * groupWeight) +
        (groupIndex + 1) * groupWeight * groupProgress;
    final clipped = overall.clamp(0.0, 1.0);

    final status = switch (groupIndex) {
      0 => 'Downloading tokenizer...',
      1 => 'Downloading vision encoder...',
      _ => 'Downloading text encoder...',
    };
    onProgress(clipped, status);
  }
}
