import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:PiliPlus/utils/clip_preprocessor_config.dart';

/// Tensor data layout formats for CLIP inference.
///
/// - [nchw]: Channel-first layout [C, H, W] used by ONNX models.
/// - [nhwc]: Channel-last layout [H, W, C] used by TFLite models.
enum TensorLayout { nchw, nhwc }

/// CLIP image preprocessing utilities.
///
/// Provides a single entry-point [preprocessImage] that decodes raw image bytes,
/// applies config-driven preprocessing (proportional resize, center crop,
/// rescale, normalise) and arranges the result according to the requested
/// tensor layout.
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
  /// Pipeline:
  /// 1. Decode raw bytes via [img.decodeImage].
  /// 2. Proportional resize (scale shortest edge to cover target, keep AR).
  /// 3. Center crop to target width × height.
  /// 4. Rescale pixel values by [config.rescaleFactor].
  /// 5. Normalise using [config.imageMean] and [config.imageStd]
  ///    (only when [config.doNormalize] is true).
  /// 6. Arrange floats according to [layout]:
  ///    - [TensorLayout.nchw]: Channel-first `[C, H, W]` — all R values,
  ///      then all G, then all B.
  ///    - [TensorLayout.nhwc]: Channel-last `[H, W, C]` — interleaved RGB
  ///      per pixel.
  ///
  /// Returns a [Float32List] of length `3 * width * height`.
  ///
  /// Size resolution priority (via [config.inputWidth] / [config.inputHeight]):
  /// 1. `doCenterCrop == true` and [config.cropSize] present → cropSize dims.
  /// 2. [config.size] has explicit `width` & `height` → those dims.
  /// 3. [config.size] has `shortest_edge` → proportional resize + square crop.
  /// 4. Otherwise → [fallbackInputSize] used as square (default 224).
  ///
  /// Channel count (3) and batch (1) remain constant.
  ///
  /// Throws [ArgumentError] if the image cannot be decoded.
  static Future<Float32List> preprocessImage(
    Uint8List imageBytes, {
    required ClipPreprocessorConfig config,
    required TensorLayout layout,
    int? fallbackInputSize,
  }) async {
    // 1. Decode
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw ArgumentError('Failed to decode image: unrecognised format');
    }

    // 2. Determine target dimensions
    final targetW = config.inputWidth ?? fallbackInputSize ?? 224;
    final targetH = config.inputHeight ?? fallbackInputSize ?? 224;

    // 3. Resize (proportional) + center crop
    img.Image processed;
    if (config.doResize) {
      final srcW = decoded.width;
      final srcH = decoded.height;

      if (config.doCenterCrop) {
        // Proportional resize: scale to cover target area
        final scale = math.max(targetW / srcW, targetH / srcH);
        final newW = (srcW * scale).round();
        final newH = (srcH * scale).round();

        final resized = img.copyResize(
          decoded,
          width: newW,
          height: newH,
          interpolation: img.Interpolation.linear,
        );

        // Center crop to final dimensions
        final cropX = ((newW - targetW) / 2).round();
        final cropY = ((newH - targetH) / 2).round();
        processed = img.copyCrop(
          resized,
          x: cropX,
          y: cropY,
          width: targetW,
          height: targetH,
        );
      } else {
        // No center crop: resize to exact target dimensions
        processed = img.copyResize(
          decoded,
          width: targetW,
          height: targetH,
          interpolation: img.Interpolation.linear,
        );
      }
    } else {
      // No resize requested — use original image as-is
      processed = decoded;
    }

    // 4, 5, 6. Rescale + normalise + tensor layout
    final finalW = processed.width;
    final finalH = processed.height;
    final totalPixels = finalW * finalH;
    final result = Float32List(3 * totalPixels);
    final rescaleFactor = config.rescaleFactor;
    final mean = config.imageMean;
    final std = config.imageStd;
    final doNorm = config.doNormalize;

    for (int y = 0; y < finalH; y++) {
      for (int x = 0; x < finalW; x++) {
        final pixel = processed.getPixel(x, y);
        double r = pixel.r * rescaleFactor;
        double g = pixel.g * rescaleFactor;
        double b = pixel.b * rescaleFactor;

        if (doNorm) {
          r = (r - mean[0]) / std[0];
          g = (g - mean[1]) / std[1];
          b = (b - mean[2]) / std[2];
        }

        if (layout == TensorLayout.nchw) {
          // NCHW: [C, H, W] — per-channel blocks
          final idx = y * finalW + x;
          result[idx] = r; // R channel
          result[totalPixels + idx] = g; // G channel
          result[2 * totalPixels + idx] = b; // B channel
        } else {
          // NHWC: [H, W, C] — pixel-interleaved
          final idx = (y * finalW + x) * 3;
          result[idx] = r;
          result[idx + 1] = g;
          result[idx + 2] = b;
        }
      }
    }

    return result;
  }
}
