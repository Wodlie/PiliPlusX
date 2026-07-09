import 'dart:typed_data';

import 'package:dart_imagehash/dart_imagehash.dart' show ImageHash, ImageHasher;
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:PiliPlus/utils/blocked_image_storage.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Compute pHash variants for an image (runs in Isolate).
/// Must be a top-level function (for compute()).
/// params[0]: Uint8List imageBytes - raw image bytes
/// params[1]: bool flipEnabled - compute horizontal flip variant
/// params[2]: bool rotateEnabled - compute rotation variants
/// Returns hex pHash list [original, flip?, rot90?, rot180?, rot270?]
List<String> computeImageHashes(List<Object?> params) {
  final bytes = params[0] as Uint8List;
  final flipEnabled = params[1] as bool;
  final rotateEnabled = params[2] as bool;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return [];

  // 1. Original pHash
  final List<String> hashes = [ImageHasher.perceptualHash(decoded).toHex()];

  // 2. Horizontal flip variant
  if (flipEnabled) {
    final flipped = img.copyFlip(
      decoded,
      direction: img.FlipDirection.horizontal,
    );
    hashes.add(ImageHasher.perceptualHash(flipped).toHex());
  }

  // 3. Rotation variants
  if (rotateEnabled) {
    for (final angle in [90, 180, 270]) {
      final rotated = img.copyRotate(decoded, angle: angle);
      hashes.add(ImageHasher.perceptualHash(rotated).toHex());
    }
  }

  return hashes;
}

/// Image blocking service.
/// Computes pHash, matches against block list, provides blocking entry point.
abstract final class ImageBlockService {
  /// URL-to-hash in-memory cache (avoids recomputation, not persisted)
  static final Map<String, List<String>> _cache = {};

  /// Compute pHash variants (runs in Isolate).
  /// [imageBytes]: raw image bytes
  /// [flipEnabled]: compute horizontal flip variant (default true)
  /// [rotateEnabled]: compute rotation variants (default true)
  /// Returns: [original, flip?, rot90?, rot180?, rot270?]
  static Future<List<String>> computeHashes(
    Uint8List imageBytes, {
    bool flipEnabled = true,
    bool rotateEnabled = true,
  }) {
    return compute(computeImageHashes, [
      imageBytes,
      flipEnabled,
      rotateEnabled,
    ]);
  }

  /// Compute Hamming distance between two pHash hex strings
  static int hammingDistance(String hash1Hex, String hash2Hex) {
    final hash1 = ImageHash.fromHex(hash1Hex);
    final hash2 = ImageHash.fromHex(hash2Hex);
    return hash1 - hash2;
  }

  /// Check if image is blocked.
  /// [imageVariantHashes]: pHash variants from computeHashes()
  /// [blockList]: Pref.imageBlockHashList entries (each is {'pHash': String, 'url': String, 'ts': int})
  /// [threshold]: Hamming distance threshold
  ///
  /// Short-circuit: returns false if enableImageBlock is false or blockList empty
  static bool isBlocked(
    List<String> imageVariantHashes,
    List<Map<String, dynamic>> blockList,
    int threshold,
  ) {
    if (!Pref.enableImageBlock) return false;
    if (blockList.isEmpty) return false;
    if (imageVariantHashes.isEmpty) return false;

    int minDistance = 64; // Max Hamming distance for 64-bit hash

    // Iterate all variants across all blocked pHashes
    for (final variantHash in imageVariantHashes) {
      for (final entry in blockList) {
        final blockedHash = entry['pHash'] as String;
        final distance = hammingDistance(variantHash, blockedHash);
        if (distance < minDistance) {
          minDistance = distance;
          if (minDistance <= threshold) return true; // Early exit
        }
      }
    }

    return false;
  }

  /// Complete image blocking flow.
  /// 1. Get bytes from cache (or download via Dio)
  /// 2. Compute pHash variants
  /// 3. Save local file
  /// 4. Return block list entry
  /// Returns null on failure
  static Future<Map<String, dynamic>?> blockImage(
    String imageUrl, {
    bool flipEnabled = true,
    bool rotateEnabled = true,
  }) async {
    try {
      final file = await CacheManager.manager.getSingleFile(imageUrl);
      final bytes = await file.readAsBytes();

      final hashes = await computeHashes(
        bytes,
        flipEnabled: flipEnabled,
        rotateEnabled: rotateEnabled,
      );
      if (hashes.isEmpty) return null;
      final primaryHash = hashes.first;

      await BlockedImageStorage.saveImage(primaryHash, bytes);

      _cache[imageUrl] = hashes;

      return {
        'pHash': primaryHash,
        'url': imageUrl,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
    } catch (_) {
      return null; // Returns null on failure; caller handles toast
    }
  }

  /// Get cached pHash variants for a URL
  static List<String>? getCachedHashes(String url) => _cache[url];

  /// Clear in-memory cache
  static void clearCache() => _cache.clear();
}
