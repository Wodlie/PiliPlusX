import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/ai_inference_engine.dart';
import 'package:PiliPlus/utils/hf_model_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// ==========================================================================
// Mock InferenceSession for testing the abstract interface.
// ==========================================================================

class MockInferenceSession implements InferenceSession {
  final Float32List? mockVisionOutput;
  final Float32List? mockTextOutput;

  MockInferenceSession({
    this.mockVisionOutput,
    this.mockTextOutput,
  });

  int visionCalls = 0;
  int textCalls = 0;
  bool disposed = false;

  @override
  Future<Float32List> runVision(Float32List input) async {
    visionCalls++;
    return mockVisionOutput ??
        Float32List.fromList(List.filled(512, 0.5));
  }

  @override
  Future<Float32List> runText(List<int> tokenIds) async {
    textCalls++;
    return mockTextOutput ??
        Float32List.fromList(List.filled(512, 0.3));
  }

  @override
  void dispose() {
    disposed = true;
  }
}

// ==========================================================================
// Helpers
// ==========================================================================

/// Create a minimal valid file at [path] that is not empty.
Future<File> _createDummyModelFile(String path) async {
  final file = File(path);
  await file.create(recursive: true);
  // Write a minimal ONNX header just for file-existence tests.
  await file.writeAsBytes(List.filled(128, 0));
  return file;
}

/// Create a minimal empty file for tokenizer fixtures.
Future<File> _createDummyFile(String path) async {
  final file = File(path);
  await file.create(recursive: true);
  await file.writeAsString('{}');
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // We use a temp directory and override AiModelStorage's base path via
  // [AiModelStorage.debugBasePath] to avoid depending on the real
  // documents directory.
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ai_engine_test_');
    AiModelStorage.debugBasePath = tempDir.path;
  });

  tearDown(() async {
    AiModelStorage.debugBasePath = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ======================================================================
  // AiModelStorage
  // ======================================================================
  group('AiModelStorage', () {
    group('hasModelFiles', () {
      test('returns false when directory does not exist', () async {
        expect(await AiModelStorage.hasModelFiles(), isFalse);
      });

      test('returns false for empty directory', () async {
        await Directory(await AiModelStorage.modelsDir).create(recursive: true);
        expect(await AiModelStorage.hasModelFiles(), isFalse);
      });

      test('returns true when model files exist', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.onnx');
        expect(await AiModelStorage.hasModelFiles(), isTrue);
      });
    });

    group('hasBothEncoders', () {
      test('returns false when directory is empty', () async {
        expect(await AiModelStorage.hasBothEncoders(), isFalse);
      });

      test('returns true when both vision and text files exist', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.onnx');
        await _createDummyModelFile('$mDir/text_model.onnx');
        expect(await AiModelStorage.hasBothEncoders(), isTrue);
      });

      test('returns false when only one encoder exists', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.onnx');
        expect(await AiModelStorage.hasBothEncoders(), isFalse);
      });
    });

    group('detectFormat', () {
      test('returns empty string when no files exist', () async {
        expect(await AiModelStorage.detectFormat(), '');
      });

      test('returns onnx when .onnx files present', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.onnx');
        expect(await AiModelStorage.detectFormat(), 'onnx');
      });

      test('returns tflite when .tflite files present', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.tflite');
        expect(await AiModelStorage.detectFormat(), 'tflite');
      });

      test('detects onnx or tflite when both are present', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.onnx');
        await _createDummyModelFile('$mDir/text_model.tflite');
        final format = await AiModelStorage.detectFormat();
        expect(format == 'onnx' || format == 'tflite', isTrue,
            reason: 'Expected onnx or tflite but got "$format"');
      });
    });

    group('getVisionPath / getTextPath', () {
      test('both return null when no files exist', () async {
        expect(await AiModelStorage.getVisionPath(), isNull);
        expect(await AiModelStorage.getTextPath(), isNull);
      });

      void testPath(Future<String?> Function() getPath, String fileName) {
        test('returns path ending with $fileName', () async {
          final mDir = await AiModelStorage.modelsDir;
          await Directory(mDir).create(recursive: true);
          await _createDummyModelFile(p.join(mDir, fileName));
          final found = await getPath();
          expect(found, isNotNull);
          expect(p.basename(found!), fileName);
        });
      }

      testPath(AiModelStorage.getVisionPath, 'vision_model.onnx');
      testPath(AiModelStorage.getVisionPath, 'image_encoder.onnx');
      testPath(AiModelStorage.getVisionPath, 'vision_model.tflite');
      testPath(AiModelStorage.getTextPath, 'text_model.onnx');
      testPath(AiModelStorage.getTextPath, 'text_encoder.tflite');
    });

    group('hasTokenizer', () {
      test('returns false when tokenizer directory is missing', () async {
        expect(await AiModelStorage.hasTokenizer(), isFalse);
      });

      test('returns true when tokenizer.json exists', () async {
        final tDir = await AiModelStorage.tokenizerDir;
        await Directory(tDir).create(recursive: true);
        await _createDummyFile('$tDir/tokenizer.json');
        expect(await AiModelStorage.hasTokenizer(), isTrue);
      });

      test('returns true when vocab.json + merges.txt exist', () async {
        final tDir = await AiModelStorage.tokenizerDir;
        await Directory(tDir).create(recursive: true);
        await _createDummyFile('$tDir/vocab.json');
        await _createDummyFile('$tDir/merges.txt');
        expect(await AiModelStorage.hasTokenizer(), isTrue);
      });

      test('returns false when only vocab.json is present', () async {
        final tDir = await AiModelStorage.tokenizerDir;
        await Directory(tDir).create(recursive: true);
        await _createDummyFile('$tDir/vocab.json');
        expect(await AiModelStorage.hasTokenizer(), isFalse);
      });
    });

    group('deleteAllModels', () {
      test('removes all files and directory', () async {
        final mDir = await AiModelStorage.modelsDir;
        await Directory(mDir).create(recursive: true);
        await _createDummyModelFile('$mDir/vision_model.onnx');
        await _createDummyModelFile('$mDir/text_model.onnx');
        expect(await AiModelStorage.hasModelFiles(), isTrue);

        await AiModelStorage.deleteAllModels();
        expect(await AiModelStorage.hasModelFiles(), isFalse);
        expect(await Directory(mDir).exists(), isFalse);
      });

      test('succeeds when directory does not exist', () async {
        // Should not throw.
        await AiModelStorage.deleteAllModels();
      });
    });
  });

  // ======================================================================
  // HfModelDownloader — URL parsing (no network calls)
  // ======================================================================
  group('HfModelDownloader', () {
    // URL validation tests return false immediately without network access.

    test('downloadFromRepo returns false for invalid URL', () async {
      final result = await HfModelDownloader.downloadFromRepo('not-a-url');
      expect(result, isFalse);
    });

    test('downloadFromRepo returns false for empty URL', () async {
      final result = await HfModelDownloader.downloadFromRepo('');
      expect(result, isFalse);
    });

    test('downloadFromRepo returns false for unsupported domain', () async {
      final result = await HfModelDownloader.downloadFromRepo(
        'https://example.com/user/repo',
      );
      expect(result, isFalse);
    });

    test('downloadFromRepo returns false for URL without owner/repo', () async {
      final result = await HfModelDownloader.downloadFromRepo(
        'https://huggingface.co',
      );
      expect(result, isFalse);
    });
  });

  // ======================================================================
  // InferenceSession (abstract interface)
  // ======================================================================
  group('InferenceSession (abstract)', () {
    test('mock implementation implements the interface', () {
      final session = MockInferenceSession();
      expect(session, isA<InferenceSession>());
    });

    test('mock runVision returns expected Float32List', () async {
      final expected = Float32List.fromList(List.filled(512, 0.42));
      final session = MockInferenceSession(mockVisionOutput: expected);
      final result = await session.runVision(Float32List(150528));
      expect(result, expected);
      expect(session.visionCalls, 1);
    });

    test('mock runText returns expected Float32List', () async {
      final expected = Float32List.fromList(List.filled(512, 0.77));
      final session = MockInferenceSession(mockTextOutput: expected);
      final result = await session.runText(List.filled(77, 1));
      expect(result, expected);
      expect(session.textCalls, 1);
    });

    test('mock dispose sets flag', () {
      final session = MockInferenceSession();
      expect(session.disposed, isFalse);
      session.dispose();
      expect(session.disposed, isTrue);
    });

    test('session can be created and used for both vision and text', () async {
      final session = MockInferenceSession();
      final visionOut = await session.runVision(Float32List(150528));
      final textOut = await session.runText(List.filled(77, 1));
      expect(visionOut, hasLength(512));
      expect(textOut, hasLength(512));
    });
  });

  // ======================================================================
  // AiInferenceEngine factory
  // ======================================================================
  group('AiInferenceEngine', () {
    test('create returns null when no model files exist', () async {
      final session = await AiInferenceEngine.create();
      expect(session, isNull);
    });

    test('create returns null when directory is empty', () async {
      await Directory(await AiModelStorage.modelsDir).create(recursive: true);
      final session = await AiInferenceEngine.create();
      expect(session, isNull);
    });
  });
}
