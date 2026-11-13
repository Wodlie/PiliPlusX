/// The guarded, non-fatal entry point the app's startup runs once per launch.
///
/// ## Why this file exists
///
/// [DurableScopeBootstrap.ensureMigrated] is the recipe and
/// [ContentGuardService.create] calls it, but a real launch has to supply the
/// app's box and the current account, and it has to do so *without* letting a
/// storage problem stop the app from opening. That guard is this file.
///
/// It stays pure Dart on purpose. The app-coupled half — reaching into
/// `GStorage.localCache` and `Accounts.main` — lives in `main()`, which
/// already owns every other bootstrap step. Importing `Accounts` from here would
/// drag `pages/mine/controller` (and therefore Flutter) into a service, which is
/// exactly the dependency direction `lib/services/AGENTS.md` forbids; taking the
/// store and the scope as arguments keeps this layer executable by a plain-Dart
/// check with no binding and no Hive box.
///
/// ## Call site
///
/// `main()` calls [runAtStartup] after `GStorage.init()` has opened the boxes
/// and after `Request.setCookie()` has published the account list, but before
/// `runApp`. That is the earliest moment both "the store is open" and "the
/// account is known" hold, and the last moment at which no page can yet construct
/// a pipeline or call `evaluate`.
///
/// ## Non-fatal by construction
///
/// Every failure mode degrades to "nothing happened, retry next launch":
///
/// * no store / no account -> the caller passes null and this returns null;
/// * guest, tourist or hand-built scope -> no stable durable identity, so the
///   bootstrap does nothing and stays out of the way;
/// * a throwing pass -> recorded as a diagnostic (type only, never a message)
///   and reported as null.
///
/// The read path keeps serving whatever is already stored, so a skipped pass
/// costs a future scan, never a lost record.
///
/// ## What it does not do
///
/// It does not construct a physical `ContentGuardService`. That needs a
/// persisted rule set and an enabled/disabled setting, neither of which exists
/// yet; inventing one here would put a half-configured feature in front of users.
/// It runs the one piece of the service's startup contract that is meaningful
/// today — the durable-state pass, with exactly the arguments and the
/// reference-counted idempotence `create()` uses — so that when a rule set is
/// finally persisted no user's accepted or rejected decisions are orphaned in the
/// meantime.
library;

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/storage/durable_scope_bootstrap.dart';
import 'package:PiliPlus/services/content_guard/storage/durable_scope_migration.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';

/// Startup wiring for ContentGuard's durable per-account namespace.
abstract final class ContentGuardStartup {
  /// Orders [account]'s durable namespace over [store]. Never throws.
  ///
  /// [store] is null while the app's boxes are still closed; [account] is null
  /// when no account is known yet. Either being null is "not yet", not "empty":
  /// nothing is memoized, so a later call in the same process still runs.
  ///
  /// Returns the pass's report when this call ran it, or null when there was
  /// nothing to do.
  static Future<DurableScopeMigrationReport?> runAtStartup({
    KeyValueStore? store,
    AccountScope? account,
    Iterable<String> trustedLegacyScopeIds = const <String>[],
  }) {
    if (store == null || account == null) {
      return Future<DurableScopeMigrationReport?>.value(null);
    }
    return DurableScopeBootstrap.ensureMigrated(
      store: store,
      account: account,
      trustedLegacyScopeIds: trustedLegacyScopeIds,
    );
  }

  /// Diagnostics accumulated by this process, credential-free.
  ///
  /// Counts and status words only; safe for a log or a bug report.
  static List<String> get diagnostics => DurableScopeBootstrap.diagnostics;

  /// Whether [account]'s namespace already holds every scope in
  /// [trustedLegacyScopeIds] for [store] in this process.
  static bool isSettled(
    KeyValueStore store,
    AccountScope account, {
    Iterable<String> trustedLegacyScopeIds = const <String>[],
  }) => DurableScopeBootstrap.isSettled(
    store,
    account,
    trustedLegacyScopeIds: trustedLegacyScopeIds,
  );

  /// Forgets this process's memo.
  ///
  /// Test-only: a check that wants to observe a second first-launch has to reset
  /// the process-wide memo. Exposed rather than reachable through
  /// [DurableScopeBootstrap.debugReset] alone so a caller of *this* facade does
  /// not have to import the layer below it.
  static void debugReset() => DurableScopeBootstrap.debugReset();
}
