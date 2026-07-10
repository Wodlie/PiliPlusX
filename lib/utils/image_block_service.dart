import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_imagehash/dart_imagehash.dart' show ImageHash, ImageHasher;
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:PiliPlus/utils/blocked_image_storage.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/lru_cache.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Compute pHash variants for an image (used as Isolate entry point).
/// Must be a top-level function (for compute() / Isolate.spawn).
/// params[0]: Uint8List imageBytes
/// params[1]: bool flipEnabled
/// params[2]: bool rotateEnabled
/// Returns hex pHash list [original, flip?, rot90?, rot180?, rot270?]
List<String> computeImageHashes(List<Object?> params) {
  final bytes = params[0] as Uint8List;
  final flipEnabled = params[1] as bool;
  final rotateEnabled = params[2] as bool;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return [];

  // Resize to small for pHash computation (reduces flip/rotate overhead).
  final small = img.copyResize(decoded, width: 128);

  final List<String> hashes = [ImageHasher.perceptualHash(small).toHex()];

  if (flipEnabled) {
    final flipped = img.copyFlip(
      small,
      direction: img.FlipDirection.horizontal,
    );
    hashes.add(ImageHasher.perceptualHash(flipped).toHex());
  }

  if (rotateEnabled) {
    for (final angle in [90, 180, 270]) {
      final rotated = img.copyRotate(small, angle: angle);
      hashes.add(ImageHasher.perceptualHash(rotated).toHex());
    }
  }

  return hashes;
}

/// Persistent Isolate worker for pHash computation.
/// Spawns once, reuses for all requests — eliminates per-call spawn overhead.
class _ImageHashWorker {
  static final _ImageHashWorker _instance = _ImageHashWorker._();
  factory _ImageHashWorker() => _instance;
  _ImageHashWorker._();

  Completer<void> _ready = Completer<void>();
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  int _nextId = 0;
  final Map<int, Completer<List<String>>> _pending = {};
  Completer<void>? _startingCompleter;

  /// Generation counter for priority queue ordering.
  int _generation = 0;

  /// Task queue for newest-first dispatch.
  final List<_Task> _taskQueue = [];

  /// Whether the isolate is currently processing a task.
  bool _workerBusy = false;

  Future<void> _start() async {
    try {
      await Isolate.spawn(_entryPoint, _receivePort.sendPort);
    } catch (e) {
      _ready.completeError(e);
      _startingCompleter?.complete();
      return;
    }
    _receivePort.listen(
      (dynamic message) {
        if (message is SendPort) {
          _sendPort = message;
          _ready.complete();
          return;
        }
        final response = message as List<Object?>;
        final id = response[0] as int;
        if (response[1] == null) {
          // Error response from worker
          _pending.remove(id)?.complete(<String>[]);
          _workerBusy = false;
          _dispatchNext();
          return;
        }
        final hashes = (response[1] as List<dynamic>).cast<String>();
        _pending.remove(id)?.complete(hashes);
        _workerBusy = false;
        _dispatchNext();
      },
      onDone: () {
        // Isolate died — reset for auto-restart
        _ready = Completer<void>();
        _startingCompleter = null;
        for (final entry in _pending.entries) {
          entry.value.complete(<String>[]);
        }
        _pending.clear();
        _taskQueue.clear();
        _workerBusy = false;
      },
    );
  }

  static void _entryPoint(SendPort mainSendPort) {
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);
    workerReceivePort.listen((dynamic message) {
      try {
        final request = message as List<Object?>;
        final id = request[0] as int;
        final bytes = request[1] as Uint8List;
        final flip = request[2] as bool;
        final rotate = request[3] as bool;
        final hashes = computeImageHashes([bytes, flip, rotate]);
        mainSendPort.send([id, hashes]);
      } catch (e) {
        try {
          final id = (message as List<Object?>)[0] as int;
          mainSendPort.send([id, null, e.toString()]);
        } catch (_) {
          // Can't extract id from malformed message
        }
      }
    });
  }

  Future<List<String>> computeHashes(
    Uint8List bytes, {
    bool flipEnabled = true,
    bool rotateEnabled = true,
  }) async {
    if (!_ready.isCompleted) {
      if (_startingCompleter == null) {
        _startingCompleter = Completer<void>();
        await _start();
        if (!_startingCompleter!.isCompleted) {
          _startingCompleter!.complete();
        }
      } else {
        await _startingCompleter!.future;
      }
      await _ready.future;
    }
    if (_sendPort == null) {
      return <String>[];
    }
    final id = _nextId++;
    final completer = Completer<List<String>>();
    _pending[id] = completer;
    _taskQueue.add(_Task(id, bytes, flipEnabled, rotateEnabled, _generation++));
    _dispatchNext();
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pending.remove(id);
        _workerBusy = false;
        _dispatchNext();
        return <String>[];
      },
    );
  }

  /// Dispatch the newest task from the queue, dropping oldest if over 50.
  void _dispatchNext() {
    while (_taskQueue.length > 50) {
      _taskQueue.sort((a, b) => a.generation.compareTo(b.generation));
      final oldest = _taskQueue.removeAt(0);
      _pending.remove(oldest.id)?.complete(<String>[]);
    }
    if (_workerBusy || _taskQueue.isEmpty) return;
    _taskQueue.sort((a, b) => b.generation.compareTo(a.generation));
    final task = _taskQueue.removeAt(0);
    _workerBusy = true;
    _sendPort!.send([
      task.id,
      task.bytes,
      task.flipEnabled,
      task.rotateEnabled,
    ]);
  }
}

/// A queued task for the image hash worker.
class _Task {
  final int id;
  final Uint8List bytes;
  final bool flipEnabled;
  final bool rotateEnabled;
  final int generation;
  _Task(
    this.id,
    this.bytes,
    this.flipEnabled,
    this.rotateEnabled,
    this.generation,
  );
}

/// Image blocking service.
/// Provides pHash-based image matching with:
/// - Persistent Isolate worker (eliminates per-call spawn overhead)
/// - URL→blocked result cache (avoids recomputation per widget life-cycle)
/// - In-memory hash cache (avoids re-downloading)
abstract final class ImageBlockService {
  static final _ImageHashWorker _worker = _ImageHashWorker();

  /// URL→hashes cache (avoids re-fetching/re-computing)
  /// Key is normalized URL (stripped of @format and ?query params).
  static final LruCache<String, List<String>> _hashCache = LruCache(
    maxSize: 500,
  );

  /// URL→blocked result cache (avoids re-evaluating isBlocked)
  /// Key is normalized URL (stripped of @format and ?query params).
  static final LruCache<String, bool> _resultCache = LruCache(maxSize: 500);

  /// In-flight evaluations dedup map (avoids re-downloading same URL).
  static final Map<String, Future<bool>> _inFlightEvaluations = {};

  /// Pre-parsed block list cache (avoids repeated Hive reads + fromHex calls).
  static List<ImageHash>? _blockListCache;

  /// Strip BiliBili image format (@...) and standard query params (?...).
  /// URLs like ".../abc.jpg@100w_100h.webp" and ".../abc.jpg" map to same key.
  @visibleForTesting
  static String normalizeUrl(String url) {
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

  /// Get the parsed block list from cache or Pref.
  /// Reads Pref.imageBlockHashList on first call, caches as List<ImageHash>.
  @visibleForTesting
  static List<ImageHash> getParsedBlockList() {
    if (_blockListCache != null) return _blockListCache!;
    final rawList = Pref.imageBlockHashList;
    _blockListCache = rawList.map((entry) {
      return ImageHash.fromHex(entry['pHash'] as String);
    }).toList();
    return _blockListCache!;
  }

  /// Transform a BiliBili CDN URL into a small thumbnail URL for pHash computation.
  /// Appends/replaces `@100w_1q.webp` format suffix on BiliBili hosts.
  /// Non-BiliBili URLs are returned unchanged.
  @visibleForTesting
  static String thumbnailUrlForHash(String url) {
    final uri = Uri.parse(url);
    final host = uri.host;
    if (!host.endsWith('.hdslb.com') && !host.endsWith('.biliimg.com')) {
      return url;
    }

    // Strip existing @... suffix, preserving query string position.
    final atIndex = url.indexOf('@');
    final qIndex = url.indexOf('?');
    int end;
    if (atIndex == -1 && qIndex == -1) {
      end = url.length;
    } else if (atIndex == -1) {
      end = qIndex;
    } else if (qIndex == -1) {
      end = atIndex;
    } else {
      end = atIndex < qIndex ? atIndex : qIndex;
    }

    final base = url.substring(0, end);
    final query = qIndex != -1 ? url.substring(qIndex) : '';
    return '$base@100w_1q.webp$query';
  }

  /// Compute pHash variants via persistent Isolate worker.
  static Future<List<String>> computeHashes(
    Uint8List imageBytes, {
    bool flipEnabled = true,
    bool rotateEnabled = true,
  }) {
    return _worker.computeHashes(
      imageBytes,
      flipEnabled: flipEnabled,
      rotateEnabled: rotateEnabled,
    );
  }

  /// Compute Hamming distance between two pHash hex strings.
  static int hammingDistance(String hash1Hex, String hash2Hex) {
    final hash1 = ImageHash.fromHex(hash1Hex);
    final hash2 = ImageHash.fromHex(hash2Hex);
    return hash1 - hash2;
  }

  /// Check if image is blocked by comparing variant hashes against block list.
  /// [blockList] parameter is retained for backward compatibility;
  /// the internal implementation reads from the pre-parsed cache via
  /// [getParsedBlockList] to avoid repeated Hive reads and ImageHash.fromHex calls.
  static bool isBlocked(
    List<String> imageVariantHashes,
    List<Map<String, dynamic>> blockList,
    int threshold,
  ) {
    if (!Pref.enableImageBlock) return false;
    if (imageVariantHashes.isEmpty) return false;

    final parsedList = getParsedBlockList();
    if (parsedList.isEmpty) return false;

    int minDistance = 64;

    for (final variantHashHex in imageVariantHashes) {
      final variantHash = ImageHash.fromHex(variantHashHex);
      for (final blockedHash in parsedList) {
        final distance = variantHash - blockedHash;
        if (distance < minDistance) {
          minDistance = distance;
          if (minDistance <= threshold) return true;
        }
      }
    }

    return false;
  }

  /// Full evaluation: result cache → hash cache → download + worker → isBlocked.
  /// Returns true if the image URL should be blocked.
  /// Deduplicates concurrent evaluations of the same URL via [_inFlightEvaluations].
  static Future<bool> evaluateBlock(String imageUrl) async {
    if (!Pref.enableImageBlock) return false;
    final key = normalizeUrl(imageUrl);

    if (_resultCache.containsKey(key)) return _resultCache[key]!;

    final cachedHashes = _hashCache[key];
    if (cachedHashes != null) {
      final blocked = isBlocked(
        cachedHashes,
        Pref.imageBlockHashList,
        Pref.imageBlockThreshold,
      );
      _resultCache[key] = blocked;
      return blocked;
    }

    // In-flight dedup: if same URL is already being evaluated, await it.
    final inFlight = _inFlightEvaluations[key];
    if (inFlight != null) return inFlight;

    final future = _evaluateFresh(key, imageUrl);
    _inFlightEvaluations[key] = future;
    try {
      return await future;
    } finally {
      _inFlightEvaluations.remove(key);
    }
  }

  /// Download and compute hashes for a URL not yet in cache.
  static Future<bool> _evaluateFresh(String key, String imageUrl) async {
    final sw = Stopwatch()..start();
    final thumbUrl = thumbnailUrlForHash(imageUrl);
    if (kDebugMode)
      debugPrint(
        '[pHash] thumbnailUrl: ${sw.elapsedMilliseconds}ms | key=$key',
      );

    try {
      sw.reset();
      final file = await CacheManager.manager.getSingleFile(thumbUrl);
      if (kDebugMode)
        debugPrint('[pHash] download: ${sw.elapsedMilliseconds}ms | key=$key');

      sw.reset();
      final bytes = await file.readAsBytes();
      if (kDebugMode)
        debugPrint(
          '[pHash] readFile: ${sw.elapsedMilliseconds}ms | size=${bytes.length} | key=$key',
        );

      sw.reset();
      final hashes = await _worker.computeHashes(
        bytes,
        flipEnabled: Pref.imageBlockFlipEnabled,
        rotateEnabled: Pref.imageBlockRotateEnabled,
      );
      if (kDebugMode)
        debugPrint(
          '[pHash] computeHashes: ${sw.elapsedMilliseconds}ms | variants=${hashes.length} | key=$key',
        );

      if (hashes.isEmpty) return false;
      _hashCache[key] = hashes;

      sw.reset();
      final blocked = isBlocked(
        hashes,
        Pref.imageBlockHashList,
        Pref.imageBlockThreshold,
      );
      if (kDebugMode)
        debugPrint(
          '[pHash] isBlocked: ${sw.elapsedMilliseconds}ms | blocked=$blocked | key=$key',
        );

      _resultCache[key] = blocked;
      return blocked;
    } catch (_) {
      _resultCache[key] = false;
      return false;
    }
  }

  /// Block an image: download → compute → save → return entry.
  /// Caller is responsible for updating Pref.imageBlockHashList.
  static Future<Map<String, dynamic>?> blockImage(
    String imageUrl, {
    bool flipEnabled = true,
    bool rotateEnabled = true,
  }) async {
    try {
      final file = await CacheManager.manager.getSingleFile(
        thumbnailUrlForHash(imageUrl),
      );
      final bytes = await file.readAsBytes();

      final hashes = await _worker.computeHashes(
        bytes,
        flipEnabled: flipEnabled,
        rotateEnabled: rotateEnabled,
      );
      if (hashes.isEmpty) return null;
      final primaryHash = hashes.first;

      await BlockedImageStorage.saveImage(primaryHash, bytes);

      final key = normalizeUrl(imageUrl);
      _hashCache[key] = hashes;
      _resultCache.remove(key);

      return {
        'pHash': primaryHash,
        'url': imageUrl,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
    } catch (_) {
      return null;
    }
  }

  /// Get cached pHash variants for a URL.
  static List<String>? getCachedHashes(String url) =>
      _hashCache[normalizeUrl(url)];

  /// Synchronously check if [imageUrl] is blocked using in-memory caches only.
  ///
  /// Returns `true` if blocked, `false` if not blocked, or `null` if the URL
  /// hasn't been evaluated yet (cache miss — caller should call [evaluateBlock]
  /// asynchronously).
  ///
  /// This method does NOT trigger any network request or Isolate computation;
  /// it only reads the existing LRU caches ([_resultCache] and [_hashCache]).
  @visibleForTesting
  static bool? getCachedBlockResult(String imageUrl) {
    if (!Pref.enableImageBlock) return false;
    if (imageUrl.isEmpty) return null;
    final key = normalizeUrl(imageUrl);

    // Check result cache first (fast path)
    final cached = _resultCache[key];
    if (cached != null) return cached;

    // Check hash cache (can compute isBlocked synchronously)
    final cachedHashes = _hashCache[key];
    if (cachedHashes != null) {
      final blocked = isBlocked(
        cachedHashes,
        Pref.imageBlockHashList,
        Pref.imageBlockThreshold,
      );
      _resultCache[key] = blocked;
      return blocked;
    }

    // Neither cache has this URL
    return null;
  }

  /// Directly set a cached result for [imageUrl] (test helper only).
  ///
  /// This bypasses the full evaluation pipeline and is intended for use
  /// in tests to simulate a pre-populated result cache.
  @visibleForTesting
  static void setCachedResult(String imageUrl, bool blocked) {
    final key = normalizeUrl(imageUrl);
    _resultCache[key] = blocked;
  }

  /// Invalidate result cache and block list cache.
  /// Call when block list/threshold/settings change.
  static void invalidateResultCache() {
    _resultCache.clear();
    _blockListCache = null;
  }

  /// Invalidate result cache for specific URLs.
  static void invalidateResultCacheForUrls(Iterable<String> urls) {
    for (final url in urls) {
      _resultCache.remove(normalizeUrl(url));
    }
  }

  /// Clear all in-memory caches.
  static void clearCache() {
    _hashCache.clear();
    _resultCache.clear();
  }
}
