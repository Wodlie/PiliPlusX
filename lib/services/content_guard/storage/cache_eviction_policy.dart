/// Pure cache eviction logic: TTL expiry + capacity + schema-version
/// invalidation. No I/O, no clock of its own — every decision takes `nowMs`
/// from the caller, so the policy is deterministic and testable.
library;

/// What the policy needs to know about one cached entry.
final class CacheEntryMeta {
  const CacheEntryMeta({
    required this.updatedAtMs,
    required this.schemaVersion,
    required this.lastAccessMs,
  });

  /// A freshly written entry: last access equals write time.
  const CacheEntryMeta.fresh({
    required this.updatedAtMs,
    required this.schemaVersion,
  }) : lastAccessMs = updatedAtMs;

  /// Write time (TTL is measured from here, i.e. it is a freshness bound).
  final int updatedAtMs;

  /// Schema version the entry was written with.
  final int schemaVersion;

  /// Last read time (drives LRU capacity eviction).
  final int lastAccessMs;

  /// Same entry, just touched at [nowMs].
  CacheEntryMeta touchedAt(int nowMs) => CacheEntryMeta(
    updatedAtMs: updatedAtMs,
    schemaVersion: schemaVersion,
    lastAccessMs: nowMs,
  );

  /// Age in milliseconds at [nowMs]; negative when the clock went backwards.
  int ageMs(int nowMs) => nowMs - updatedAtMs;

  @override
  String toString() =>
      'CacheEntryMeta(updatedAtMs: $updatedAtMs, schemaVersion: $schemaVersion, '
      'lastAccessMs: $lastAccessMs)';
}

/// Eviction policy. Documented choices:
///
/// * **TTL** is a freshness bound measured from [CacheEntryMeta.updatedAtMs]
///   (not from the last access): an entry expires once its age reaches
///   [ttl], so a zero ttl expires everything immediately.
/// * **Capacity** evicts least-recently-used first, using
///   [CacheEntryMeta.lastAccessMs]; ties break on key order so the result is
///   stable regardless of map iteration order.
/// * **Version invalidation** is a separate predicate ([isVersionStale]) — a
///   stale-schema entry is simply dropped, never migrated, mirroring the
///   repository's "schema mismatch is a miss" rule.
final class CacheEvictionPolicy {
  const CacheEvictionPolicy({required this.ttl, required this.capacity});

  /// Time-to-live measured from the write time.
  final Duration ttl;

  /// Maximum number of live entries; non-positive means "keep nothing".
  final int capacity;

  /// True once the entry's age reaches [ttl].
  bool isExpired(CacheEntryMeta meta, int nowMs) =>
      meta.ageMs(nowMs) >= ttl.inMilliseconds;

  /// True when the entry was written by a different schema version.
  bool isVersionStale(CacheEntryMeta meta, int currentVersion) =>
      meta.schemaVersion != currentVersion;

  /// Ids that must be dropped: expired entries first (key order), then LRU
  /// victims until the survivors fit [capacity].
  List<String> selectEvictions(
    Map<String, CacheEntryMeta> entries,
    int nowMs,
  ) {
    final expired = <String>[];
    final live = <MapEntry<String, CacheEntryMeta>>[];
    for (final entry in entries.entries) {
      if (isExpired(entry.value, nowMs)) {
        expired.add(entry.key);
      } else {
        live.add(entry);
      }
    }
    expired.sort();
    final evictions = <String>[...expired];
    final limit = capacity < 0 ? 0 : capacity;
    if (live.length > limit) {
      live.sort((a, b) {
        final byAccess = a.value.lastAccessMs.compareTo(b.value.lastAccessMs);
        return byAccess != 0 ? byAccess : a.key.compareTo(b.key);
      });
      for (var i = 0; i < live.length - limit; i++) {
        evictions.add(live[i].key);
      }
    }
    return evictions;
  }

  /// Ids written by a schema version other than [currentVersion].
  List<String> selectVersionStale(
    Map<String, CacheEntryMeta> entries,
    int currentVersion,
  ) {
    final stale = <String>[
      for (final entry in entries.entries)
        if (isVersionStale(entry.value, currentVersion)) entry.key,
    ];
    stale.sort();
    return stale;
  }
}
