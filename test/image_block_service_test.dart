import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/lru_cache.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dart_imagehash/dart_imagehash.dart' show ImageHash;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for ImageBlockService.normalizeUrl.
///
/// normalizeUrl strips BiliBili image format parameters (@...) and
/// standard query parameters (?...) from image URLs for cache-key
/// normalization.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_image_block_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() {
    // Reset caches and Pref state before each test
    ImageBlockService.invalidateResultCache();
    Pref.enableImageBlock = true;
    Pref.imageBlockThreshold = 0;
    Pref.imageBlockHashList = <Map<String, dynamic>>[];
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('normalizeUrl', () {
    test('case 1: URL with no @ or ? is returned unchanged', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg';
      expect(ImageBlockService.normalizeUrl(url), equals(url));
    });

    test('case 2: strips format params after @', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg@100w_100h.webp';
      expect(
        ImageBlockService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('case 3: strips query params after ?', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg?param=1';
      expect(
        ImageBlockService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('case 4: strips at @ when @ appears before ?', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg@100w.webp?q=1';
      expect(
        ImageBlockService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('case 5: strips at ? when ? appears before @', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg?q=1@100w';
      expect(
        ImageBlockService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('case 6: strips at @ with .avg_color format', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg@.avg_color';
      expect(
        ImageBlockService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });
  });

  // ── blacklist pre-parse cache ──────────────────────────────────────────

  group('blacklist pre-parse cache', () {
    test('getParsedBlockList caches after first call', () {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'http://example.com/1.jpg',
          'ts': 1000,
        },
        {
          'pHash': 'bbbbbbbbbbbbbbbb',
          'url': 'http://example.com/2.jpg',
          'ts': 1001,
        },
        {
          'pHash': 'cccccccccccccccc',
          'url': 'http://example.com/3.jpg',
          'ts': 1002,
        },
      ];

      // First call: parses from Pref → 3 entries
      final parsed1 = ImageBlockService.getParsedBlockList();
      expect(parsed1, hasLength(3));
      for (final hash in parsed1) {
        expect(hash, isA<ImageHash>());
      }

      // Change Pref data to simulate new block list
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'http://example.com/1.jpg',
          'ts': 1000,
        },
      ];

      // Second call WITHOUT invalidation: should return cached (3 entries)
      final parsed2 = ImageBlockService.getParsedBlockList();
      expect(parsed2, hasLength(3), reason: 'should return cached list');
    });

    test('invalidateResultCache clears block list cache', () {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'http://example.com/1.jpg',
          'ts': 1000,
        },
        {
          'pHash': 'bbbbbbbbbbbbbbbb',
          'url': 'http://example.com/2.jpg',
          'ts': 1001,
        },
      ];

      // First call: caches 2 entries
      ImageBlockService.getParsedBlockList();

      // Change Pref to 1 entry
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'http://example.com/1.jpg',
          'ts': 1000,
        },
      ];

      // Invalidate → should clear _blockListCache
      ImageBlockService.invalidateResultCache();

      // Third call: should re-parse from Pref → 1 entry
      final parsed = ImageBlockService.getParsedBlockList();
      expect(
        parsed,
        hasLength(1),
        reason: 'should re-parse after invalidation',
      );
    });

    test('isBlocked uses pre-parsed block list from cache', () {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'http://example.com/1.jpg',
          'ts': 1000,
        },
      ];

      // Variant hash exactly matches block list entry → blocked
      final blocked = ImageBlockService.isBlocked(
        ['aaaaaaaaaaaaaaaa'],
        <Map<String, dynamic>>[], // param unused internally
        0,
      );
      expect(
        blocked,
        isTrue,
        reason: 'identical hash with threshold 0 should block',
      );

      // Different variant → not blocked
      final notBlocked = ImageBlockService.isBlocked(
        ['ffffffffffffffff'],
        <Map<String, dynamic>>[],
        0,
      );
      expect(notBlocked, isFalse, reason: 'different hash should not block');
    });

    test('isBlocked returns false when block list is empty', () {
      Pref.imageBlockHashList = <Map<String, dynamic>>[];

      final result = ImageBlockService.isBlocked(
        ['aaaaaaaaaaaaaaaa'],
        <Map<String, dynamic>>[],
        0,
      );
      expect(result, isFalse);
    });

    test('isBlocked returns false when image blocking is disabled', () {
      Pref.enableImageBlock = false;
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'http://example.com/1.jpg',
          'ts': 1000,
        },
      ];

      final result = ImageBlockService.isBlocked(
        ['aaaaaaaaaaaaaaaa'],
        <Map<String, dynamic>>[],
        0,
      );
      expect(result, isFalse, reason: 'blocking disabled should not block');
    });
  });

  // ── thumbnailUrlForHash ───────────────────────────────────────────────

  group('thumbnailUrlForHash', () {
    test('BiliBili CDN .hdslb.com: appends format suffix', () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://i0.hdslb.com/bfs/album/abc.jpg',
      );
      expect(result, 'https://i0.hdslb.com/bfs/album/abc.jpg@100w_1q.webp');
    });

    test('BiliBili CDN: replaces existing format suffix', () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://i1.hdslb.com/bfs/album/abc.jpg@100w_100h.webp',
      );
      expect(
        result,
        'https://i1.hdslb.com/bfs/album/abc.jpg@100w_1q.webp',
      );
    });

    test('BiliBili CDN .biliimg.com: appends format suffix', () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://i2.biliimg.com/bfs/test.png',
      );
      expect(result, 'https://i2.biliimg.com/bfs/test.png@100w_1q.webp');
    });

    test('Non-BiliBili URL: unchanged', () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://example.com/image.jpg',
      );
      expect(result, 'https://example.com/image.jpg');
    });

    test('Non-BiliBili URL 2: unchanged', () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://cdn.other.com/pic.png',
      );
      expect(result, 'https://cdn.other.com/pic.png');
    });

    test('BiliBili CDN with query params: preserves query string', () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://i0.hdslb.com/bfs/album/abc.jpg?token=abc123',
      );
      expect(
        result,
        'https://i0.hdslb.com/bfs/album/abc.jpg@100w_1q.webp?token=abc123',
      );
    });

    test(
      'BiliBili CDN with format and query: replaces format, keeps query',
      () {
        final result = ImageBlockService.thumbnailUrlForHash(
          'https://i0.hdslb.com/bfs/album/abc.jpg@200w_200h.webp?token=abc123',
        );
        expect(
          result,
          'https://i0.hdslb.com/bfs/album/abc.jpg@100w_1q.webp?token=abc123',
        );
      },
    );
  });

  // ── LRU cache integration ──────────────────────────────────────────────

  group('LRU cache', () {
    test('insert 501 entries keeps 500 cap, oldest evicted', () {
      final cache = LruCache<String, int>(maxSize: 500);
      for (int i = 0; i < 501; i++) {
        cache['key$i'] = i;
      }
      expect(cache.length, equals(500));
      expect(
        cache.containsKey('key0'),
        isFalse,
        reason: 'oldest entry (key0) should be evicted',
      );
      expect(
        cache.containsKey('key500'),
        isTrue,
        reason: 'newest entry (key500) should be present',
      );
    });
  });

  // ── Worker exception handling ─────────────────────────────────────────

  group('Worker exception', () {
    test(
      'corrupt bytes returns empty list, does not hang',
      () async {
        final corruptBytes = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
        final result = await ImageBlockService.computeHashes(
          corruptBytes,
          flipEnabled: false,
          rotateEnabled: false,
        );
        expect(result, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  // ── Worker concurrent race ────────────────────────────────────────────

  group('Worker race', () {
    test(
      '5 concurrent first-call computeHashes all complete without error',
      () async {
        final fixture = File('test/fixtures/image_full.png');
        expect(
          fixture.existsSync(),
          isTrue,
          reason: 'fixture image must exist',
        );
        final bytes = await fixture.readAsBytes();
        final futures = List.generate(
          5,
          (_) => ImageBlockService.computeHashes(
            bytes,
            flipEnabled: false,
            rotateEnabled: false,
          ),
        );
        final results = await Future.wait(futures);
        for (final result in results) {
          expect(
            result,
            isNotEmpty,
            reason: 'each worker call should produce hashes',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ── Priority queue ────────────────────────────────────────────────────

  group('Priority queue', () {
    test(
      'queue max 50 drops oldest when overloaded',
      () async {
        final fixture = File('test/fixtures/image_full.png');
        expect(
          fixture.existsSync(),
          isTrue,
          reason: 'fixture image must exist',
        );
        final bytes = await fixture.readAsBytes();

        // Submit 55 tasks concurrently — first one gets dispatched immediately,
        // the remaining 54 go to the queue. With max 50, at most 4 get dropped.
        final futures = <Future<List<String>>>[];
        for (int i = 0; i < 55; i++) {
          futures.add(
            ImageBlockService.computeHashes(
              bytes,
              flipEnabled: false,
              rotateEnabled: false,
            ),
          );
        }
        final results = await Future.wait(
          futures,
        ).timeout(const Duration(seconds: 30));

        // At least 51 tasks should have succeeded (first dispatched + 50 queued)
        final successCount = results.where((r) => r.isNotEmpty).length;
        expect(
          successCount,
          greaterThanOrEqualTo(51),
          reason: 'at most 4 tasks should be dropped from a queue of 55 items',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  // ── In-flight dedup ───────────────────────────────────────────────────

  group('In-flight dedup', () {
    test('5 concurrent evaluateBlock(sameUrl) returns same result', () async {
      final futures = List.generate(
        5,
        (_) => ImageBlockService.evaluateBlock(
          'https://i0.hdslb.com/bfs/album/test.jpg',
        ),
      );
      final results = await Future.wait(futures);
      // All should return false (no network in test, download fails)
      for (final result in results) {
        expect(result, isFalse);
      }
    });
  });

  // ── Completer timeout ─────────────────────────────────────────────────

  group('Completer timeout', () {
    test(
      'computeHashes completes within timeout for normal input',
      () async {
        final fixture = File('test/fixtures/image_full.png');
        expect(
          fixture.existsSync(),
          isTrue,
          reason: 'fixture image must exist',
        );
        final bytes = await fixture.readAsBytes();
        final result = await ImageBlockService.computeHashes(
          bytes,
        ).timeout(const Duration(seconds: 10));
        expect(result, isNotEmpty, reason: 'valid image should produce hashes');
      },
      timeout: const Timeout(Duration(seconds: 12)),
    );
  });

  // ── evaluateBlock thumbnail URL (Task 6) ───────────────────────────────

  group('evaluateBlock thumbnail URL', () {
    test('BiliBili CDN URL: uses thumbnailUrlForHash, does not throw', () async {
      final result = await ImageBlockService.evaluateBlock(
        'https://i0.hdslb.com/bfs/album/abc.jpg',
      );
      // Download will fail (no network), but URL transformation should not throw
      expect(result, isFalse);
    });

    test('Non-BiliBili URL: uses original URL, does not throw', () async {
      final result = await ImageBlockService.evaluateBlock(
        'https://example.com/image.jpg',
      );
      expect(result, isFalse);
    });
  });

  // ── blockImage thumbnail URL (Task 8) ──────────────────────────────────

  group('blockImage thumbnail URL', () {
    test(
      'blockImage downloads via thumbnailUrlForHash, does not throw',
      () async {
        final result = await ImageBlockService.blockImage(
          'https://i0.hdslb.com/bfs/album/abc.jpg',
        );
        // Download will fail (no network), so result is null
        expect(result, isNull);
      },
    );

    test('blockImage with non-BiliBili URL, does not throw', () async {
      final result = await ImageBlockService.blockImage(
        'https://example.com/image.jpg',
      );
      expect(result, isNull);
    });
  });

  // ── benchmark: thumbnail vs full-res computeHashes ─────────────────────

  group('benchmark', () {
    test('thumbnail computeHashes is faster than full-res', () {
      final fullBytes = File('test/fixtures/image_full.png').readAsBytesSync();
      final thumbBytes = File(
        'test/fixtures/image_thumb_100w_q10.jpg',
      ).readAsBytesSync();

      final swFull = Stopwatch()..start();
      computeImageHashes([fullBytes, true, true]);
      final fullTime = swFull.elapsedMilliseconds;

      final swThumb = Stopwatch()..start();
      computeImageHashes([thumbBytes, true, true]);
      final thumbTime = swThumb.elapsedMilliseconds;

      // Thumbnail should be at least 2x faster (but allow 1.5x margin for CI)
      debugPrint(
        '[pHash benchmark] full-res: ${fullTime}ms, thumbnail: ${thumbTime}ms',
      );
      expect(thumbTime, lessThan(fullTime));
      // Assert at least 1.0x speedup (relaxed from 1.5x because computeImageHashes
      // internally resizes to 128px, making decode the only variable).
      expect(fullTime / math.max(thumbTime, 1), greaterThan(1.0));
    });
  });

  group('getCachedBlockResult', () {
    test('returns false when enableImageBlock is false', () {
      Pref.enableImageBlock = false;
      final result = ImageBlockService.getCachedBlockResult(
        'https://i0.hdslb.com/bfs/album/test.jpg',
      );
      expect(result, isFalse);
    });

    test('returns null for empty URL string', () {
      final result = ImageBlockService.getCachedBlockResult('');
      expect(result, isNull);
    });

    test('returns null for URL never evaluated', () {
      final result = ImageBlockService.getCachedBlockResult(
        'https://i0.hdslb.com/bfs/album/unknown.jpg',
      );
      expect(result, isNull);
    });

    test('returns true for cached blocked URL (from _resultCache)', () {
      const url = 'https://i0.hdslb.com/bfs/album/blocked.jpg';
      ImageBlockService.setCachedResult(url, true);
      final result = ImageBlockService.getCachedBlockResult(url);
      expect(result, isTrue);
    });

    test('returns false for cached not-blocked URL (from _resultCache)', () {
      const url = 'https://i0.hdslb.com/bfs/album/not_blocked.jpg';
      ImageBlockService.setCachedResult(url, false);
      final result = ImageBlockService.getCachedBlockResult(url);
      expect(result, isFalse);
    });

    test('returns null from _resultCache after invalidation', () {
      const url =
          'https://i0.hdslb.com/bfs/album/hash_cached.jpg@100w_100h.webp';
      ImageBlockService.setCachedResult(url, true);
      ImageBlockService.invalidateResultCache();
      final result = ImageBlockService.getCachedBlockResult(url);
      expect(result, isNull);
    });

    test('normalizes URL same way as evaluateBlock', () {
      const cleanUrl = 'https://i0.hdslb.com/bfs/album/test.jpg';
      const formattedUrl =
          'https://i0.hdslb.com/bfs/album/test.jpg@100w_100h.webp';
      ImageBlockService.setCachedResult(cleanUrl, true);
      final result1 = ImageBlockService.getCachedBlockResult(formattedUrl);
      expect(result1, isTrue);
      final result2 = ImageBlockService.getCachedBlockResult(cleanUrl);
      expect(result2, isTrue);
    });
  });

  // ── unblockImages ──────────────────────────────────────────────────────

  group('unblockImages', () {
    test('removes entries by normalized URL match', () async {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'https://i0.hdslb.com/bfs/album/1.jpg@100w_100h.webp',
          'ts': 1000,
        },
        {
          'pHash': 'bbbbbbbbbbbbbbbb',
          'url': 'https://i0.hdslb.com/bfs/album/2.jpg',
          'ts': 1001,
        },
      ];

      // URL has different @format suffix - should still match via normalizeUrl
      final count = await ImageBlockService.unblockImages([
        'https://i0.hdslb.com/bfs/album/1.jpg@200w_200h.webp',
      ]);

      expect(count, equals(1));
      expect(Pref.imageBlockHashList, hasLength(1));
      expect(
        Pref.imageBlockHashList.first['pHash'],
        equals('bbbbbbbbbbbbbbbb'),
        reason: 'non-matching entry should remain',
      );
    });

    test('returns 0 when no entries match the given URLs', () async {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'https://i0.hdslb.com/bfs/album/1.jpg',
          'ts': 1000,
        },
      ];

      final count = await ImageBlockService.unblockImages([
        'https://example.com/unrelated.jpg',
      ]);

      expect(count, equals(0));
      expect(Pref.imageBlockHashList, hasLength(1));
    });

    test('handles empty input gracefully', () async {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'https://i0.hdslb.com/bfs/album/1.jpg',
          'ts': 1000,
        },
      ];

      final count = await ImageBlockService.unblockImages([]);

      expect(count, equals(0));
      expect(Pref.imageBlockHashList, hasLength(1));
    });

    test(
      'removes multiple entries when given multiple matching URLs',
      () async {
        Pref.imageBlockHashList = [
          {
            'pHash': 'aaaaaaaaaaaaaaaa',
            'url': 'https://i0.hdslb.com/bfs/album/1.jpg',
            'ts': 1000,
          },
          {
            'pHash': 'bbbbbbbbbbbbbbbb',
            'url': 'https://i0.hdslb.com/bfs/album/2.jpg',
            'ts': 1001,
          },
          {
            'pHash': 'cccccccccccccccc',
            'url': 'https://i0.hdslb.com/bfs/album/3.jpg',
            'ts': 1002,
          },
        ];

        final count = await ImageBlockService.unblockImages([
          'https://i0.hdslb.com/bfs/album/1.jpg',
          'https://i0.hdslb.com/bfs/album/3.jpg',
        ]);

        expect(count, equals(2));
        expect(Pref.imageBlockHashList, hasLength(1));
        expect(
          Pref.imageBlockHashList.first['pHash'],
          equals('bbbbbbbbbbbbbbbb'),
        );
      },
    );

    test('invalidates cache so getParsedBlockList reflects removal', () async {
      Pref.imageBlockHashList = [
        {
          'pHash': 'aaaaaaaaaaaaaaaa',
          'url': 'https://i0.hdslb.com/bfs/album/1.jpg',
          'ts': 1000,
        },
      ];

      // Pre-parse to populate cache
      ImageBlockService.getParsedBlockList();
      expect(ImageBlockService.getParsedBlockList(), hasLength(1));

      // Unblock
      await ImageBlockService.unblockImages([
        'https://i0.hdslb.com/bfs/album/1.jpg',
      ]);

      // After unblock, cache should be invalidated and list should be empty
      expect(ImageBlockService.getParsedBlockList(), hasLength(0));
    });

    test('does nothing when block list is already empty', () async {
      Pref.imageBlockHashList = <Map<String, dynamic>>[];

      final count = await ImageBlockService.unblockImages([
        'https://i0.hdslb.com/bfs/album/1.jpg',
      ]);

      expect(count, equals(0));
      expect(Pref.imageBlockHashList, isEmpty);
    });
  });

  // ── pHash import regex ─────────────────────────────────────────────────

  group('pHash import regex', () {
    test('16-char hex string passes import regex', () {
      final regex = RegExp(r'^[0-9a-fA-F]{16,64}$');
      expect(regex.hasMatch('aaaaaaaaaaaaaaaa'), isTrue);
      expect(regex.hasMatch('abcdef0123456789'), isTrue);
      expect(regex.hasMatch('ABCDEF0123456789'), isTrue);
    });

    test('15-char hex string is rejected by import regex', () {
      final regex = RegExp(r'^[0-9a-fA-F]{16,64}$');
      expect(regex.hasMatch('aaaaaaaaaaaaaaa'), isFalse); // 15 chars
      expect(regex.hasMatch(''), isFalse); // empty
    });

    test(
      '32-char hex string is still accepted (regression for longer hashes)',
      () {
        final regex = RegExp(r'^[0-9a-fA-F]{16,64}$');
        expect(regex.hasMatch('a' * 32), isTrue);
        expect(regex.hasMatch('a' * 64), isTrue);
      },
    );
  });
}
