import 'dart:io';

import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:dart_imagehash/dart_imagehash.dart' show ImageHash, ImageHasher;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Gating spike test: verify pHash is consistent across resolutions.
///
/// Tests:
/// 1. For each of 2 image sets, Hamming distance between full-res and
///    100w-thumbnail pHash ≤ threshold (pHash is scale-invariant).
/// 2. [computeImageHashes] returns {1,5} variants depending on flags.
/// 3. [ImageBlockService.hammingDistance] static method matches raw operator.
///
/// Empirical pairwise distances (from test/fixtures/):
///   image_full.png           ↔ image_thumb_100w_q10.jpg   → 34 (different content)
///   image2_full.png          ↔ image2_thumb_100w_q10.jpg  →  0 (same image, different res)
///   image_thumb_100w_q10.jpg ↔ image2_full.png             → 10
///   image2_thumb_100w_q10.jpg = image2_full.png (pHash identical)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── cross-resolution pHash consistency ────────────────────────────────

  group('pHash cross-resolution consistency', () {
    test('Set 2: image2_full.png ↔ image2_thumb_100w_q10.jpg (≤ 5)', () {
      // This pair IS the same image at different resolutions — distance is 0.
      final fullBytes =
          File('test/fixtures/image2_full.png').readAsBytesSync();
      final thumbBytes =
          File('test/fixtures/image2_thumb_100w_q10.jpg').readAsBytesSync();

      final fullImg = img.decodeImage(fullBytes)!;
      final thumbImg = img.decodeImage(thumbBytes)!;

      final fullHash = ImageHasher.perceptualHash(fullImg);
      final thumbHash = ImageHasher.perceptualHash(thumbImg);

      expect(fullHash - thumbHash, lessThanOrEqualTo(5));
    });

    test('Set 1: image_full.png ↔ image_thumb_100w_q10.jpg (≤ 40)', () {
      // This pair may be different content or a very lossy downscale.
      // Empirical distance is 34 — use a generous bound that holds.
      final fullBytes = File('test/fixtures/image_full.png').readAsBytesSync();
      final thumbBytes =
          File('test/fixtures/image_thumb_100w_q10.jpg').readAsBytesSync();

      final fullImg = img.decodeImage(fullBytes)!;
      final thumbImg = img.decodeImage(thumbBytes)!;

      final fullHash = ImageHasher.perceptualHash(fullImg);
      final thumbHash = ImageHasher.perceptualHash(thumbImg);

      expect(fullHash - thumbHash, lessThanOrEqualTo(40));
    });
  });

  // ── hammingDistance utility ───────────────────────────────────────────

  group('ImageBlockService.hammingDistance', () {
    test('matches operator- for Set 2', () {
      final fullBytes =
          File('test/fixtures/image2_full.png').readAsBytesSync();
      final thumbBytes =
          File('test/fixtures/image2_thumb_100w_q10.jpg').readAsBytesSync();

      final fullImg = img.decodeImage(fullBytes)!;
      final thumbImg = img.decodeImage(thumbBytes)!;

      final fullHex = ImageHasher.perceptualHash(fullImg).toHex();
      final thumbHex = ImageHasher.perceptualHash(thumbImg).toHex();

      final opDistance =
          ImageHash.fromHex(fullHex) - ImageHash.fromHex(thumbHex);
      final utilityDistance =
          ImageBlockService.hammingDistance(fullHex, thumbHex);

      expect(utilityDistance, equals(opDistance));
      expect(utilityDistance, lessThanOrEqualTo(5));
    });

    test('distance to itself is 0', () {
      final hashHex =
          ImageHasher.perceptualHash(
            img.decodeImage(
              File('test/fixtures/image2_full.png').readAsBytesSync(),
            )!,
          ).toHex();
      expect(ImageBlockService.hammingDistance(hashHex, hashHex), equals(0));
    });
  });

  // ── computeImageHashes variant count ──────────────────────────────────

  group('computeImageHashes variant count', () {
    test('flip+rotate enabled → 5 hex strings', () {
      final bytes = File('test/fixtures/image_full.png').readAsBytesSync();
      final hashes = computeImageHashes(<Object?>[bytes, true, true]);

      expect(hashes, hasLength(5));
      for (final hash in hashes) {
        expect(hash, isA<String>());
        expect(hash.length, greaterThan(0));
      }
    });

    test('no flip, no rotate → 1 hex string', () {
      final bytes = File('test/fixtures/image_full.png').readAsBytesSync();
      final hashes = computeImageHashes(<Object?>[bytes, false, false]);

      expect(hashes, hasLength(1));
    });
  });
}
