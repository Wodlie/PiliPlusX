import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Immutable configuration parsed from a HuggingFace-style CLIP model's
/// `preprocessor_config.json`.
///
/// All fields default to OpenAI CLIP ViT-B/32 values when absent from JSON.
///
/// Example JSON:
/// ```json
/// {
///   "do_resize": true,
///   "size": {"shortest_edge": 256},
///   "do_center_crop": true,
///   "crop_size": 224,
///   "do_rescale": true,
///   "rescale_factor": 0.00392156862745098,
///   "do_normalize": true,
///   "image_mean": [0.48145466, 0.4578275, 0.40821073],
///   "image_std": [0.26862954, 0.26130258, 0.27577711],
///   "do_convert_rgb": true
/// }
/// ```
class ClipPreprocessorConfig {
  /// Whether to resize the image before center-cropping.
  final bool doResize;

  /// Raw size value from JSON.
  ///
  /// Can be:
  /// - `int` (square, e.g. `224`)
  /// - `Map` with `shortest_edge` (e.g. `{"shortest_edge": 256}`)
  /// - `Map` with `height` and `width` (e.g. `{"height": 224, "width": 224}`)
  final dynamic size;

  /// Whether to center-crop the image after resizing.
  final bool doCenterCrop;

  /// Raw crop size value from JSON.
  ///
  /// Can be:
  /// - `int` (square, e.g. `224`)
  /// - `Map` with `height` and `width` (e.g. `{"height": 224, "width": 224}`)
  final dynamic cropSize;

  /// Whether to rescale pixel values by [rescaleFactor].
  final bool doRescale;

  /// Factor to multiply pixel values by (typically `1/255`).
  final double rescaleFactor;

  /// Whether to normalize pixel values using [imageMean] and [imageStd].
  final bool doNormalize;

  /// Channel-wise mean for normalization (RGB order, length 3).
  final List<double> imageMean;

  /// Channel-wise standard deviation for normalization (RGB order, length 3).
  final List<double> imageStd;

  /// Resampling method used by Pillow/HuggingFace image processors.
  ///
  /// Common values:
  /// - `2` bilinear (PIL default)
  /// - `3` bicubic
  /// - `1` lanczos
  final int? resample;

  /// Whether to convert input images to RGB format.
  final bool convertRgb;

  const ClipPreprocessorConfig({
    this.doResize = true,
    this.size,
    this.doCenterCrop = true,
    this.cropSize,
    this.doRescale = true,
    this.rescaleFactor = 1.0 / 255.0,
    this.doNormalize = true,
    this.imageMean = const [0.48145466, 0.4578275, 0.40821073],
    this.imageStd = const [0.26862954, 0.26130258, 0.27577711],
    this.resample,
    this.convertRgb = true,
  });

  /// Creates a [ClipPreprocessorConfig] with OpenAI CLIP ViT-B/32 defaults.
  factory ClipPreprocessorConfig.fromDefaults() =>
      const ClipPreprocessorConfig();

  /// Loads and parses a HuggingFace-style `preprocessor_config.json` file.
  ///
  /// Returns `null` if the file does not exist, contains invalid JSON,
  /// or any other error occurs during loading.
  static Future<ClipPreprocessorConfig?> loadFromPath(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final contents = await file.readAsString();
      final json = jsonDecode(contents) as Map<String, dynamic>;
      return _fromJson(json);
    } catch (e) {
      debugPrint('ClipPreprocessorConfig.loadFromPath: $e');
      return null;
    }
  }

  static ClipPreprocessorConfig _fromJson(Map<String, dynamic> json) {
    final doResize = json['do_resize'] as bool? ?? true;

    final dynamic size;
    if (json.containsKey('size')) {
      size = json['size'];
    } else {
      size = null;
    }

    final doCenterCrop = json['do_center_crop'] as bool? ?? true;

    final dynamic cropSize;
    if (json.containsKey('crop_size')) {
      cropSize = json['crop_size'];
    } else {
      cropSize = null;
    }

    final doRescale = json['do_rescale'] as bool? ?? true;
    final rescaleFactor =
        (json['rescale_factor'] as num?)?.toDouble() ?? (1.0 / 255.0);
    final doNormalize = json['do_normalize'] as bool? ?? true;

    final imageMeanRaw = json['image_mean'];
    final imageMean = imageMeanRaw is List
        ? imageMeanRaw.map((e) => (e as num).toDouble()).toList()
        : const [0.48145466, 0.4578275, 0.40821073];

    final imageStdRaw = json['image_std'];
    final imageStd = imageStdRaw is List
        ? imageStdRaw.map((e) => (e as num).toDouble()).toList()
        : const [0.26862954, 0.26130258, 0.27577711];

    final resample = json['resample'] as int?;
    final convertRgb = json['do_convert_rgb'] as bool? ?? true;

    return ClipPreprocessorConfig(
      doResize: doResize,
      size: size,
      doCenterCrop: doCenterCrop,
      cropSize: cropSize,
      doRescale: doRescale,
      rescaleFactor: rescaleFactor,
      doNormalize: doNormalize,
      imageMean: imageMean,
      imageStd: imageStd,
      resample: resample,
      convertRgb: convertRgb,
    );
  }

  /// Computed input width based on size resolution priority.
  ///
  /// Resolution priority:
  /// 1. `doCenterCrop == true` and `cropSize` is present → use `cropSize`.
  /// 2. `size` has both `width` and `height` → use `size.width`.
  /// 3. `size` has `shortest_edge` → use as square dimension.
  /// 4. `size` is a plain `int` → use as square dimension.
  /// 5. Otherwise → `null` (caller should fall back to [Pref.aiModelInputSize]).
  int? get inputWidth {
    // Priority 1: doCenterCrop && cropSize exists
    if (doCenterCrop && cropSize != null) {
      final w = _extractWidth(cropSize);
      if (w != null) return w;
    }

    // Priority 2: size has both width && height
    if (size is Map) {
      final map = size as Map;
      if (map.containsKey('width') && map.containsKey('height')) {
        final w = _numToInt(map['width']);
        if (w != null) return w;
      }
    }

    // Priority 3: size has shortest_edge → square
    if (size is Map) {
      final map = size as Map;
      final w = _numToInt(map['shortest_edge']);
      if (w != null) return w;
    }

    // Priority 4: size is plain int/num → square
    if (size is num) return size.toInt();

    return null;
  }

  /// Computed input height. See [inputWidth] for resolution priority.
  int? get inputHeight {
    // Priority 1: doCenterCrop && cropSize exists
    if (doCenterCrop && cropSize != null) {
      final h = _extractHeight(cropSize);
      if (h != null) return h;
    }

    // Priority 2: size has both width && height
    if (size is Map) {
      final map = size as Map;
      if (map.containsKey('width') && map.containsKey('height')) {
        final h = _numToInt(map['height']);
        if (h != null) return h;
      }
    }

    // Priority 3: size has shortest_edge → square
    if (size is Map) {
      final map = size as Map;
      final h = _numToInt(map['shortest_edge']);
      if (h != null) return h;
    }

    // Priority 4: size is plain int/num → square
    if (size is num) return size.toInt();

    return null;
  }

  /// Extracts width from a cropSize value that may be an int or a map.
  static int? _extractWidth(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is Map) {
      final w = _numToInt(value['width']);
      if (w != null) return w;
    }
    return null;
  }

  /// Extracts height from a cropSize value that may be an int or a map.
  static int? _extractHeight(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is Map) {
      final h = _numToInt(value['height']);
      if (h != null) return h;
    }
    return null;
  }

  /// Safely converts a raw JSON numeric value to [int], returning `null` if
  /// the value is not a number.
  static int? _numToInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  @override
  String toString() =>
      'ClipPreprocessorConfig('
      'doResize: $doResize, '
      'size: $size, '
      'doCenterCrop: $doCenterCrop, '
      'cropSize: $cropSize, '
      'doRescale: $doRescale, '
      'rescaleFactor: $rescaleFactor, '
      'doNormalize: $doNormalize, '
      'imageMean: $imageMean, '
      'imageStd: $imageStd, '
      'resample: $resample, '
      'convertRgb: $convertRgb'
      ')';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipPreprocessorConfig &&
          runtimeType == other.runtimeType &&
          doResize == other.doResize &&
          size == other.size &&
          doCenterCrop == other.doCenterCrop &&
          cropSize == other.cropSize &&
          doRescale == other.doRescale &&
          rescaleFactor == other.rescaleFactor &&
          doNormalize == other.doNormalize &&
          imageMean == other.imageMean &&
          imageStd == other.imageStd &&
          resample == other.resample &&
          convertRgb == other.convertRgb;

  @override
  int get hashCode => Object.hash(
    runtimeType,
    doResize,
    size,
    doCenterCrop,
    cropSize,
    doRescale,
    rescaleFactor,
    doNormalize,
    imageMean,
    imageStd,
    resample,
    convertRgb,
  );
}
