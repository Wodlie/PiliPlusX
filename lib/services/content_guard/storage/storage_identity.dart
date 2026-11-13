/// Optional capability: a store that can name its own backing identity.
///
/// The bootstrap memo must treat two wrappers over *one* box as one store, and
/// two different boxes as two stores. `identityHashCode(store)` answers the wrong
/// question for the first case: [HiveKeyValueStore] is a cheap wrapper, so the app
/// builds a new one per call site and every wrapper hashes differently.
///
/// This is a **separate** interface rather than a member on [KeyValueStore] so the
/// existing contract — and every implementation of it, including the test doubles
/// and `InMemoryKeyValueStore` — keeps compiling untouched. A store that does not
/// implement this is identified by object identity, which is exactly right for a
/// store that has no backing object to share.
library;

/// A [KeyValueStore] that can identify its backing storage.
abstract interface class StorageIdentity {
  /// Stable, process-scoped identity of the backing box.
  ///
  /// Two wrappers over the same box must return the **same** value; two different
  /// boxes must return **different** values. It is deliberately an `Object` rather
  /// than a string: the bootstrap keys its memo by object identity, so a value
  /// that is merely equal (two digests that happen to collide, two strings with the
  /// same text) must not be mistaken for the same store.
  ///
  /// Implementations should return the box/backend object itself.
  Object get storageIdentity;
}
