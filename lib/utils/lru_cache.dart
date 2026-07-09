/// A generic LRU (Least Recently Used) cache with capacity-based eviction.
///
/// When [length] exceeds [maxSize], the least recently accessed entry is
/// evicted. Both read (`[]`) and write (`[]=`) count as access and promote
/// the key to the most-recently-used position.
///
/// Implementation uses a [LinkedHashMap] as an insertion-ordered map. Access
/// is simulated by remove-then-reinsert to move the entry to the end (most
/// recently inserted position), giving O(1) amortized read/write.
///
/// - Keys extend [Object] (non-nullable).
/// - Values can be nullable (`V?`).
/// - Not thread-safe.
class LruCache<K extends Object, V> {
  /// Maximum number of entries before the oldest is evicted.
  final int maxSize;

  /// Internal insertion-ordered map. Dart's default [Map] is a
  /// [LinkedHashMap] which preserves insertion order.
  final _map = <K, V>{};

  /// Creates an LRU cache with the given [maxSize].
  ///
  /// [maxSize] must be >= 1. Defaults to 500.
  LruCache({this.maxSize = 500}) : assert(maxSize >= 1);

  /// Reads [key] and promotes it to most-recently-used position.
  ///
  /// Returns `null` when [key] is not in cache.
  V? operator [](K key) {
    if (!_map.containsKey(key)) return null;
    // Remove then re-insert to move to end (most recently used).
    // Using `as V` instead of `!` to support nullable V (e.g., V = String?).
    final value = _map.remove(key) as V;
    _map[key] = value;
    return value;
  }

  /// Inserts or overwrites [key] with [value].
  ///
  /// If [key] already exists, it is reinserted (promoted to
  /// most-recently-used). After insertion, the oldest entries are evicted
  /// until [length] <= [maxSize].
  void operator []=(K key, V value) {
    // Remove first so reinsert updates access order.
    _map.remove(key);
    _map[key] = value;
    _evict();
  }

  /// Returns `true` if [key] is present, without affecting access order.
  bool containsKey(K key) => _map.containsKey(key);

  /// Removes [key] from cache, if present.
  void remove(K key) => _map.remove(key);

  /// Removes all entries from cache.
  void clear() => _map.clear();

  /// Current number of entries in cache.
  int get length => _map.length;

  /// Evicts the oldest entries (first inserted) until length <= maxSize.
  void _evict() {
    while (_map.length > maxSize) {
      // `.keys.first` yields the earliest-inserted key.
      _map.remove(_map.keys.first);
    }
  }
}
