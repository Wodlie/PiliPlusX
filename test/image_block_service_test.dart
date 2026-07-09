import 'dart:io';

import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dart_imagehash/dart_imagehash.dart' show ImageHash;
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
      expect(parsed, hasLength(1), reason: 'should re-parse after invalidation');
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
      expect(blocked, isTrue,
          reason: 'identical hash with threshold 0 should block');

      // Different variant → not blocked
      final notBlocked = ImageBlockService.isBlocked(
        ['ffffffffffffffff'],
        <Map<String, dynamic>>[],
        0,
      );
      expect(notBlocked, isFalse,
          reason: 'different hash should not block');
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
      expect(result, isFalse,
          reason: 'blocking disabled should not block');
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

    test('BiliBili CDN with format and query: replaces format, keeps query',
        () {
      final result = ImageBlockService.thumbnailUrlForHash(
        'https://i0.hdslb.com/bfs/album/abc.jpg@200w_200h.webp?token=abc123',
      );
      expect(
        result,
        'https://i0.hdslb.com/bfs/album/abc.jpg@100w_1q.webp?token=abc123',
      );
    });
  });
}
