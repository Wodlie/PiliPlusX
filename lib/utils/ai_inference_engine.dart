import 'dart:io' show File;
import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_model_storage.dart';
import 'package:PiliPlus/utils/clip_tokenizer_config.dart';
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
  Future<Float32List> runVision(Float32List input, {required List<int> shape});

  /// Run the text encoder on tokenized text.
  ///
  /// [tokens] is produced by [CLIPTokenizer.tokenize] and contains both
  /// input IDs and an attention mask.
  Future<Float32List> runText(TokenizedText tokens);

  /// Release all native resources (sessions, tensors, interpreters).
  void dispose();
}

// ==========================================================================
// ONNX Runtime session (all inference on main isolate)
// ==========================================================================

/// Inference session backed by [flutter_onnxruntime].
///
/// Both vision and text inference run on the main isolate using persistent
/// sessions created once at startup.  The moderation queue is serial
/// (one image at a time) so the main event loop can process frames between
/// inference calls, keeping the UI responsive.
class OnnxSession implements InferenceSession {
  late final onnx.OrtSession _visionSession;
  late final onnx.OrtSession _textSession;
  late final String _visionInputName;
  late final String _visionOutputName;
  late final String _textOutputName;

  OnnxSession._();

  /// Create an [OnnxSession] from model files stored on disk.
  ///
  /// Creates both vision and text sessions on the main isolate and keeps
  /// them alive for reuse across all inference calls.
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
      session._visionSession = vision;
      session._textSession = text;
      session._visionInputName = vision.inputNames.first;
      session._visionOutputName = vision.outputNames.first;
      session._textOutputName = text.outputNames.first;
      return session;
    } catch (e) {
      throw StateError('Failed to create ONNX session: $e');
    }
  }

  @override
  Future<Float32List> runVision(
    Float32List input, {
    required List<int> shape,
  }) async {
    final tensor = await onnx.OrtValue.fromList(input.toList(), shape);
    try {
      final outputs = await _visionSession.run({_visionInputName: tensor});
      final out = outputs[_visionOutputName]!;
      final raw = await out.asFlattenedList();
      final flat = _flattenList(raw as List<dynamic>);
      return Float32List.fromList(flat.cast<double>());
    } finally {
      await tensor.dispose();
    }
  }

  @override
  Future<Float32List> runText(TokenizedText tokens) async {
    final inputNames = _textSession.inputNames;

    // Fuzzy match input names (case-insensitive).
    String? inputIdsName;
    String? attentionMaskName;
    for (final name in inputNames) {
      final lower = name.toLowerCase();
      if (lower == 'input_ids') {
        inputIdsName = name;
      } else if (lower == 'attention_mask') {
        attentionMaskName = name;
      }
    }

    final shape = [1, tokens.inputIds.length];
    final inputs = <String, onnx.OrtValue>{};

    if (inputIdsName != null) {
      final tensor = await onnx.OrtValue.fromList(
        Int64List.fromList(tokens.inputIds),
        shape,
      );
      inputs[inputIdsName] = tensor;
    }

    if (attentionMaskName != null && inputNames.length > 1) {
      final maskTensor = await onnx.OrtValue.fromList(
        Int64List.fromList(tokens.attentionMask),
        shape,
      );
      inputs[attentionMaskName] = maskTensor;
    }

    if (inputs.isEmpty) {
      throw StateError(
        'No supported input found in model input names: $inputNames. '
        'Expected at least "input_ids".',
      );
    }

    try {
      final outputs = await _textSession.run(inputs);
      final out = outputs[_textOutputName]!;
      final raw = await out.asFlattenedList();
      final flat = _flattenList(raw as List<dynamic>);
      return Float32List.fromList(flat.cast<double>());
    } finally {
      for (final v in inputs.values) {
        await v.dispose();
      }
    }
  }

  @override
  void dispose() {
    _visionSession.close();
    _textSession.close();
  }
}

// ==========================================================================
// Helpers
// ==========================================================================

/// Recursively flatten a nested [List] of numeric values into a single-level
/// [List]<[num]>.
///
/// ONNX Runtime may return outputs shaped `[1, 512]`, `[1, 512, 1]`, or other
/// multi-dimensional layouts.  This helper collapses any nesting depth.
List<num> _flattenList(List<dynamic> list) {
  final result = <num>[];
  for (final item in list) {
    if (item is List<dynamic>) {
      result.addAll(_flattenList(item));
    } else if (item is num) {
      result.add(item);
    }
  }
  return result;
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
  Future<Float32List> runVision(
    Float32List input, {
    required List<int> shape,
  }) async {
    final outputs = _visionModel!.run([input]);
    return outputs.first;
  }

  @override
  Future<Float32List> runText(TokenizedText tokens) async {
    // Dynamic output buffer size from the model's output tensor shape.
    final outputTensors = _textInterpreter!.getOutputTensors();
    final outputTensor = outputTensors.first;
    final outputShape = outputTensor.shape;
    final outputDim = outputShape.length >= 2
        ? outputShape[outputShape.length - 1]
        : outputShape[0];

    // Determine how many inputs the model expects.
    final inputTensors = _textInterpreter!.getInputTensors();

    final outputBuffer = [List.filled(outputDim, 0.0)];

    if (inputTensors.length > 1) {
      // Model expects both input_ids and attention_mask.
      final inputList = <Object>[
        [tokens.inputIds.toList()],
        [tokens.attentionMask.toList()],
      ];
      await _textIsolate!.runForMultipleInputs(inputList, {0: outputBuffer});
    } else {
      // Model expects only input_ids.
      await _textIsolate!.run([tokens.inputIds.toList()], outputBuffer);
    }

    return Float32List.fromList(
      (outputBuffer.first as List<dynamic>).cast<double>(),
    );
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
  static String? lastCreateError;

  /// Detect the model format and create the appropriate session.
  ///
  /// Returns `null` when no model files are available or session creation
  /// fails for all available formats.  Check [lastCreateError] for the
  /// reason.
  static Future<InferenceSession?> create() async {
    lastCreateError = null;

    // Verify vision and text encoders use the same format.
    final visionPath = await AiModelStorage.getVisionPath();
    final textPath = await AiModelStorage.getTextPath();
    if (visionPath != null && textPath != null) {
      final visionIsOnnx = visionPath.endsWith('.onnx');
      final textIsOnnx = textPath.endsWith('.onnx');
      if (visionIsOnnx != textIsOnnx) {
        throw StateError('不支持混合编码器格式');
      }
    }

    final format = await AiModelStorage.detectFormat();

    switch (format.toLowerCase()) {
      case 'onnx':
        try {
          return await OnnxSession.create();
        } catch (e) {
          lastCreateError = 'ONNX: $e';
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
