import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';

import 'identity_contracts.dart';
import 'identity_owner.dart';
import 'identity_profile.dart';

final class OwnerScopedIdentitySnapshot implements IdentityResolvedSnapshot {
  const OwnerScopedIdentitySnapshot({
    required this.owner,
    required this.profile,
    required this.isLogin,
    required this.mid,
    required this.accessKey,
    required this.refreshToken,
    required this.csrf,
    required this.cookieJar,
  });

  factory OwnerScopedIdentitySnapshot.fromAccount(Account account) {
    if (account is NoAccount) {
      throw StateError('NoAccount cannot resolve into an owner-scoped identity snapshot.');
    }

    final owner = account.identityOwner;
    return OwnerScopedIdentitySnapshot(
      owner: owner,
      profile: IdentityCoreProfile(owner: owner, buvid: account.buvid),
      isLogin: account.isLogin,
      mid: account.mid,
      accessKey: account.accessKey,
      refreshToken: account.refresh,
      csrf: account.csrf,
      cookieJar: account.cookieJar,
    );
  }

  @override
  final IdentityOwnerKey owner;

  @override
  final IdentityCoreProfile profile;

  @override
  final bool isLogin;

  @override
  final int mid;

  @override
  final String? accessKey;

  @override
  final String? refreshToken;

  @override
  final String csrf;

  @override
  final DefaultCookieJar cookieJar;
}
