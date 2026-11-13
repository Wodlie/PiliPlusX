import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Account identity for every ContentGuard artifact.
///
/// ## Two identities, one object
///
/// A live account has to answer two different questions, and conflating them is
/// what orphans user state whenever a credential rotates:
///
/// | question | identity | value |
/// |---|---|---|
/// | "is this the same request identity / credential generation?" | [id] | rotates on access-key, cookie, device, buvid, mobiApp or login-state change |
/// | "is this the same _person's_ saved state?" | [durableId] | stable for one logged-in mid, forever |
///
/// [id] stays exactly what it was: the credential-generation digest used by the
/// transient pipeline, the reply bridge, the presenter store, decision cache keys
/// and traces. It must keep rotating — a stale decision, presentation or anchor
/// computed under an old key must never be handed to a new one.
///
/// [durableId] is the **persistence** identity: the namespace of violations,
/// corrections, suggestions and any other accepted/rejected/snoozed user state.
/// It is derived from the account's mid alone, so re-login, key rotation, cookie
/// rotation, device change, buvid change and mobiApp change of the same account
/// keep reading and writing the same records. Two different mids can never share
/// it, and it contains no credential material in any form.
///
/// ## Credentials never become part of this object
///
/// An [AccountScope] stores **no** access key, cookie, token, cookie jar or
/// request header. The only persistable forms are [id] and [durableId]: SHA-256
/// digests computed in memory from identity material. Both are safe in storage
/// keys, cache keys, logs and `toString`; the raw material is not, and is only
/// ever used as digest input (plan-core §8.1).
///
/// ## When there is no stable identity
///
/// [durableIdOfMid] returns null for a non-positive mid, which is what a tourist
/// or an anonymous session carries. [durableId] then falls back to [id]: the
/// guest keeps the conservative, credential-isolated namespace it always had, so
/// two guests can never be merged into one persisted owner and no opaque hash is
/// ever *inferred* to be an account. The same fallback applies to a scope built
/// by hand through the bare `const AccountScope(id: ..., isGuest: ...)`
/// constructor, which keeps every existing caller working unchanged.
///
/// ## Why this file has no app imports
///
/// This is a pure data layer: it imports `dart:convert` and `package:crypto`
/// and nothing else, so it can be compiled and tested without the app's
/// dependency graph. Callers holding a live `Account` use
/// `account_scope_adapter.dart`, which is where that dependency belongs.
final class AccountScope {
  /// Builds a scope from an explicit digest.
  ///
  /// [durableId] is optional so the pre-existing
  /// `const AccountScope(id: ..., isGuest: ...)` call sites keep their exact
  /// behaviour: without it the durable identity *is* [id], i.e. the record
  /// namespace is unchanged for that caller.
  const AccountScope({
    required this.id,
    required this.isGuest,
    String? durableId,
  }) : _durableId = durableId;

  /// Digests explicit identity material into a request scope.
  ///
  /// Exists so callers that hold the material (a restored local record, a
  /// transport header snapshot) or a test can derive the same scope id without
  /// constructing an `Account`. The arguments are used as digest input only and
  /// are never retained.
  ///
  /// The argument set and the [id] digest formula are frozen: stored keys, cache
  /// keys and persisted evidence stamp ids minted by this function, so adding,
  /// reordering or re-encoding an argument would invalidate all of them. The
  /// durable identity is derived separately and never from these arguments, so
  /// rotating any of them cannot move a user's saved state.
  factory AccountScope.fromIdentityMaterial({
    required int mid,
    required bool isLogin,
    required String? accessKey,
    required String buvid,
    required String mobiApp,
    required String deviceDigest,
    required String cookieDigest,
  }) {
    final material = <String>[
      _digestSalt,
      mid.toString(),
      isLogin.toString(),
      accessKey ?? '',
      buvid,
      mobiApp,
      deviceDigest,
      cookieDigest,
    ].join('\u0000');
    return AccountScope(
      id: 'cgs1_${sha256.convert(utf8.encode(material))}',
      isGuest: !isLogin,
      durableId: durableIdOfMid(isLogin ? mid : 0),
    );
  }

  /// Version marker mixed into the request digest so a future scope definition
  /// cannot collide with ids minted by this one.
  static const String _digestSalt = 'contentguard.account.scope.v1';

  /// Version marker and domain separator of the durable digest.
  ///
  /// A distinct salt *and* a distinct prefix mean the two id spaces can never
  /// collide, even if one day both are derived from the same material.
  static const String _durableSalt = 'contentguard.account.durable.v1';

  /// Prefix of every durable account identity.
  static const String durableIdPrefix = 'cgd1_';

  /// Prefix of every request (credential-generation) identity.
  static const String requestIdPrefix = 'cgs1_';

  /// Durable persistence identity of [mid], or null when [mid] is not a real
  /// logged-in mid.
  ///
  /// Domain-separated from [id] and computed from the mid alone: the value is
  /// therefore identical across access-key, cookie, device, buvid and mobiApp
  /// rotations of one account, and different for every different mid. It is a
  /// digest, never the raw mid, so a storage key does not spell out who the user
  /// is.
  ///
  /// A non-positive mid yields null on purpose: "no verifiable positive mid"
  /// means "no durable owner", and callers must fall back to the isolated
  /// request scope rather than merge unknown identities together.
  static String? durableIdOfMid(int mid) {
    if (mid <= 0) {
      return null;
    }
    final material = <String>[_durableSalt, mid.toString()].join('\u0000');
    return '$durableIdPrefix${sha256.convert(utf8.encode(material))}';
  }

  /// Opaque, path-safe digest of the account's **credential generation**. The
  /// identity of a request, a cached decision, a presentation row or a trace.
  ///
  /// This value is expected to change on re-login, key rotation, cookie
  /// rotation, device change or platform change of the same account. Nothing
  /// durable may be keyed by it.
  final String id;

  /// Whether the scope was derived from a non-logged-in account.
  final bool isGuest;

  final String? _durableId;

  /// Explicit alias for [id] that reads as what it is: the request identity.
  ///
  /// Same value, same semantics, same freeze. It exists so a call site can say
  /// which of the two identities it means instead of relying on the reader
  /// knowing which one `id` currently stands for.
  String get requestScopeId => id;

  /// Opaque, path-safe digest of the **durable persistence identity**.
  ///
  /// Stable for one logged-in mid across credential, device and platform
  /// rotation; equals [id] when no verifiable mid was available (guests, and
  /// scopes built by hand without a durable identity).
  String get durableId => _durableId ?? id;

  /// Whether [durableId] is a real account-level identity rather than the
  /// conservative fallback to [id].
  bool get hasStableDurableId => _durableId != null;

  /// Whether two scopes persist into the same namespace.
  bool sharesDurableNamespaceWith(AccountScope other) =>
      durableId == other.durableId;

  /// Equality is request identity only, exactly as before: [id] plus [isGuest].
  ///
  /// [durableId] is deliberately *not* part of it. Two scopes with the same
  /// request digest describe the same credential generation — that is what the
  /// pipeline, the bridge and the presenter store compare — and adding a
  /// persistence field here would silently change every one of those checks.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountScope && id == other.id && isGuest == other.isGuest;

  @override
  int get hashCode => Object.hash(id, isGuest);

  @override
  String toString() => 'AccountScope(id: $id, isGuest: $isGuest)';
}
