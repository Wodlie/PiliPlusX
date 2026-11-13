import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';

/// Converts the live [account] into a ContentGuard [AccountScope].
///
/// This adapter is the *only* place that couples account identity to the
/// ContentGuard scope model, and it lives outside `account_scope.dart` on
/// purpose: importing `account.dart` drags in the whole transport bootstrap
/// (`http/init.dart` -> `main.dart` -> `nativeapi`), which would make the pure
/// model layer untestable.
///
/// Only published identity state is read: no validation is triggered, no
/// network call is made and no storage is written. The internal `NoAccount`
/// sentinel has no cookie jar and no buvid, so it throws inside
/// [AccountHealthIdentity.capture]; callers holding it must pass the real
/// current account instead of inventing a fake scope.
///
/// The returned scope carries both identities:
///
/// * [AccountScope.id] — the credential-generation request identity, still
///   derived from key, cookie, device, buvid and platform, so it rotates with
///   them;
/// * [AccountScope.durableId] — the persistence identity, derived from the mid
///   alone, so saved violations, corrections and suggestion decisions survive
///   that rotation.
///
/// A non-positive mid (tourist, anonymous, a login record whose mid could not be
/// resolved) yields no durable identity, and the scope falls back to the
/// isolated request identity. Nothing here ever infers an owner from a hash.
AccountScope scopeOf(Account account) {
  final identity = AccountHealthIdentity.capture(account);
  return AccountScope.fromIdentityMaterial(
    mid: identity.mid,
    isLogin: identity.isLogin,
    accessKey: identity.accessKey,
    buvid: identity.buvid,
    mobiApp: identity.mobiApp,
    deviceDigest: identity.deviceDigest,
    cookieDigest: identity.cookieDigest,
  );
}

/// Durable persistence identity of [account], or null when it has no verifiable
/// positive mid.
///
/// Exposed for callers that need the persistence namespace without building a
/// whole request scope — the durable-scope migration, for instance, which is
/// handed a target account and must not depend on the credential generation of
/// the moment.
String? durableScopeIdOf(Account account) {
  final mid = account.isLogin ? account.mid : 0;
  return AccountScope.durableIdOfMid(mid);
}
