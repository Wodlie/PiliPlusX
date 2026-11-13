/// Runs the durable-scope migration once per (store, account, trusted set).
///
/// The memo key is a [_MemoKey]: the backing store identified by **object
/// identity** plus the durable account id, then the set of trusted legacy scopes
/// already migrated. A store that implements [StorageIdentity] reports its box, so
/// two wrappers over one box are one store; anything else is its own store.
///
/// Hashing never decides equality — [Object.hash] only picks a bucket, and
/// [_MemoKey.==] compares the store by `identical`. Two backends whose identity
/// hashes collide therefore stay two entries.
///
/// A pass is skipped only when an already-migrated trusted set covers the one
/// being asked for, so a later, wider trusted set — a newly supplied legacy
/// namespace, or the new current scope after a credential rotation — still runs.
/// Nothing is recorded unless the pass was clean, so a failure retries; retrying
/// is safe because every merge in [DurableScopeMigration] is idempotent.
///
/// No cross-process atomicity: [KeyValueStore] has no compare-and-swap, so two
/// isolates starting at once both run and converge on the same merged result.
library;

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/storage/durable_scope_migration.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/storage/storage_identity.dart';

/// Identity of one memo entry: backing store (by identity) + durable account id.
final class _MemoKey {
  _MemoKey(this.storageIdentity, this.durableScopeId);

  /// The backing store object, held so its identity stays valid and unique.
  final Object storageIdentity;

  final String durableScopeId;

  /// Store compared by `identical`, never by `==` or by hash.
  ///
  /// Two distinct objects that merely compare equal — or that happen to share an
  /// identity hash — are two stores.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _MemoKey &&
          identical(storageIdentity, other.storageIdentity) &&
          durableScopeId == other.durableScopeId;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(storageIdentity), durableScopeId);

  @override
  String toString() => 'MemoKey($durableScopeId)';
}

/// Runs the durable-scope migration at most once per store, account and trusted set.
abstract final class DurableScopeBootstrap {
  /// Trusted sets already migrated, per [_MemoKey].
  static final Map<_MemoKey, List<Set<String>>> _settled =
      <_MemoKey, List<Set<String>>>{};

  /// Passes still running, keyed the same way.
  static final Map<_MemoKey, Future<DurableScopeMigrationReport?>> _inFlight =
      <_MemoKey, Future<DurableScopeMigrationReport?>>{};

  /// Credential-free record of what this process did.
  static final List<String> _diagnostics = <String>[];

  /// Everything this process decided about durable state, oldest first.
  static List<String> get diagnostics =>
      List<String>.unmodifiable(_diagnostics);

  /// Ensures [account]'s durable namespace holds its proven legacy data.
  ///
  /// Returns the pass's report when this call ran one, or null when the exact
  /// trusted set was already migrated (or nothing was attempted). Never throws.
  /// [featureEnabled] false skips the pass: a switched-off service has no storage
  /// side effects.
  static Future<DurableScopeMigrationReport?> ensureMigrated({
    required KeyValueStore store,
    required AccountScope account,
    Iterable<String> trustedLegacyScopeIds = const <String>[],
    bool featureEnabled = true,
    int Function()? nowMs,
  }) {
    if (!featureEnabled) {
      return Future<DurableScopeMigrationReport?>.value(null);
    }
    final key = _keyOf(store, account);
    final trusted = _trustedSetOf(account, trustedLegacyScopeIds);
    if (_isSettled(key, trusted)) {
      return Future<DurableScopeMigrationReport?>.value(null);
    }
    final running = _inFlight[key];
    if (running != null) {
      // Join it, then re-check: it may have covered only a narrower set, in which
      // case this caller still needs its own pass for the extra namespaces.
      return running.then((report) {
        if (_isSettled(key, trusted)) return null;
        return ensureMigrated(
          store: store,
          account: account,
          trustedLegacyScopeIds: trustedLegacyScopeIds,
          featureEnabled: featureEnabled,
          nowMs: nowMs,
        );
      });
    }
    final pass = _run(
      key: key,
      trusted: trusted,
      store: store,
      account: account,
      trustedLegacyScopeIds: trustedLegacyScopeIds,
      nowMs: nowMs,
    );
    _inFlight[key] = pass;
    return pass.whenComplete(() {
      if (identical(_inFlight[key], pass)) {
        _inFlight.remove(key);
      }
    });
  }

  /// Whether [account]'s namespace already holds every scope in
  /// [trustedLegacyScopeIds] for [store].
  static bool isSettled(
    KeyValueStore store,
    AccountScope account, {
    Iterable<String> trustedLegacyScopeIds = const <String>[],
  }) => _isSettled(
    _keyOf(store, account),
    _trustedSetOf(account, trustedLegacyScopeIds),
  );

  /// Whether two stores would share one memo entry, decided by the same rule the
  /// memo itself uses.
  ///
  /// Exposed for checks: it lets a test verify the identity rule directly instead
  /// of hoping two objects collide in a hash.
  static bool sameMemoEntry({
    required KeyValueStore storeA,
    required AccountScope accountA,
    required KeyValueStore storeB,
    required AccountScope accountB,
  }) => _keyOf(storeA, accountA) == _keyOf(storeB, accountB);

  /// Forgets what this process has done. Test-only.
  static void debugReset() {
    _settled.clear();
    _inFlight.clear();
    _diagnostics.clear();
  }

  static Future<DurableScopeMigrationReport?> _run({
    required _MemoKey key,
    required Set<String> trusted,
    required KeyValueStore store,
    required AccountScope account,
    required Iterable<String> trustedLegacyScopeIds,
    required int Function()? nowMs,
  }) async {
    if (!account.hasStableDurableId) {
      // Guest / tourist / hand-built scope: no stable owner to migrate to. Only
      // this account's own entry is settled, so a logged-in account still runs.
      _remember(key, trusted);
      _diagnostics.add(
        'durable-scope: no stable account identity, nothing to do',
      );
      return null;
    }
    try {
      final report = await DurableScopeMigration(
        store,
        account: account,
        trustedLegacyScopeIds: trustedLegacyScopeIds,
        nowMs: nowMs,
      ).run();
      if (report.isClean) {
        _remember(key, trusted);
      }
      _diagnostics.add(_describe(report));
      return report;
    } catch (error) {
      // Type only: an arbitrary message may quote a key.
      _diagnostics.add(
        'durable-scope: pass failed (${error.runtimeType}), will retry',
      );
      return null;
    }
  }

  static void _remember(_MemoKey key, Set<String> trusted) {
    final sets = _settled.putIfAbsent(key, () => <Set<String>>[]);
    if (!sets.any((existing) => _covers(existing, trusted))) {
      sets.add(trusted);
    }
  }

  static bool _isSettled(_MemoKey key, Set<String> trusted) {
    final sets = _settled[key];
    if (sets == null) return false;
    return sets.any((existing) => _covers(existing, trusted));
  }

  /// Whether [existing] already migrated every scope [wanted] asks for.
  static bool _covers(Set<String> existing, Set<String> wanted) =>
      existing.containsAll(wanted);

  /// The trusted set a pass would use: current request scope plus supplied ids.
  static Set<String> _trustedSetOf(
    AccountScope account,
    Iterable<String> supplied,
  ) => Set<String>.unmodifiable(<String>{
    account.requestScopeId,
    for (final scope in supplied)
      if (scope.isNotEmpty) scope,
  });

  /// One diagnostic line about a finished pass: counts only.
  static String _describe(DurableScopeMigrationReport report) {
    final inserted = report.inserted.values.fold<int>(0, (a, b) => a + b);
    final merged = report.merged.values.fold<int>(0, (a, b) => a + b);
    return 'durable-scope: inserted=$inserted merged=$merged '
        'deleted=${report.deletedSourceKeys} '
        'skipped=${report.skippedUnreadable.length} '
        'stale=${report.staleSources.length} '
        'failed=${report.failures.length} '
        'unrecoverable=${report.unrecoverableScopeIds.length} '
        'refused=${report.refusedScopeIds.length}';
  }

  /// Memo key: the backing store object, then the durable account identity.
  static _MemoKey _keyOf(KeyValueStore store, AccountScope account) {
    // `store is StorageIdentity` cannot promote (unrelated interfaces, no
    // intersection types), so the cast is guarded by the test.
    final Object identity = store is StorageIdentity
        ? (store as StorageIdentity).storageIdentity
        : store;
    return _MemoKey(identity, account.durableId);
  }
}
