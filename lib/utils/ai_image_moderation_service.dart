import 'dart:async';
import 'dart:collection';
import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:PiliPlus/utils/ai_image_state.dart';
import 'package:PiliPlus/utils/ai_inference_engine.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/clip_preprocessing.dart';
import 'package:PiliPlus/utils/clip_similarity.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/utils/lru_cache.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// A queued evaluation task for [AiImageModerationService].
///
/// Mirrors the [_ImageHashWorker._Task] pattern from [ImageBlockService].
class _EvaluationTask {
  final String key;
  final String imageUrl;
  final Completer<AiImageState> completer;

  _EvaluationTask({
    required this.key,
    required this.imageUrl,
    required this.completer,
  });
}

/// AI-powered image moderation service using CLIP zero-shot classification.
///
/// Mirrors the [ImageBlockService] pattern:
/// - Static methods only (no GetxService, no reactive streams)
/// - LRU cache for results ([_resultCache], max 500 entries)
/// - In-flight dedup ([_inFlightEvaluations]) avoids re-downloading the same URL
/// - Evaluation queue ([_evalQueue], max 50, newest-first) prevents resource
///   exhaustion when rapidly scrolling through comments
/// - Lazy-loaded singleton [InferenceSession]
/// - Cache-first → in-flight dedup → evaluation queue → fresh evaluation
/// - Fail-open: any exception returns [AiImageState.normal]
/// - Fire-and-forget: UI calls [evaluateImage], gets result back, does setState
abstract final class AiImageModerationService {
  /// URL→result cache (avoids re-evaluating same image).
  static final LruCache<String, AiImageState> _resultCache = LruCache(
    maxSize: 500,
  );

  /// In-flight evaluations dedup map (avoids re-downloading same URL).
  static final Map<String, Future<AiImageState>> _inFlightEvaluations = {};

  /// Lazy-loaded singleton inference session.
  static InferenceSession? _session;

  /// Generation counter for cache invalidation.
  static int _generation = 0;

  /// Tracks model format for auto-invalidation when model is replaced.
  static String? _lastFormat;

  // ── Evaluation queue (max 50, newest-first) ─────────────────────────

  /// Maximum number of queued evaluations before oldest are dropped.
  static const int _maxEvalQueueSize = 50;

  /// Ordered queue of pending evaluation tasks (newest at end).
  static final Queue<_EvaluationTask> _evalQueue = Queue<_EvaluationTask>();

  /// Whether the queue worker is currently processing a task.
  static bool _evalQueueBusy = false;

  // ── Sync fast path ──────────────────────────────────────────────────

  /// Returns cached result for [url], or `null` if not in cache.
  ///
  /// Does NOT trigger any network request or inference. Only reads the LRU
  /// result cache.
  static AiImageState? getCachedResult(String url) {
    final key = _normalizeUrl(url);
    return _resultCache[key];
  }

  // ── Full async evaluation pipeline ──────────────────────────────────

  /// Full async evaluation pipeline for [imageUrl].
  ///
  /// Steps:
  /// 1. Early-return [AiImageState.normal] if AI moderation or pHash is
  ///    disabled (zero overhead).
  /// 2. Early-return [AiImageState.normal] if no model or embeddings
  ///    available (fail-open).
  /// 3. Check LRU result cache → return cached value.
  /// 4. Check in-flight dedup map → await concurrent evaluation.
  /// 5. Queue the evaluation task (newest-first, max 50).
  /// 6. Dispatch the next task from the queue.
  static Future<AiImageState> evaluateImage(String imageUrl) async {
    // 1. If AI disabled or pHash disabled → normal (zero overhead)
    if (!Pref.enableAiImageModeration || !Pref.enableImageBlock) {
      return AiImageState.normal;
    }

    // 2. If no model or no embeddings → normal (fail-open)
    if (!Pref.aiModelDownloaded || Pref.aiTextEmbeddings.length < 1536) {
      return AiImageState.normal;
    }

    // 3. Normalize URL
    final key = _normalizeUrl(imageUrl);

    // 4. Check result cache
    final cached = _resultCache[key];
    if (cached != null) return cached;

    // 5. Check in-flight dedup
    final inFlight = _inFlightEvaluations[key];
    if (inFlight != null) return inFlight;

    // 6. Create a queued evaluation task.
    final completer = Completer<AiImageState>();
    _inFlightEvaluations[key] = completer.future;

    // 7. If queue is full, drop the oldest task (complete it as normal).
    while (_evalQueue.length >= _maxEvalQueueSize) {
      final oldest = _evalQueue.removeFirst();
      _inFlightEvaluations.remove(oldest.key);
      if (!oldest.completer.isCompleted) {
        oldest.completer.complete(AiImageState.normal);
      }
    }

    // 8. Add to queue and try to dispatch.
    _evalQueue.add(_EvaluationTask(
      key: key,
      imageUrl: imageUrl,
      completer: completer,
    ));
    _dispatchNextEval();

    try {
      return await completer.future;
    } finally {
      _inFlightEvaluations.remove(key);
    }
  }

  // ── Internal evaluation ─────────────────────────────────────────────

  /// Internal: download image, preprocess, run inference, classify.
  static Future<AiImageState> _evaluateFresh(
    String key,
    String imageUrl,
  ) async {
    try {
      // Load text embeddings from Pref
      final rawEmbeds = Pref.aiTextEmbeddings;
      if (rawEmbeds.length < 1536) return AiImageState.normal;

      // Parse 3×512 embeddings
      final embedList = <Float32List>[
        Float32List.fromList(rawEmbeds.sublist(0, 512)),
        Float32List.fromList(rawEmbeds.sublist(512, 1024)),
        Float32List.fromList(rawEmbeds.sublist(1024, 1536)),
      ];

      // Auto-invalidate cache if model format changed (model was replaced)
      final format = Pref.aiModelFormat;
      if (_lastFormat != null && _lastFormat != format) {
        _resultCache.clear();
      }
      _lastFormat = format;

      // Lazy-load inference session
      _session ??= await AiInferenceEngine.create();
      if (_session == null) return AiImageState.normal;

      // Get input size and layout
      final inputSize = Pref.aiModelInputSize;
      final layout = ClipPreprocessing.layoutForFormat(format);

      // Download image via CacheManager
      final file = await CacheManager.manager.getSingleFile(imageUrl);
      final bytes = await file.readAsBytes();

      // Preprocess
      final input = await ClipPreprocessing.preprocessImage(
        bytes,
        inputSize: inputSize,
        layout: layout,
      );

      // Run vision encoder
      final imageEmbed = await _session!.runVision(input);

      // Normalize image embedding
      final normalizedImage = _normalize(imageEmbed);

      // Classify
      final (state, _) = ClipSimilarity.classify(normalizedImage, embedList);

      // Cache result
      _resultCache[key] = state;

      // Auto-blocklist: if MALICIOUS && aiAutoBlocklist
      if (state == AiImageState.blocked && Pref.aiAutoBlocklist) {
        await ImageBlockService.blockImage(imageUrl);
      }

      return state;
    } catch (e) {
      // Fail-open: any exception → show image normally
      debugPrint('AiImageModerationService error: $e');
      return AiImageState.normal;
    }
  }

  // ── Evaluation queue dispatch ───────────────────────────────────────

  /// Dispatch the newest task from the queue.
  ///
  /// Only one task processes at a time ([_evalQueueBusy]). When it finishes,
  /// the next-newest task in the queue is dispatched (LIFO / newest-first).
  static void _dispatchNextEval() {
    if (_evalQueueBusy || _evalQueue.isEmpty) return;

    // Newest-first: take from end of queue.
    final task = _evalQueue.removeLast();
    _evalQueueBusy = true;

    _executeEval(task).then((_) {
      _evalQueueBusy = false;
      _dispatchNextEval();
    });
  }

  /// Execute a single evaluation task.
  ///
  /// Delegates to [_evaluateFresh] and completes the task's completer with
  /// the result. On any exception, completes with [AiImageState.normal].
  static Future<void> _executeEval(_EvaluationTask task) async {
    try {
      final result = await _evaluateFresh(task.key, task.imageUrl);
      if (!task.completer.isCompleted) {
        task.completer.complete(result);
      }
    } catch (e) {
      debugPrint('AiImageModerationService._executeEval error: $e');
      if (!task.completer.isCompleted) {
        task.completer.complete(AiImageState.normal);
      }
    }
  }

  // ── Cache management ────────────────────────────────────────────────

  /// Invalidate all caches. Call when prompts change or model is replaced.
  static void invalidateCache() {
    _resultCache.clear();
    _generation++;
  }

  /// Directly set a cached result for [imageUrl] (test helper only).
  @visibleForTesting
  static void setCachedResult(String imageUrl, AiImageState state) {
    final key = _normalizeUrl(imageUrl);
    _resultCache[key] = state;
  }

  /// Set a mock [InferenceSession] for testing (test helper only).
  ///
  /// Pass `null` to reset to lazy-loaded behaviour.
  @visibleForTesting
  static void setMockSession(InferenceSession? session) {
    _session = session;
  }

  // ── URL normalization ───────────────────────────────────────────────

  /// Normalize a URL by stripping BiliBili format suffixes (@...) and
  /// query parameters (?...).
  ///
  /// Mirrors [ImageBlockService.normalizeUrl] behaviour.
  @visibleForTesting
  static String normalizeUrl(String url) => _normalizeUrl(url);

  static String _normalizeUrl(String url) {
    final atIndex = url.indexOf('@');
    final qIndex = url.indexOf('?');
    int end;
    if (atIndex == -1 && qIndex == -1) return url;
    if (atIndex == -1) {
      end = qIndex;
    } else if (qIndex == -1) {
      end = atIndex;
    } else {
      end = atIndex < qIndex ? atIndex : qIndex;
    }
    return url.substring(0, end);
  }

  // ── Vector normalization ────────────────────────────────────────────

  /// L2-normalise [v] to unit length.
  /// Returns a new [Float32List] (or [v] if norm is zero).
  static Float32List _normalize(Float32List v) {
    double norm = 0.0;
    for (int i = 0; i < v.length; i++) {
      norm += v[i] * v[i];
    }
    norm = sqrt(norm);
    if (norm == 0.0) return v;
    final result = Float32List(v.length);
    for (int i = 0; i < v.length; i++) {
      result[i] = v[i] / norm;
    }
    return result;
  }

  // ── Lifecycle ───────────────────────────────────────────────────────

  /// Dispose the inference session and clear all caches.
  static void dispose() {
    _session?.dispose();
    _session = null;
    _resultCache.clear();
    _inFlightEvaluations.clear();
    _evalQueueBusy = false;
    // Complete all pending queue tasks with normal (fail-open).
    while (_evalQueue.isNotEmpty) {
      final task = _evalQueue.removeFirst();
      if (!task.completer.isCompleted) {
        task.completer.complete(AiImageState.normal);
      }
    }
    _generation++;
  }
}
