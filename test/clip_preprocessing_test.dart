import 'dart:typed_data';

import 'package:PiliPlus/utils/clip_preprocessing.dart';
import 'package:PiliPlus/utils/clip_preprocessor_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Tests for [ClipPreprocessing].
///
/// All test images are generated programmatically to avoid fixture files.

// Default CLIP normalisation constants (OpenAI CLIP).
const _meanR = 0.48145466;
const _meanG = 0.4578275;
const _meanB = 0.40821073;
const _stdR = 0.26862954;
const _stdG = 0.26130258;
const _stdB = 0.27577711;

void main() {
  // ---------------------------------------------------------------------------
  // layoutForFormat
  // ---------------------------------------------------------------------------
  group('layoutForFormat', () {
    test('"onnx" → TensorLayout.nchw', () {
      expect(ClipPreprocessing.layoutForFormat('onnx'), TensorLayout.nchw);
    });

    test('"ONNX" (upper case) → TensorLayout.nchw', () {
      expect(ClipPreprocessing.layoutForFormat('ONNX'), TensorLayout.nchw);
    });

    test('"tflite" → TensorLayout.nhwc', () {
      expect(ClipPreprocessing.layoutForFormat('tflite'), TensorLayout.nhwc);
    });

    test('"TFLite" (mixed case) → TensorLayout.nhwc', () {
      expect(ClipPreprocessing.layoutForFormat('TFLite'), TensorLayout.nhwc);
    });

    test('unknown format → TensorLayout.nhwc (default)', () {
      expect(
        ClipPreprocessing.layoutForFormat('coreml'),
        TensorLayout.nhwc,
      );
    });

    test('empty string → TensorLayout.nhwc', () {
      expect(ClipPreprocessing.layoutForFormat(''), TensorLayout.nhwc);
    });
  });

  // ---------------------------------------------------------------------------
  // preprocessImage – basic behaviour
  // ---------------------------------------------------------------------------
  group('preprocessImage', () {
    /// Helper: create a [inputSize]×[inputSize] solid-colour PNG and return its
    /// encoded bytes. Every pixel is set to ([r], [g], [b]).
    Uint8List _solidImageBytes(int inputSize, int r, int g, int b) {
      final image = img.Image(width: inputSize, height: inputSize);
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          image.getPixel(x, y).setRgba(r, g, b, 255);
        }
      }
      return img.encodePng(image);
    }

    // Expected normalised values for a white pixel.
    final whiteR = (1.0 - _meanR) / _stdR;
    final whiteG = (1.0 - _meanG) / _stdG;
    final whiteB = (1.0 - _meanB) / _stdB;

    // Expected normalised values for a black pixel.
    final blackR = (0.0 - _meanR) / _stdR;
    final blackG = (0.0 - _meanG) / _stdG;
    final blackB = (0.0 - _meanB) / _stdB;

    test(
      'white 2×2 image → all NCHW values match (1.0 - mean) / std',
      () async {
        final bytes = _solidImageBytes(2, 255, 255, 255);
        final result = await ClipPreprocessing.preprocessImage(
          bytes,
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nchw,
          fallbackInputSize: 2,
        );

        expect(result, hasLength(12)); // 3 × 2 × 2

        // R block (indices 0..3)
        for (int i = 0; i < 4; i++) {
          expect(result[i], closeTo(whiteR, 1e-6));
        }
        // G block (indices 4..7)
        for (int i = 4; i < 8; i++) {
          expect(result[i], closeTo(whiteG, 1e-6));
        }
        // B block (indices 8..11)
        for (int i = 8; i < 12; i++) {
          expect(result[i], closeTo(whiteB, 1e-6));
        }
      },
    );

    test(
      'black 2×2 image → all NCHW values match (0.0 - mean) / std',
      () async {
        final bytes = _solidImageBytes(2, 0, 0, 0);
        final result = await ClipPreprocessing.preprocessImage(
          bytes,
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nchw,
          fallbackInputSize: 2,
        );

        expect(result, hasLength(12));

        for (int i = 0; i < 4; i++) {
          expect(result[i], closeTo(blackR, 1e-6));
        }
        for (int i = 4; i < 8; i++) {
          expect(result[i], closeTo(blackG, 1e-6));
        }
        for (int i = 8; i < 12; i++) {
          expect(result[i], closeTo(blackB, 1e-6));
        }
      },
    );

    test('output length scales correctly with inputSize', () async {
      for (final size in [224, 256]) {
        final bytes = _solidImageBytes(size, 128, 128, 128);
        final resultNchw = await ClipPreprocessing.preprocessImage(
          bytes,
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nchw,
          fallbackInputSize: size,
        );
        expect(resultNchw, hasLength(3 * size * size));

        final resultNhwc = await ClipPreprocessing.preprocessImage(
          bytes,
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nhwc,
          fallbackInputSize: size,
        );
        expect(resultNhwc, hasLength(3 * size * size));
      }
    });

    // === Config-driven size resolution ===

    test('default config uses fallbackInputSize (224)', () async {
      final bytes = _solidImageBytes(100, 128, 128, 128);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: ClipPreprocessorConfig.fromDefaults(),
        layout: TensorLayout.nhwc,
        fallbackInputSize: 224,
      );
      expect(result, hasLength(3 * 224 * 224));
    });

    test('size as int (256) produces 256×256', () async {
      final bytes = _solidImageBytes(100, 128, 128, 128);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: const ClipPreprocessorConfig(size: 256),
        layout: TensorLayout.nhwc,
      );
      expect(result, hasLength(3 * 256 * 256));
    });

    test('size as shortest_edge with rectangular source', () async {
      // 320×240 source, shortest_edge=256
      // → proportional resize + center crop to 256×256
      final image = img.Image(width: 320, height: 240);
      for (int y = 0; y < 240; y++) {
        for (int x = 0; x < 320; x++) {
          image.getPixel(x, y).setRgba(128, 128, 128, 255);
        }
      }
      final bytes = img.encodePng(image);

      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: const ClipPreprocessorConfig(size: {'shortest_edge': 256}),
        layout: TensorLayout.nhwc,
      );
      // Must be 256×256 after proportional resize + center crop
      expect(result, hasLength(3 * 256 * 256));
    });

    test('size as height/width map', () async {
      final bytes = _solidImageBytes(100, 128, 128, 128);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: const ClipPreprocessorConfig(
          size: {'height': 224, 'width': 224},
        ),
        layout: TensorLayout.nhwc,
      );
      expect(result, hasLength(3 * 224 * 224));
    });

    // === Custom config overrides ===

    test('custom mean and std via config', () async {
      const customMean = [0.5, 0.5, 0.5];
      const customStd = [0.5, 0.5, 0.5];
      final config = ClipPreprocessorConfig(
        imageMean: customMean,
        imageStd: customStd,
      );
      final bytes = _solidImageBytes(2, 255, 255, 255);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: config,
        layout: TensorLayout.nchw,
        fallbackInputSize: 2,
      );
      // White pixel: 255 → rescale 255/255 = 1.0 → (1.0 - 0.5) / 0.5 = 1.0
      expect(result, hasLength(12));
      for (int i = 0; i < 12; i++) {
        expect(result[i], closeTo(1.0, 1e-6));
      }
    });

    test('custom rescale_factor via config', () async {
      // rescaleFactor=1.0 → no rescaling; pixel values stay at 255
      const rFactor = 1.0;
      final config = ClipPreprocessorConfig(rescaleFactor: rFactor);
      final bytes = _solidImageBytes(2, 255, 255, 255);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: config,
        layout: TensorLayout.nchw,
        fallbackInputSize: 2,
      );
      // r' = 255.0 * 1.0 = 255.0 → (255.0 - mean) / std
      final expectedR = (255.0 - _meanR) / _stdR;
      final expectedG = (255.0 - _meanG) / _stdG;
      final expectedB = (255.0 - _meanB) / _stdB;
      expect(result, hasLength(12));
      for (int i = 0; i < 4; i++) {
        expect(result[i], closeTo(expectedR, 1e-4));
      }
      for (int i = 4; i < 8; i++) {
        expect(result[i], closeTo(expectedG, 1e-4));
      }
      for (int i = 8; i < 12; i++) {
        expect(result[i], closeTo(expectedB, 1e-4));
      }
    });

    test('ONNX NCHW with 336 size', () async {
      final bytes = _solidImageBytes(100, 128, 128, 128);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: const ClipPreprocessorConfig(size: 336),
        layout: TensorLayout.nchw,
      );
      expect(result, hasLength(3 * 336 * 336));
    });

    test('TFLite NHWC with 256 size', () async {
      final bytes = _solidImageBytes(100, 128, 128, 128);
      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: const ClipPreprocessorConfig(size: 256),
        layout: TensorLayout.nhwc,
      );
      expect(result, hasLength(3 * 256 * 256));
    });
  });

  // ---------------------------------------------------------------------------
  // NCHW layout structure
  // ---------------------------------------------------------------------------
  group('NCHW layout', () {
    test(
      'first third = R, second = G, third = B for multi-colour image',
      () async {
        // Create a 2×2 image where each pixel has a distinct RGB value:
        //   (0,0) → (240, 10, 20)
        //   (1,0) → ( 30, 200, 50)
        //   (0,1) → ( 60, 70, 220)
        //   (1,1) → (180, 120, 90)
        const size = 2;
        final image = img.Image(width: size, height: size);
        image.getPixel(0, 0).setRgba(240, 10, 20, 255);
        image.getPixel(1, 0).setRgba(30, 200, 50, 255);
        image.getPixel(0, 1).setRgba(60, 70, 220, 255);
        image.getPixel(1, 1).setRgba(180, 120, 90, 255);
        final bytes = img.encodePng(image);

        final result = await ClipPreprocessing.preprocessImage(
          bytes,
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nchw,
          fallbackInputSize: size,
        );

        expect(result, hasLength(12));

        // Manual normalisation helper.
        double nv(num raw, double mean, double std) =>
            (raw / 255.0 - mean) / std;

        // R block (indices 0..3) — row-major: (0,0), (1,0), (0,1), (1,1)
        expect(result[0], closeTo(nv(240, _meanR, _stdR), 1e-6));
        expect(result[1], closeTo(nv(30, _meanR, _stdR), 1e-6));
        expect(result[2], closeTo(nv(60, _meanR, _stdR), 1e-6));
        expect(result[3], closeTo(nv(180, _meanR, _stdR), 1e-6));

        // G block (indices 4..7)
        expect(result[4], closeTo(nv(10, _meanG, _stdG), 1e-6));
        expect(result[5], closeTo(nv(200, _meanG, _stdG), 1e-6));
        expect(result[6], closeTo(nv(70, _meanG, _stdG), 1e-6));
        expect(result[7], closeTo(nv(120, _meanG, _stdG), 1e-6));

        // B block (indices 8..11)
        expect(result[8], closeTo(nv(20, _meanB, _stdB), 1e-6));
        expect(result[9], closeTo(nv(50, _meanB, _stdB), 1e-6));
        expect(result[10], closeTo(nv(220, _meanB, _stdB), 1e-6));
        expect(result[11], closeTo(nv(90, _meanB, _stdB), 1e-6));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // NHWC layout structure
  // ---------------------------------------------------------------------------
  group('NHWC layout', () {
    test('interleaved RGB per pixel for multi-colour image', () async {
      // Same 2×2 image as the NCHW test.
      const size = 2;
      final image = img.Image(width: size, height: size);
      image.getPixel(0, 0).setRgba(240, 10, 20, 255);
      image.getPixel(1, 0).setRgba(30, 200, 50, 255);
      image.getPixel(0, 1).setRgba(60, 70, 220, 255);
      image.getPixel(1, 1).setRgba(180, 120, 90, 255);
      final bytes = img.encodePng(image);

      final result = await ClipPreprocessing.preprocessImage(
        bytes,
        config: ClipPreprocessorConfig.fromDefaults(),
        layout: TensorLayout.nhwc,
        fallbackInputSize: size,
      );

      expect(result, hasLength(12));

      double nv(num raw, double mean, double std) => (raw / 255.0 - mean) / std;

      // Pixel (0,0): stride 0
      expect(result[0], closeTo(nv(240, _meanR, _stdR), 1e-6));
      expect(result[1], closeTo(nv(10, _meanG, _stdG), 1e-6));
      expect(result[2], closeTo(nv(20, _meanB, _stdB), 1e-6));

      // Pixel (1,0): stride 3
      expect(result[3], closeTo(nv(30, _meanR, _stdR), 1e-6));
      expect(result[4], closeTo(nv(200, _meanG, _stdG), 1e-6));
      expect(result[5], closeTo(nv(50, _meanB, _stdB), 1e-6));

      // Pixel (0,1): stride 6
      expect(result[6], closeTo(nv(60, _meanR, _stdR), 1e-6));
      expect(result[7], closeTo(nv(70, _meanG, _stdG), 1e-6));
      expect(result[8], closeTo(nv(220, _meanB, _stdB), 1e-6));

      // Pixel (1,1): stride 9
      expect(result[9], closeTo(nv(180, _meanR, _stdR), 1e-6));
      expect(result[10], closeTo(nv(120, _meanG, _stdG), 1e-6));
      expect(result[11], closeTo(nv(90, _meanB, _stdB), 1e-6));
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------
  group('error handling', () {
    test('corrupt bytes throws ArgumentError', () async {
      final corrupt = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
      expect(
        () => ClipPreprocessing.preprocessImage(
          corrupt,
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nchw,
          fallbackInputSize: 224,
        ),
        throwsArgumentError,
      );
    });

    test('empty bytes throws ArgumentError', () async {
      expect(
        () => ClipPreprocessing.preprocessImage(
          Uint8List(0),
          config: ClipPreprocessorConfig.fromDefaults(),
          layout: TensorLayout.nchw,
          fallbackInputSize: 224,
        ),
        throwsArgumentError,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Symmetry: NCHW and NHWC contain the same floats (just re-arranged)
  // ---------------------------------------------------------------------------
  group('NCHW ↔ NHWC symmetry', () {
    test('same image, same order of normalised values', () async {
      const size = 4;
      final image = img.Image(width: size, height: size);
      // Fill with a gradient.
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          image
              .getPixel(x, y)
              .setRgba(
                (x * 60) % 256,
                (y * 70) % 256,
                ((x + y) * 40) % 256,
                255,
              );
        }
      }
      final bytes = img.encodePng(image);

      final nchw = await ClipPreprocessing.preprocessImage(
        bytes,
        config: ClipPreprocessorConfig.fromDefaults(),
        layout: TensorLayout.nchw,
        fallbackInputSize: size,
      );
      final nhwc = await ClipPreprocessing.preprocessImage(
        bytes,
        config: ClipPreprocessorConfig.fromDefaults(),
        layout: TensorLayout.nhwc,
        fallbackInputSize: size,
      );

      // Both should have the same length.
      expect(nchw, hasLength(nhwc.length));

      // Collect the set of normalised values — every value that appears in NCHW
      // must also appear in NHWC (they're just grouped differently).
      final nchwSet = nchw.toSet();
      for (final v in nhwc) {
        expect(
          nchwSet.contains(v),
          isTrue,
          reason: 'NHWC value $v not found in NCHW result',
        );
      }
    });
  });
}
