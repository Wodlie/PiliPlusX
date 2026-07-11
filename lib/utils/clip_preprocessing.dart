import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Tensor data layout formats for CLIP inference.
///
/// - [nchw]: Channel-first layout [C, H, W] used by ONNX models.
/// - [nhwc]: Channel-last layout [H, W, C] used by TFLite models.
enum TensorLayout { nchw, nhwc }

/// CLIP image preprocessing utilities.
///
/// Provides a single entry-point [preprocessImage] that decodes raw image bytes,
/// resizes to the CLIP input size, normalises pixels using OpenAI CLIP's standard
/// mean/std, and arranges the result according to the requested tensor layout.
abstract final class ClipPreprocessing {
  /// Map a format string to a [TensorLayout].
  ///
  /// * `'onnx'` → [TensorLayout.nchw]
  /// * `'tflite'` → [TensorLayout.nhwc]
  /// * Anything else → [TensorLayout.nhwc] (default).
  static TensorLayout layoutForFormat(String format) {
    switch (format.toLowerCase()) {
      case 'onnx':
        return TensorLayout.nchw;
      case 'tflite':
        return TensorLayout.nhwc;
      default:
        return TensorLayout.nhwc;
    }
  }

  /// Preprocess raw image bytes for CLIP inference.
  ///
  /// Steps:
  /// 1. Decode the image via [img.decodeImage].
  /// 2. Resize to [inputSize] × [inputSize] with bilinear interpolation.
  /// 3. Extract RGB channels and normalise:
  ///    `(pixel / 255.0 - mean) / std`
  /// 4. Arrange floats according to [layout]:
  ///    - [TensorLayout.nchw]: Channel-first `[C, H, W]` — all R values,
  ///      then all G, then all B.
  ///    - [TensorLayout.nhwc]: Channel-last `[H, W, C]` — interleaved RGB
  ///      per pixel.
  ///
  /// Returns a [Float32List] of length `3 * inputSize * inputSize`.
  ///
  /// Default mean/std are OpenAI CLIP's canonical values:
  /// ```
  ///   mean = [0.48145466, 0.4578275, 0.40821073]
  ///   std  = [0.26862954, 0.26130258, 0.27577711]
  /// ```
  ///
  /// Throws [ArgumentError] if the image cannot be decoded.
  static Future<Float32List> preprocessImage(
    Uint8List imageBytes, {
    required int inputSize,
    required TensorLayout layout,
    double meanR = 0.48145466,
    double meanG = 0.4578275,
    double meanB = 0.40821073,
    double stdR = 0.26862954,
    double stdG = 0.26130258,
    double stdB = 0.27577711,
  }) async {
    // 1. Decode
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw ArgumentError('Failed to decode image: unrecognised format');
    }

    // 2. Resize
    final resized = img.copyResize(
      decoded,
      width: inputSize,
      height: inputSize,
      interpolation: img.Interpolation.linear,
    );

    // 3 & 4. Normalise + layout
    final totalPixels = inputSize * inputSize;
    final result = Float32List(3 * totalPixels);

    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        final r = pixel.r / 255.0;
        final g = pixel.g / 255.0;
        final b = pixel.b / 255.0;

        final nr = (r - meanR) / stdR;
        final ng = (g - meanG) / stdG;
        final nb = (b - meanB) / stdB;

        if (layout == TensorLayout.nchw) {
          // NCHW: [C, H, W] — per-channel blocks
          final idx = y * inputSize + x;
          result[idx] = nr; // R channel
          result[totalPixels + idx] = ng; // G channel
          result[2 * totalPixels + idx] = nb; // B channel
        } else {
          // NHWC: [H, W, C] — pixel-interleaved
          final idx = (y * inputSize + x) * 3;
          result[idx] = nr;
          result[idx + 1] = ng;
          result[idx + 2] = nb;
        }
      }
    }

    return result;
  }
}
