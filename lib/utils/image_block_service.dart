import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_imagehash/dart_imagehash.dart' show ImageHash, ImageHasher;
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:PiliPlus/utils/blocked_image_storage.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
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

  final List<String> hashes = [ImageHasher.perceptualHash(decoded).toHex()];

  if (flipEnabled) {
    final flipped = img.copyFlip(
      decoded,
      direction: img.FlipDirection.horizontal,
    );
    hashes.add(ImageHasher.perceptualHash(flipped).toHex());
  }

  if (rotateEnabled) {
    for (final angle in [90, 180, 270]) {
      final rotated = img.copyRotate(decoded, angle: angle);
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

  final Completer<void> _ready = Completer<void>();
  late final SendPort _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  int _nextId = 0;
  final Map<int, Completer<List<String>>> _pending = {};

  Future<void> _start() async {
    await Isolate.spawn(_entryPoint, _receivePort.sendPort);
    _receivePort.listen((dynamic message) {
      if (message is SendPort) {
        _sendPort = message;
        _ready.complete();
        return;
      }
      final response = message as List<Object?>;
      final id = response[0] as int;
      final hashes = (response[1] as List<dynamic>).cast<String>();
      _pending.remove(id)?.complete(hashes);
    });
  }

  static void _entryPoint(SendPort mainSendPort) {
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);
    workerReceivePort.listen((dynamic message) {
      final request = message as List<Object?>;
      final id = request[0] as int;
      final bytes = request[1] as Uint8List;
      final flip = request[2] as bool;
      final rotate = request[3] as bool;
      final hashes = computeImageHashes([bytes, flip, rotate]);
      mainSendPort.send([id, hashes]);
    });
  }

  Future<List<String>> computeHashes(
    Uint8List bytes, {
    bool flipEnabled = true,
    bool rotateEnabled = true,
  }) async {
    if (!_ready.isCompleted) {
      await _start();
      await _ready.future;
    }
    final id = _nextId++;
    final completer = Completer<List<String>>();
    _pending[id] = completer;
    _sendPort.send([id, bytes, flipEnabled, rotateEnabled]);
    return completer.future;
  }
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
  static final Map<String, List<String>> _hashCache = {};

  /// URL→blocked result cache (avoids re-evaluating isBlocked)
  /// Key is normalized URL (stripped of @format and ?query params).
  static final Map<String, bool> _resultCache = {};

  /// Strip BiliBili image format (@...) and standard query params (?...).
  /// URLs like ".../abc.jpg@100w_100h.webp" and ".../abc.jpg" map to same key.
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
  static bool isBlocked(
    List<String> imageVariantHashes,
    List<Map<String, dynamic>> blockList,
    int threshold,
  ) {
    if (!Pref.enableImageBlock) return false;
    if (blockList.isEmpty) return false;
    if (imageVariantHashes.isEmpty) return false;

    int minDistance = 64;

    for (final variantHash in imageVariantHashes) {
      for (final entry in blockList) {
        final blockedHash = entry['pHash'] as String;
        final distance = hammingDistance(variantHash, blockedHash);
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
  static Future<bool> evaluateBlock(String imageUrl) async {
    if (!Pref.enableImageBlock) return false;
    final key = _normalizeUrl(imageUrl);

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

    try {
      final file = await CacheManager.manager.getSingleFile(imageUrl);
      final bytes = await file.readAsBytes();
      final hashes = await _worker.computeHashes(
        bytes,
        flipEnabled: Pref.imageBlockFlipEnabled,
        rotateEnabled: Pref.imageBlockRotateEnabled,
      );
      if (hashes.isEmpty) return false;
      _hashCache[key] = hashes;
      final blocked = isBlocked(
        hashes,
        Pref.imageBlockHashList,
        Pref.imageBlockThreshold,
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
      final file = await CacheManager.manager.getSingleFile(imageUrl);
      final bytes = await file.readAsBytes();

      final hashes = await _worker.computeHashes(
        bytes,
        flipEnabled: flipEnabled,
        rotateEnabled: rotateEnabled,
      );
      if (hashes.isEmpty) return null;
      final primaryHash = hashes.first;

      await BlockedImageStorage.saveImage(primaryHash, bytes);

      final key = _normalizeUrl(imageUrl);
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
      _hashCache[_normalizeUrl(url)];

  /// Invalidate result cache. Call when block list/threshold/settings change.
  static void invalidateResultCache() {
    _resultCache.clear();
  }

  /// Invalidate result cache for specific URLs.
  static void invalidateResultCacheForUrls(Iterable<String> urls) {
    for (final url in urls) {
      _resultCache.remove(_normalizeUrl(url));
    }
  }

  /// Clear all in-memory caches.
  static void clearCache() {
    _hashCache.clear();
    _resultCache.clear();
  }
}
