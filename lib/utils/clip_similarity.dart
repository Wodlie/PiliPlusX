import 'package:PiliPlus/utils/ai_image_state.dart';
import 'dart:typed_data';

/// CLIP zero-shot image classification utilities.
abstract final class ClipSimilarity {
  /// Compute cosine similarity between two vectors.
  /// Handles zero-norm edge case (returns 0.0).
  static double cosineSimilarity(Float32List a, Float32List b) {
    final int len = a.length;
    if (len == 0 || b.length != len) return 0.0;

    double dot = 0.0, normA = 0.0, normB = 0.0;
    for (int i = 0; i < len; i++) {
      final ai = a[i];
      final bi = b[i];
      dot += ai * bi;
      normA += ai * ai;
      normB += bi * bi;
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  /// Return index of highest score. Tie-break: return first occurrence.
  static int argmax(List<double> scores) {
    if (scores.isEmpty) return -1;
    int maxIdx = 0;
    double maxVal = scores[0];
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > maxVal) {
        maxVal = scores[i];
        maxIdx = i;
      }
    }
    return maxIdx;
  }

  /// Classify image embedding against 3 text embeddings (MALICIOUS, high-risk, normal).
  /// Returns (state, confidence) where confidence is the cosine similarity score.
  /// Index 0 → AiImageState.blocked (MALICIOUS)
  /// Index 1 → AiImageState.lowRes (high-risk)
  /// Index 2 → AiImageState.normal (normal)
  static (AiImageState, double) classify(
    Float32List imageEmbed,
    List<Float32List> textEmbeds,
  ) {
    assert(textEmbeds.length == 3,
        'textEmbeds must contain exactly 3 entries (MALICIOUS, high-risk, normal)');

    final scores = <double>[
      cosineSimilarity(imageEmbed, textEmbeds[0]),
      cosineSimilarity(imageEmbed, textEmbeds[1]),
      cosineSimilarity(imageEmbed, textEmbeds[2]),
    ];

    final bestIdx = argmax(scores);
    final state = switch (bestIdx) {
      0 => AiImageState.blocked,
      1 => AiImageState.lowRes,
      2 => AiImageState.normal,
      _ => AiImageState.normal,
    };

    return (state, scores[bestIdx]);
  }

  /// Square root via Newton's method (no dart:math dependency).
  static double sqrt(double x) {
    if (x < 0) return double.nan;
    if (x == 0) return 0.0;
    double guess = x;
    for (int i = 0; i < 20; i++) {
      guess = (guess + x / guess) * 0.5;
    }
    return guess;
  }
}
