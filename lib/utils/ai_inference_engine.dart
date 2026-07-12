import 'dart:io' show File;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as onnx;
import 'package:flutter_litert/flutter_litert.dart' as tflite;

// ==========================================================================
// Abstract interface
// ==========================================================================

/// Abstract inference session for CLIP vision and text encoders.
///
/// Implementations wrap either the ONNX Runtime or LiteRT (TFLite) inference
/// engine, auto-selected by [AiInferenceEngine.create] based on which model
/// file format is available on disk.
abstract class InferenceSession {
  /// Run the vision encoder on a preprocessed image tensor.
  ///
  /// [input] is a flat [Float32List] produced by [ClipPreprocessing].
  ///   - For ONNX: shape `[1, 3, H, W]` (NCHW, channel-first)
  ///   - For TFLite: shape `[1, H, W, 3]` (NHWC, channel-last)
  ///
  /// Returns a 512-element image embedding (caller normalises with
  /// [ClipSimilarity]).
  Future<Float32List> runVision(Float32List input);

  /// Run the text encoder on token IDs.
  ///
  /// [tokenIds] is a 77-element list produced by [CLIPTokenizer.tokenize].
  ///
  /// Returns a 512-element text embedding (caller normalises with
  /// [ClipSimilarity]).
  Future<Float32List> runText(List<int> tokenIds);

  /// Release all native resources (sessions, tensors, interpreters).
  void dispose();
}

// ==========================================================================
// ONNX Runtime session
// ==========================================================================

/// Inference session backed by [flutter_onnxruntime].
///
/// Only available on platforms that meet ONNX Runtime requirements:
///   - iOS 16+
///   - macOS 14+
/// Other platforms fall back to [TfliteSession].
class OnnxSession implements InferenceSession {
  onnx.OnnxRuntime? _ort;
  late final onnx.OrtSession _visionSession;
  late final onnx.OrtSession _textSession;
  late final String _visionInputName;
  late final String _visionOutputName;
  late final String _textInputName;
  late final String _textOutputName;
  // Model paths are needed by [Isolate.run] which creates temporary sessions
  // inside the spawned isolate (native resources cannot cross boundaries).
  late final String _visionModelPath;
  late final String _textModelPath;

  OnnxSession._();

  /// Create an [OnnxSession] from model files stored on disk.
  ///
  /// Throws [StateError] if model files are not found.
  ///
  /// ONNX Runtime is supported on all platforms (Android, iOS, Linux,
  /// macOS, Windows) via the flutter_onnxruntime plugin.
  static Future<OnnxSession> create() async {
    final visionPath = await AiModelStorage.getVisionPath();
    final textPath = await AiModelStorage.getTextPath();
    if (visionPath == null || textPath == null) {
      throw StateError('ONNX model files not found on disk.');
    }

    final ort = onnx.OnnxRuntime();
    try {
      final vision = await ort.createSession(visionPath);
      final text = await ort.createSession(textPath);
      final session = OnnxSession._();
      session._ort = ort;
      session._visionSession = vision;
      session._textSession = text;
      session._visionModelPath = visionPath;
      session._textModelPath = textPath;
      session._visionInputName = vision.inputNames.first;
      session._visionOutputName = vision.outputNames.first;
      session._textInputName = text.inputNames.first;
      session._textOutputName = text.outputNames.first;
      return session;
    } catch (e) {
      ort;
      rethrow;
    }
  }

  @override
  Future<Float32List> runVision(Float32List input) async {
    // ONNX Runtime has no built-in IsolateInterpreter (unlike flutter_litert).
    // Use Isolate.run() to offload inference: create a temporary session
    // inside the spawned isolate (sessions cannot cross isolate boundaries),
    // run inference, close the session, and return the result.
    final path = _visionModelPath;
    final inputName = _visionInputName;
    final outputName = _visionOutputName;
    return Isolate.run(() async {
      final ort = onnx.OnnxRuntime();
      final session = await ort.createSession(path);
      try {
        final tensor = await onnx.OrtValue.fromList(
          input.toList(),
          [1, 3, 224, 224],
        );
        try {
          final outputs = await session.run({inputName: tensor});
          final out = outputs[outputName]!;
          final list = await out.asList() as List<dynamic>;
          return Float32List.fromList(list.cast<double>());
        } finally {
          await tensor.dispose();
        }
      } finally {
        session.close();
      }
    });
  }

  @override
  Future<Float32List> runText(List<int> tokenIds) async {
    final tensor = await onnx.OrtValue.fromList(
      tokenIds.map((e) => e.toInt()).toList(),
      [1, 77],
    );
    try {
      final outputs = await _textSession.run({_textInputName: tensor});
      final out = outputs[_textOutputName]!;
      final list = await out.asList() as List<dynamic>;
      return Float32List.fromList(list.cast<double>());
    } finally {
      await tensor.dispose();
    }
  }

  @override
  void dispose() {
    _visionSession.close();
    _textSession.close();
    _ort = null;
  }
}

// ==========================================================================
// TFLite / LiteRT session
// ==========================================================================

/// Inference session backed by [flutter_litert] with [CompiledModel] for
/// the vision encoder and [Interpreter] + [IsolateInterpreter] for the
/// text encoder (which requires int32 token IDs).
class TfliteSession implements InferenceSession {
  tflite.CompiledModel? _visionModel;
  tflite.Interpreter? _textInterpreter;
  tflite.IsolateInterpreter? _textIsolate;

  TfliteSession._();

  /// Create a [TfliteSession] from model files stored on disk.
  ///
  /// Throws [StateError] if model files are not found.
  static Future<TfliteSession> create() async {
    final visionPath = await AiModelStorage.getVisionPath();
    final textPath = await AiModelStorage.getTextPath();
    if (visionPath == null || textPath == null) {
      throw StateError('TFLite model files not found on disk.');
    }

    final session = TfliteSession._();
    try {
      session._visionModel = tflite.CompiledModel.fromFile(
        visionPath,
        accelerators: {tflite.Accelerator.cpu},
      );

      final interpreter = await tflite.Interpreter.fromFile(File(textPath));
      session._textInterpreter = interpreter;
      session._textIsolate = await tflite.IsolateInterpreter.create(
        address: interpreter.address,
      );
    } catch (e) {
      session.dispose();
      rethrow;
    }
    return session;
  }

  @override
  Future<Float32List> runVision(Float32List input) async {
    final outputs = _visionModel!.run([input]);
    return outputs.first;
  }

  @override
  Future<Float32List> runText(List<int> tokenIds) async {
    final input = [tokenIds.toList()];
    final output = [List.filled(512, 0.0)];
    await _textIsolate!.run(input, output);
    return Float32List.fromList(output.first.cast<double>());
  }

  @override
  void dispose() {
    _visionModel?.close();
    _visionModel = null;
    _textIsolate?.close();
    _textIsolate = null;
    _textInterpreter?.close();
    _textInterpreter = null;
  }
}

// ==========================================================================
// Factory
// ==========================================================================

/// Entry-point for creating an [InferenceSession] based on the model format
/// discovered on disk.
abstract final class AiInferenceEngine {
  /// The error message from the most recent failed [create] call, or `null`
  /// if the last call succeeded or no call has been made.
  ///
  /// Callers can inspect this to show a user-friendly diagnostic when
  /// [create] returns `null`.
  static String? lastCreateError;

  /// Detect the model format and create the appropriate session.
  ///
  /// Returns `null` when no model files are available or session creation
  /// fails for all available formats.  Check [lastCreateError] for the
  /// reason.
  ///
  /// Selection priority:
  ///   1. ONNX (all platforms)
  ///   2. TFLite (fallback)
  static Future<InferenceSession?> create() async {
    lastCreateError = null;
    final format = await AiModelStorage.detectFormat();

    switch (format.toLowerCase()) {
      case 'onnx':
        try {
          return await OnnxSession.create();
        } catch (e) {
          lastCreateError = 'ONNX: $e';
        }
        if (await AiModelStorage.hasBothEncoders()) {
          try {
            return await TfliteSession.create();
          } catch (e) {
            lastCreateError = 'TFLite(onnx-fallback): $e';
            return null;
          }
        }
        lastCreateError ??= 'ONNX 格式已检测到但缺少编码器文件';
        return null;

      case 'tflite':
        try {
          return await TfliteSession.create();
        } catch (e) {
          lastCreateError = 'TFLite: $e';
          return null;
        }

      default:
        lastCreateError = '未检测到模型文件，请先导入模型';
        return null;
    }
  }
}
