import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_image_moderation_service.dart';
import 'package:PiliPlus/utils/ai_image_state.dart';
import 'package:PiliPlus/utils/ai_inference_engine.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stub [InferenceSession] for tests that require a full evaluation pipeline.
class _MockInferenceSession implements InferenceSession {
  bool shouldThrow = false;
  final Float32List _unitVector;

  _MockInferenceSession({this.shouldThrow = false})
      : _unitVector = _makeUnitVector();

  static Float32List _makeUnitVector() {
    final v = Float32List(512);
    v[0] = 1.0; // unit-norm: only first component is non-zero
    return v;
  }

  @override
  Future<Float32List> runVision(Float32List input) async {
    if (shouldThrow) throw Exception('mock inference error');
    return Float32List.fromList(_unitVector);
  }

  @override
  Future<Float32List> runText(List<int> tokenIds) async {
    return Float32List(512);
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_ai_moderation_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() {
    // Reset to known defaults before each test
    AiImageModerationService.invalidateCache();
    AiImageModerationService.dispose();
    Pref.enableAiImageModeration = true;
    Pref.enableImageBlock = true;
    Pref.aiModelDownloaded = true;
    Pref.aiTextEmbeddings = List.filled(1536, 0.1);
    Pref.aiModelFormat = 'tflite';
    Pref.aiAutoBlocklist = false;
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ── Disabled / fail-open early returns ──────────────────────────────

  group('disabled / fail-open early returns', () {
    test('AI moderation disabled returns normal (zero overhead)', () async {
      Pref.enableAiImageModeration = false;
      final result = await AiImageModerationService.evaluateImage(
        'https://example.com/test.jpg',
      );
      expect(result, equals(AiImageState.normal));
    });

    test('pHash disabled returns normal (zero overhead)', () async {
      Pref.enableImageBlock = false;
      final result = await AiImageModerationService.evaluateImage(
        'https://example.com/test.jpg',
      );
      expect(result, equals(AiImageState.normal));
    });

    test('no model downloaded returns normal (fail-open)', () async {
      Pref.aiModelDownloaded = false;
      final result = await AiImageModerationService.evaluateImage(
        'https://example.com/test.jpg',
      );
      expect(result, equals(AiImageState.normal));
    });

    test('no text embeddings returns normal (fail-open)', () async {
      Pref.aiTextEmbeddings = <double>[];
      final result = await AiImageModerationService.evaluateImage(
        'https://example.com/test.jpg',
      );
      expect(result, equals(AiImageState.normal));
    });

    test(
      'embeddings shorter than 1536 returns normal (fail-open)',
      () async {
        Pref.aiTextEmbeddings = List.filled(1000, 0.1);
        final result = await AiImageModerationService.evaluateImage(
          'https://example.com/test.jpg',
        );
        expect(result, equals(AiImageState.normal));
      },
    );
  });

  // ── Cache behaviour ─────────────────────────────────────────────────

  group('cache behaviour', () {
    test('getCachedResult returns null for unknown URL', () {
      final result = AiImageModerationService.getCachedResult(
        'https://example.com/unknown.jpg',
      );
      expect(result, isNull);
    });

    test('getCachedResult returns cached value after setCachedResult', () {
      const url = 'https://example.com/cached.jpg';
      AiImageModerationService.setCachedResult(url, AiImageState.blocked);
      final result = AiImageModerationService.getCachedResult(url);
      expect(result, equals(AiImageState.blocked));
    });

    test('getCachedResult returns null after invalidateCache', () {
      const url = 'https://example.com/to_invalidate.jpg';
      AiImageModerationService.setCachedResult(url, AiImageState.lowRes);
      AiImageModerationService.invalidateCache();
      final result = AiImageModerationService.getCachedResult(url);
      expect(result, isNull);
    });

    test('evaluateImage returns cached result without re-evaluation', () async {
      const url = 'https://example.com/precached.jpg';
      AiImageModerationService.setCachedResult(url, AiImageState.blocked);
      // Even though Pref allows full evaluation, the cache hit should
      // return immediately without hitting dependencies.
      final result = await AiImageModerationService.evaluateImage(url);
      expect(result, equals(AiImageState.blocked));
    });

    test('URL normalization matches between setCachedResult and getCachedResult',
        () {
      const cleanUrl = 'https://example.com/photo.jpg';
      const formattedUrl =
          'https://example.com/photo.jpg@100w_100h.webp';
      AiImageModerationService.setCachedResult(cleanUrl, AiImageState.blocked);
      final result1 = AiImageModerationService.getCachedResult(formattedUrl);
      expect(result1, equals(AiImageState.blocked));
      final result2 = AiImageModerationService.getCachedResult(cleanUrl);
      expect(result2, equals(AiImageState.blocked));
    });
  });

  // ── URL normalization ───────────────────────────────────────────────

  group('normalizeUrl', () {
    test('URL with no @ or ? is returned unchanged', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg';
      expect(AiImageModerationService.normalizeUrl(url), equals(url));
    });

    test('strips format params after @', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg@100w_100h.webp';
      expect(
        AiImageModerationService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('strips query params after ?', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg?param=1';
      expect(
        AiImageModerationService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('strips at @ when @ appears before ?', () {
      const url =
          'https://i0.hdslb.com/bfs/album/abc.jpg@100w.webp?q=1';
      expect(
        AiImageModerationService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });

    test('strips at ? when ? appears before @', () {
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg?q=1@100w';
      expect(
        AiImageModerationService.normalizeUrl(url),
        equals('https://i0.hdslb.com/bfs/album/abc.jpg'),
      );
    });
  });

  // ── Full pipeline fail-open ─────────────────────────────────────────

  group('full pipeline fail-open', () {
    test(
      'evaluateImage with full pipeline returns normal on download error',
      () async {
        // Everything enabled — will reach _evaluateFresh, fail at download,
        // catch exception, return normal.
        final result = await AiImageModerationService.evaluateImage(
          'https://example.com/nonexistent.jpg',
        );
        expect(result, equals(AiImageState.normal));
      },
    );
  });

  // ── In-flight dedup ─────────────────────────────────────────────────

  group('in-flight dedup', () {
    test(
      '5 concurrent evaluateImage(sameUrl) all return same result',
      () async {
        final futures = List.generate(
          5,
          (_) => AiImageModerationService.evaluateImage(
            'https://example.com/concurrent.jpg',
          ),
        );
        final results = await Future.wait(futures);
        for (final result in results) {
          // All should return normal (download fails in test env)
          expect(result, equals(AiImageState.normal));
        }
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  // ── Disposal ────────────────────────────────────────────────────────

  group('dispose', () {
    test('dispose clears caches and session', () {
      const url = 'https://example.com/dispose_test.jpg';
      AiImageModerationService.setCachedResult(url, AiImageState.blocked);

      // Should not throw
      AiImageModerationService.dispose();

      // Cache should be empty after dispose
      expect(
        AiImageModerationService.getCachedResult(url),
        isNull,
        reason: 'cache should be cleared after dispose',
      );
    });
  });

  // ── LRU cache capacity ──────────────────────────────────────────────

  group('LRU cache (via image_block_service_test)', () {
    test('500 entry limit is maintained for result cache', () {
      // Fill with 501 entries — oldest should be evicted
      for (int i = 0; i < 501; i++) {
        AiImageModerationService.setCachedResult(
          'https://example.com/img_$i.jpg',
          AiImageState.normal,
        );
      }
      // Entry 0 should be evicted
      expect(
        AiImageModerationService.getCachedResult(
          'https://example.com/img_0.jpg',
        ),
        isNull,
        reason: 'oldest entry (img_0) should be evicted',
      );
      // Entry 500 should be present
      expect(
        AiImageModerationService.getCachedResult(
          'https://example.com/img_500.jpg',
        ),
        equals(AiImageState.normal),
        reason: 'newest entry (img_500) should be present',
      );
    });
  });

  // ── Mock session ────────────────────────────────────────────────────

  group('mock session integration', () {
    test('setMockSession allows injection of test session', () async {
      final mockSession = _MockInferenceSession();
      AiImageModerationService.setMockSession(mockSession);

      // With all Pref flags set and a mock session, the pipeline should
      // reach _evaluateFresh → download (fails) → catch → return normal.
      // The session is not reached because download fails first.
      // This test verifies the mock session is accepted without error.
      expect(
        () => AiImageModerationService.setMockSession(mockSession),
        returnsNormally,
      );

      // Reset to null (lazy-loaded behaviour)
      AiImageModerationService.setMockSession(null);
    });
  });
}
