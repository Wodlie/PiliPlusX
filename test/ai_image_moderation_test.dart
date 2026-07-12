import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_image_moderation_service.dart';
import 'package:PiliPlus/utils/ai_image_state.dart';
import 'package:PiliPlus/utils/ai_inference_engine.dart';
import 'package:PiliPlus/utils/clip_tokenizer_config.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Fake [PathProviderPlatform] for test environments where no platform
/// channel implementation is available.
class _FakePathProviderPlatform extends PathProviderPlatform {
  final String basePath;
  _FakePathProviderPlatform(this.basePath);

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationSupportPath() async => basePath;

  @override
  Future<String?> getTemporaryPath() async => basePath;

  @override
  Future<String?> getLibraryPath() async => basePath;

  @override
  Future<String?> getApplicationCachePath() async => basePath;
}

/// Stub [InferenceSession] for tests that require a full evaluation pipeline.
class _MockInferenceSession implements InferenceSession {
  bool shouldThrow = false;

  /// Dimension of the embeddings this mock returns.
  final int dim;

  /// Optional factory to produce custom vision results per test case.
  /// If null, [runVision] returns a vector that classifies as [AiImageState.blocked]
  /// (first text-embedding segment → highest similarity with MALICIOUS prompt).
  final Float32List Function()? visionResultFactory;

  _MockInferenceSession({
    this.shouldThrow = false,
    this.dim = 384,
    this.visionResultFactory,
  });

  @override
  Future<Float32List> runVision(
    Float32List input, {
    required List<int> shape,
  }) async {
    if (shouldThrow) throw Exception('mock inference error');
    if (visionResultFactory != null) return visionResultFactory!();

    // Default: return first dim entries of Pref.aiTextEmbeddings.
    // After L2-normalization this has highest cosine-sim with textEmbeds[0]
    // (MALICIOUS), so classify() returns AiImageState.blocked.
    final embeds = Pref.aiTextEmbeddings;
    if (embeds.length >= dim * 3) {
      return Float32List(dim)..setRange(0, dim, embeds.sublist(0, dim));
    }
    return Float32List(dim);
  }

  @override
  Future<Float32List> runText(TokenizedText tokens) async {
    if (shouldThrow) throw Exception('mock inference error');
    return Float32List(dim);
  }

  @override
  void dispose() {}
}

/// Default text embedding dimension used in tests (384 = 1152 / 3).
const _defaultDim = 384;
const _defaultEmbeddingLength = _defaultDim * 3; // 1152

/// Create a minimal valid PNG image as [Uint8List] for pre-populating the
/// image cache in full-pipeline tests.
Uint8List _createTestImage({int size = 64}) {
  final image = img.Image(width: size, height: size);
  // Fill with neutral grey pixels
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgba(x, y, 128, 128, 128, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Uint8List _testImageBytes;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_ai_moderation_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    await GStorage.init();
    _testImageBytes = _createTestImage();
  });

  setUp(() {
    // Reset to known defaults before each test
    AiImageModerationService.invalidateCache();
    AiImageModerationService.dispose();
    AiImageModerationService.mockImageBytes = null;
    AiImageModerationService.setMockSession(null);
    AiImageModerationService.onAutoBlock = null;
    Pref.enableAiImageModeration = true;
    Pref.enableImageBlock = true;
    Pref.aiModelDownloaded = true;
    Pref.aiTextEmbeddings = List.filled(_defaultEmbeddingLength, 0.1);
    Pref.aiModelFormat = 'tflite';
    Pref.aiAutoBlocklist = false;
    Pref.imageBlockHashList = [];
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
      'embeddings not divisible by 3 returns normal (fail-open)',
      () async {
        Pref.aiTextEmbeddings = List.filled(100, 0.1);
        final result = await AiImageModerationService.evaluateImage(
          'https://example.com/test.jpg',
        );
        expect(result, equals(AiImageState.normal));
      },
    );

    test(
      '384-dim embeddings accepted without error',
      () async {
        Pref.aiTextEmbeddings = List.generate(1152, (i) => i.toDouble());
        // Downloads will fail in test env, so result is normal (fail-open)
        final result = await AiImageModerationService.evaluateImage(
          'https://example.com/384dim.jpg',
        );
        expect(result, equals(AiImageState.normal));
      },
    );

    test(
      '512-dim embeddings (backward compat) accepted without error',
      () async {
        Pref.aiTextEmbeddings = List.generate(1536, (i) => i.toDouble());
        final result = await AiImageModerationService.evaluateImage(
          'https://example.com/512dim.jpg',
        );
        expect(result, equals(AiImageState.normal));
      },
    );

    test(
      '768-dim embeddings accepted without error',
      () async {
        Pref.aiTextEmbeddings = List.generate(2304, (i) => i.toDouble());
        final result = await AiImageModerationService.evaluateImage(
          'https://example.com/768dim.jpg',
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
      AiImageModerationService.setCachedResult(url, AiImageState.highRisk);
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

    test(
      'URL normalization matches between setCachedResult and getCachedResult',
      () {
        const cleanUrl = 'https://example.com/photo.jpg';
        const formattedUrl = 'https://example.com/photo.jpg@100w_100h.webp';
        AiImageModerationService.setCachedResult(
          cleanUrl,
          AiImageState.blocked,
        );
        final result1 = AiImageModerationService.getCachedResult(formattedUrl);
        expect(result1, equals(AiImageState.blocked));
        final result2 = AiImageModerationService.getCachedResult(cleanUrl);
        expect(result2, equals(AiImageState.blocked));
      },
    );
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
      const url = 'https://i0.hdslb.com/bfs/album/abc.jpg@100w.webp?q=1';
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

  // ── Full pipeline (mock session + mock image bytes) ──────────────────

  group('full pipeline with mocks', () {
    const _testUrl = 'https://example.com/full_pipeline_test.jpg';

    setUp(() {
      AiImageModerationService.setMockSession(_MockInferenceSession());
      AiImageModerationService.mockImageBytes = Uint8List.fromList(
        _testImageBytes,
      );
      AiImageModerationService.onAutoBlock = null;
    });

    test(
      'image/text dim mismatch returns normal (fail-open)',
      () async {
        // 384-dim embeddings but mock returns 512-dim vision embedding
        Pref.aiTextEmbeddings = List.generate(1152, (i) => i.toDouble());
        final mismatchSession = _MockInferenceSession(
          dim: 512,
          visionResultFactory: () => Float32List(512),
        );
        AiImageModerationService.setMockSession(mismatchSession);

        final result = await AiImageModerationService.evaluateImage(_testUrl);
        expect(result, equals(AiImageState.normal));
      },
    );

    test(
      'auto-block ON → onAutoBlock fires with source ai_auto',
      () async {
        Pref.aiAutoBlocklist = true;
        Pref.aiTextEmbeddings = List.generate(1152, (i) => i.toDouble());

        String? capturedUrl;
        String? capturedSource;
        AiImageModerationService.onAutoBlock = (url, source) {
          capturedUrl = url;
          capturedSource = source;
        };

        final result = await AiImageModerationService.evaluateImage(_testUrl);
        expect(result, equals(AiImageState.blocked));
        expect(capturedUrl, contains('full_pipeline_test'));
        expect(capturedSource, equals('ai_auto'));
      },
    );

    test(
      'auto-block fires only once per URL (dedup via result cache)',
      () async {
        Pref.aiAutoBlocklist = true;
        Pref.aiTextEmbeddings = List.generate(1152, (i) => i.toDouble());

        int callCount = 0;
        AiImageModerationService.onAutoBlock = (_, __) {
          callCount++;
        };

        // First call → fires auto-block
        await AiImageModerationService.evaluateImage(_testUrl);
        expect(
          callCount,
          equals(1),
          reason: 'first evaluation should fire auto-block',
        );

        // Result cache hit → second call returns cached, no re-fire
        await AiImageModerationService.evaluateImage(_testUrl);
        expect(
          callCount,
          equals(1),
          reason: 'cached result should not fire auto-block again',
        );
      },
    );

    test(
      'highRisk does NOT fire onAutoBlock',
      () async {
        Pref.aiAutoBlocklist = true;
        Pref.aiTextEmbeddings = List.generate(1152, (i) => i.toDouble());

        bool called = false;
        AiImageModerationService.onAutoBlock = (_, __) {
          called = true;
        };

        // Return the middle text-embedding segment → classifies as highRisk
        const dim = 384;
        final highRiskSession = _MockInferenceSession(
          visionResultFactory: () => Float32List(dim)
            ..setRange(
              0,
              dim,
              Pref.aiTextEmbeddings.sublist(dim, 2 * dim),
            ),
        );
        AiImageModerationService.setMockSession(highRiskSession);

        final result = await AiImageModerationService.evaluateImage(_testUrl);
        expect(result, equals(AiImageState.highRisk));
        expect(
          called,
          isFalse,
          reason: 'highRisk should not trigger auto-block',
        );
      },
    );

    test(
      'auto-block OFF does not fire onAutoBlock',
      () async {
        // aiAutoBlocklist is false by default from setUp
        Pref.aiTextEmbeddings = List.generate(1152, (i) => i.toDouble());

        bool called = false;
        AiImageModerationService.onAutoBlock = (_, __) {
          called = true;
        };

        final result = await AiImageModerationService.evaluateImage(_testUrl);
        expect(result, equals(AiImageState.blocked));
        expect(called, isFalse, reason: 'no auto-block when setting is OFF');
      },
    );
  });
}
