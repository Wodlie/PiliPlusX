import 'dart:typed_data';

import 'package:PiliPlus/utils/ai_image_state.dart';
import 'package:PiliPlus/utils/clip_similarity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── cosineSimilarity ─────────────────────────────────────────

  group('cosineSimilarity', () {
    test('identical vectors → 1.0', () {
      final a = Float32List.fromList([1.0, 0.0, 0.0]);
      final b = Float32List.fromList([1.0, 0.0, 0.0]);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(1.0, 1e-6));
    });

    test('orthogonal vectors → 0.0', () {
      final a = Float32List.fromList([1.0, 0.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0, 0.0]);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(0.0, 1e-6));
    });

    test('opposite vectors → -1.0', () {
      final a = Float32List.fromList([1.0, 0.0, 0.0]);
      final b = Float32List.fromList([-1.0, 0.0, 0.0]);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(-1.0, 1e-6));
    });

    test('zero-norm vector → 0.0', () {
      final a = Float32List.fromList([0.0, 0.0, 0.0]);
      final b = Float32List.fromList([1.0, 0.0, 0.0]);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(0.0, 1e-6));
    });

    test('mismatched lengths → 0.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([1.0, 0.0, 0.0]);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(0.0, 1e-6));
    });

    test('empty vectors → 0.0', () {
      final a = Float32List.fromList([]);
      final b = Float32List.fromList([]);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(0.0, 1e-6));
    });

    // Verify dimension-agnostic: same result with larger vectors
    test('100-dim identical vectors → 1.0', () {
      final a = Float32List(100)..fillRange(0, 100, 0.5);
      final b = Float32List(100)..fillRange(0, 100, 0.5);
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(1.0, 1e-6));
    });

    test('non-trivial angle', () {
      final a = Float32List.fromList([3.0, 4.0]);
      final b = Float32List.fromList([4.0, 3.0]);
      // dot = 3*4 + 4*3 = 24
      // ||a|| = 5, ||b|| = 5
      // cos = 24/25 = 0.96
      final result = ClipSimilarity.cosineSimilarity(a, b);
      expect(result, closeTo(0.96, 1e-6));
    });
  });

  // ── argmax ────────────────────────────────────────────────────

  group('argmax', () {
    test('clear winner [0.1, 0.5, 0.3] → index 1', () {
      final scores = [0.1, 0.5, 0.3];
      expect(ClipSimilarity.argmax(scores), 1);
    });

    test('tie [0.5, 0.5, 0.3] → index 0 (first occurrence)', () {
      final scores = [0.5, 0.5, 0.3];
      expect(ClipSimilarity.argmax(scores), 0);
    });

    test('all equal → index 0', () {
      final scores = [0.7, 0.7, 0.7];
      expect(ClipSimilarity.argmax(scores), 0);
    });

    test('descending [1.0, 0.5, 0.0] → index 0', () {
      final scores = [1.0, 0.5, 0.0];
      expect(ClipSimilarity.argmax(scores), 0);
    });

    test('ascending [0.0, 0.5, 1.0] → index 2', () {
      final scores = [0.0, 0.5, 1.0];
      expect(ClipSimilarity.argmax(scores), 2);
    });

    test('empty list → -1', () {
      expect(ClipSimilarity.argmax(<double>[]), -1);
    });

    test('single element → 0', () {
      expect(ClipSimilarity.argmax([42.0]), 0);
    });
  });

  // ── classify ──────────────────────────────────────────────────

  group('classify', () {
    late Float32List malEmbed;
    late Float32List highRiskEmbed;
    late Float32List normalEmbed;
    late List<Float32List> textEmbeds;

    setUp(() {
      // textEmbeds[0] = MALICIOUS template
      malEmbed = Float32List.fromList([1.0, 0.0, 0.0]);
      // textEmbeds[1] = high-risk template
      highRiskEmbed = Float32List.fromList([0.0, 1.0, 0.0]);
      // textEmbeds[2] = normal template
      normalEmbed = Float32List.fromList([0.0, 0.0, 1.0]);
      textEmbeds = [malEmbed, highRiskEmbed, normalEmbed];
    });

    test('matches MALICIOUS → AiImageState.blocked', () {
      final (state, confidence) = ClipSimilarity.classify(malEmbed, textEmbeds);
      expect(state, AiImageState.blocked);
      expect(confidence, closeTo(1.0, 1e-6));
    });

    test('matches high-risk → AiImageState.highRisk', () {
      final (state, confidence) = ClipSimilarity.classify(
        highRiskEmbed,
        textEmbeds,
      );
      expect(state, AiImageState.highRisk);
      expect(confidence, closeTo(1.0, 1e-6));
    });

    test('matches normal → AiImageState.normal', () {
      final (state, confidence) = ClipSimilarity.classify(
        normalEmbed,
        textEmbeds,
      );
      expect(state, AiImageState.normal);
      expect(confidence, closeTo(1.0, 1e-6));
    });

    test(
      'ambiguous embedding (equidistant) → AiImageState.blocked (first)',
      () {
        // equally similar to all three → argmax picks first → blocked
        final ambiguous = Float32List.fromList([0.5, 0.5, 0.5]);
        final (state, _) = ClipSimilarity.classify(ambiguous, textEmbeds);
        expect(state, AiImageState.blocked);
      },
    );

    test('partial match high-risk → AiImageState.highRisk', () {
      // Slightly closer to highRisk (index 1) but not pure
      final mixed = Float32List.fromList([0.1, 0.9, 0.2]);
      final (state, confidence) = ClipSimilarity.classify(mixed, textEmbeds);
      expect(state, AiImageState.highRisk);
      expect(confidence, greaterThan(0.0));
    });
  });
}
