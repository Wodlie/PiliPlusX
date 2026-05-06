import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';

import 'identity_owner.dart';

abstract interface class IdentityProfileView {
  IdentityOwnerKey get owner;

  String get buvid;
}

abstract interface class IdentityGenerationContext {
  IdentityOwnerKey get owner;

  IdentityProfileView? get storedProfile;
}

final class IdentityValidationResult {
  const IdentityValidationResult._({
    required this.isValid,
    this.reason,
  });

  const IdentityValidationResult.valid() : this._(isValid: true);

  const IdentityValidationResult.invalid(String reason)
    : this._(isValid: false, reason: reason);

  final bool isValid;
  final String? reason;
}

abstract interface class IdentityProfileValidator<T extends IdentityProfileView> {
  IdentityValidationResult validate(T profile);
}

abstract interface class IdentityProfileStore<T extends IdentityProfileView> {
  FutureOr<T?> read(IdentityOwnerKey owner);

  FutureOr<void> write(T profile);

  FutureOr<void> delete(IdentityOwnerKey owner);
}

abstract interface class IdentityResolvedSnapshot {
  IdentityOwnerKey get owner;

  IdentityProfileView get profile;

  bool get isLogin;

  int get mid;

  String? get accessKey;

  String? get refreshToken;

  String get csrf;

  DefaultCookieJar get cookieJar;

  String get buvid => profile.buvid;
}

abstract interface class IdentitySnapshotResolver<T extends IdentityResolvedSnapshot> {
  FutureOr<T> resolve(IdentityOwnerKey owner);
}
