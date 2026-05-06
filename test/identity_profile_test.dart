import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/identity_core.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('identity core generators', () {
    test('profile generator reuses valid stored profile for the same owner', () {
      final owner = IdentityOwnerKey.account(1001);
      final storedProfile = IdentityCoreProfile(
        owner: owner,
        buvid: IdentityCoreGenerators.deriveBuvidFromSeed('AABBCCDDEEFF'),
      );

      final generated = const IdentityCoreProfileGenerator().generate(
        IdentityCoreGenerationContext(
          owner: owner,
          storedProfile: storedProfile,
        ),
      );

      expect(generated.owner.key, owner.key);
      expect(generated.buvid, storedProfile.buvid);
      expect(
        const IdentityCoreProfileValidator().validate(generated).isValid,
        isTrue,
      );
    });

    test('profile generator regenerates when owner changes', () {
      final guestOwner = const IdentityOwnerKey.guest();
      final accountOwner = IdentityOwnerKey.account(1002);
      final storedProfile = IdentityCoreProfile(
        owner: guestOwner,
        buvid: IdentityCoreGenerators.deriveBuvidFromSeed('001122334455'),
      );

      final generated = const IdentityCoreProfileGenerator().generate(
        IdentityCoreGenerationContext(
          owner: accountOwner,
          storedProfile: storedProfile,
        ),
      );

      expect(generated.owner.key, accountOwner.key);
      expect(generated.buvid, isNot(storedProfile.buvid));
      expect(IdentityCoreGenerators.validateBuvid(generated.buvid).isValid, isTrue);
    });

    test('rule-conforming BUVID exposes extracted MD5 characters', () {
      final buvid = IdentityCoreGenerators.deriveBuvidFromSeed(
        'AA:BB:CC:DD:EE:FF',
      );

      expect(buvid, startsWith('XY'));
      expect(buvid.length, 37);
      expect(IdentityCoreGenerators.validateBuvid(buvid).isValid, isTrue);

      final md5Body = buvid.substring(5);
      expect(buvid.substring(2, 5), '${md5Body[2]}${md5Body[12]}${md5Body[22]}');
    });

    test('device/local ids are owner-scoped and checksum-valid', () {
      final guestBuvid = IdentityCoreGenerators.deriveBuvidFromSeed('guest-seed');
      final accountBuvid = IdentityCoreGenerators.deriveBuvidFromSeed('account-seed');

      final guestDeviceId = IdentityCoreGenerators.generateDeviceLocalId(
        owner: const IdentityOwnerKey.guest(),
        buvid: guestBuvid,
      );
      final accountDeviceId = IdentityCoreGenerators.generateDeviceLocalId(
        owner: IdentityOwnerKey.account(42),
        buvid: accountBuvid,
      );

      expect(
        IdentityCoreGenerators.validateDeviceLocalId(guestDeviceId).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateDeviceLocalId(accountDeviceId).isValid,
        isTrue,
      );
      expect(guestDeviceId, isNot(accountDeviceId));
      expect(guestDeviceId, isNot('0'));
    });

    test('fp local/remote derive from owner identity and satisfy checksum rule', () {
      final snapshot = IdentityCoreGenerators.deriveProfile(
        owner: IdentityOwnerKey.account(2048),
        storedProfile: IdentityCoreProfile(
          owner: IdentityOwnerKey.account(2048),
          buvid: IdentityCoreGenerators.deriveBuvidFromSeed('C0FFEE2048'),
        ),
        now: DateTime.utc(2026, 5, 6, 11, 22, 33),
      );

      expect(snapshot.fpLocal, snapshot.fpRemote);
      expect(IdentityCoreGenerators.validateFp(snapshot.fpLocal).isValid, isTrue);
      expect(snapshot.fpLocal, isNot('1' * 64));
    });

    test('session id and trace id follow expected runtime format', () {
      final sessionId = IdentityCoreGenerators.generateSessionId();
      final traceId = IdentityCoreGenerators.generateTraceId(
        now: DateTime.utc(2026, 5, 6, 12, 0, 0),
      );

      expect(IdentityCoreGenerators.validateSessionId(sessionId).isValid, isTrue);
      expect(IdentityCoreGenerators.validateTraceId(traceId).isValid, isTrue);
      expect(traceId, isNot('11111111111111111111111111111111:1111111111111111:0:0'));
    });
  });

  group('legacy-facing wrappers use identity core contracts', () {
    test('LoginUtils, IdUtils, and Constants expose valid identity values', () {
      final buvid = LoginUtils.generateBuvid();
      final buvid3 = IdUtils.genBuvid3();
      final traceId = IdUtils.genTraceId();
      final deviceId = LoginUtils.genDeviceId();
      final runtimeTraceFromConstants = Constants.traceId;

      expect(IdentityCoreGenerators.validateBuvid(buvid).isValid, isTrue);
      expect(IdentityCoreGenerators.validateBuvid3(buvid3).isValid, isTrue);
      expect(IdentityCoreGenerators.validateTraceId(traceId).isValid, isTrue);
      expect(
        IdentityCoreGenerators.validateDeviceLocalId(deviceId).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateTraceId(runtimeTraceFromConstants).isValid,
        isTrue,
      );
      expect(
        runtimeTraceFromConstants,
        isNot('11111111111111111111111111111111:1111111111111111:0:0'),
      );
    });

    test('owner snapshot keeps guest/login and account-to-account transitions isolated', () {
      final guest = OwnerScopedIdentitySnapshot.fromAccount(AnonymousAccount());
      final accountA = OwnerScopedIdentitySnapshot.fromAccount(
        _loginAccount(mid: 2201, buvid: 'ACCOUNT_SNAPSHOT_A'),
      );
      final accountB = OwnerScopedIdentitySnapshot.fromAccount(
        _loginAccount(mid: 2202, buvid: 'ACCOUNT_SNAPSHOT_B'),
      );

      expect(guest.owner.key, 'guest');
      expect(guest.isLogin, isFalse);
      expect(accountA.owner.key, 'account:2201');
      expect(accountA.isLogin, isTrue);
      expect(accountB.owner.key, 'account:2202');
      expect(accountB.isLogin, isTrue);
      expect(accountA.profile.buvid, isNot(guest.profile.buvid));
      expect(accountB.profile.buvid, isNot(accountA.profile.buvid));
    });
  });
}

LoginAccount _loginAccount({required int mid, required String buvid}) {
  final cookieJar = DefaultCookieJar(ignoreExpires: true)
    ..domainCookies['bilibili.com'] = {
      '/': {
        'DedeUserID': SerializableCookie(Cookie('DedeUserID', '$mid')..setBiliDomain()),
        'bili_jct': SerializableCookie(Cookie('bili_jct', 'csrf_$mid')..setBiliDomain()),
        'SESSDATA': SerializableCookie(Cookie('SESSDATA', 'sess_$mid')..setBiliDomain()),
      },
    };
  return LoginAccount(cookieJar, 'ACCESS_KEY_$mid', 'REFRESH_$mid', {}, buvid);
}
