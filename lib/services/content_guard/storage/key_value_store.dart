/// Minimal key/value contract for ContentGuard persistence.
///
/// Pure Dart: no Hive, no Flutter, no bindings, no async I/O beyond the four
/// declared futures. Repositories depend on this interface only, so tests and
/// the in-memory fake never need a Hive box or a Flutter binding.
library;

import 'package:PiliPlus/services/content_guard/storage/storage_identity.dart';

/// A string-keyed, string-or-null-valued store.
///
/// Values stay [Object] because the backing box stores dynamic values; every
/// ContentGuard repository encodes its payload to JSON before writing, so
/// nothing but [String] (and `null`) is expected on read.
abstract interface class KeyValueStore {
  Object? get(String key);

  Future<void> put(String key, Object? value);

  Future<void> delete(String key);

  Iterable<String> keys();

  bool containsKey(String key);
}

/// Thin adapter over a Hive-like box.
///
/// The box is reached through [dynamic] access on purpose: this file stays the
/// only place that knows the backing object's shape, and `package:hive_ce`
/// never has to be imported (nor mocked) for the storage layer or its tests.
/// [keys] filters out non-string keys instead of throwing.
///
/// Implements [StorageIdentity] so every wrapper over one box reports the **same**
/// backing identity. Without it the bootstrap memo would key on the wrapper — and
/// the app builds a fresh wrapper per call site, so each one would look like a new
/// store and re-scan the box.
final class HiveKeyValueStore implements KeyValueStore, StorageIdentity {
  /// Wraps an already-opened box.
  HiveKeyValueStore(dynamic box) : _boxOf = (() => box);

  /// Wraps a lazily resolved box, e.g. `GStorage.localCache` before [init].
  HiveKeyValueStore.fromAccessor(dynamic Function() boxAccessor)
    : _boxOf = boxAccessor;

  final dynamic Function() _boxOf;

  /// The box itself, resolved lazily.
  ///
  /// Lazy so `fromAccessor` stays usable before the box exists; the bootstrap only
  /// asks for it once it is about to migrate, at which point a box must be open.
  @override
  Object get storageIdentity => _boxOf();

  @override
  Object? get(String key) => _boxOf().get(key);

  @override
  Future<void> put(String key, Object? value) async {
    await _boxOf().put(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _boxOf().delete(key);
  }

  @override
  Iterable<String> keys() {
    final Iterable<Object?> rawKeys = _boxOf().keys as Iterable<Object?>;
    return rawKeys.whereType<String>();
  }

  @override
  bool containsKey(String key) => _boxOf().containsKey(key) as bool;
}
