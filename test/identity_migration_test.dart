import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/accounts/identity_core.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_identity_migration_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDown(() async {
    await Accounts.account.clear();
    await GStorage.localCache.clear();
    for (final accountType in AccountType.values) {
      Accounts.accountMode[accountType.index] = AnonymousAccount();
    }
    await AnonymousAccount().delete();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('identity migration', () {
    test('guest migration repairs a malformed stored BUVID once and keeps repeated reads stable', () {
      GStorage.localCache.put(LocalCacheKey.guestBuvid, 'broken-guest');

      final repaired = Pref.guestBuvid;
      final repeated = Pref.guestBuvid;

      expect(
        IdentityCoreGenerators.validateBuvid(repaired).isValid,
        isTrue,
      );
      expect(repeated, repaired);
      expect(GStorage.localCache.get(LocalCacheKey.guestBuvid), repaired);
    });

    test('guest migration preserves a valid stored BUVID', () {
      final validGuest = IdentityCoreGenerators.deriveBuvidFromSeed('guest-valid');
      GStorage.localCache.put(LocalCacheKey.guestBuvid, validGuest);

      expect(Pref.guestBuvid, validGuest);
      expect(GStorage.localCache.get(LocalCacheKey.guestBuvid), validGuest);
    });

    test('guest migration recovers from a corrupt stored BUVID by promoting a valid legacy entry', () {
      final validLegacyGuest = IdentityCoreGenerators.deriveBuvidFromSeed(
        'guest-legacy-valid',
      );
      GStorage.localCache.put(LocalCacheKey.guestBuvid, 'broken-guest');
      GStorage.localCache.put(LocalCacheKey.legacyBuvid, validLegacyGuest);

      final recovered = Pref.guestBuvid;
      final repeated = Pref.guestBuvid;

      expect(recovered, validLegacyGuest);
      expect(repeated, validLegacyGuest);
      expect(
        IdentityCoreGenerators.validateBuvid(recovered).isValid,
        isTrue,
      );
      expect(GStorage.localCache.get(LocalCacheKey.guestBuvid), validLegacyGuest);
      expect(GStorage.localCache.get(LocalCacheKey.legacyBuvid), isNull);
    });

    test('account migration repairs a malformed account BUVID and marks it for persistence', () async {
      final account = _createLoginAccount(mid: 2001, buvid: 'broken-account-buvid');

      expect(
        IdentityCoreGenerators.validateBuvid(account.buvid).isValid,
        isTrue,
      );
      expect(account.needsBuvidPersist, isTrue);

      await account.onChange();

      final persisted = Accounts.account.get(account.mid.toString());
      expect(persisted, isNotNull);
      expect(persisted!.buvid, account.buvid);
      expect(persisted.needsBuvidPersist, isFalse);
    });

    test('account migration preserves a valid account BUVID', () {
      final validAccountBuvid = IdentityCoreGenerators.deriveBuvidFromSeed('account-valid');
      final account = _createLoginAccount(mid: 2002, buvid: validAccountBuvid);

      expect(account.buvid, validAccountBuvid);
      expect(account.needsBuvidPersist, isFalse);
    });

    test('old account records without device profile still deserialize and fall back safely', () {
      final restored = LoginAccount.restored(
        _createCookieJar(mid: 2004),
        'ACCESS_KEY_2004',
        'REFRESH_2004',
        {AccountType.main},
        IdentityCoreGenerators.deriveBuvidFromSeed('legacy-device-profile-2004'),
      );
      
      expect(restored.deviceProfile, isNull);
      final fallbackProfile = AppDeviceProfiles.defaultDeviceProfileForOwner(
        'account:2004',
      );
      final identity = RequestIdentityAdapter.fromAccount(
        account: restored,
        userAgent: AppDeviceProfiles.androidHd.userAgent,
      );
      expect(identity.profile.deviceProfile, fallbackProfile);
      expect(identity.deviceName, fallbackProfile.deviceName);
      expect(identity.devicePlatform, fallbackProfile.devicePlatform);
      expect(identity.profile.deviceProfile.hasGenericPlaceholderFields, isFalse);
      expect(restored.needsBuvidPersist, isTrue);
    });

    test('new account records persist and reload the device profile', () async {
      final storedProfile = AppDeviceProfile(
        brand: 'Samsung',
        model: 'SM-S9280',
        osver: '16',
      );
      final account = _createLoginAccount(
        mid: 2005,
        buvid: IdentityCoreGenerators.deriveBuvidFromSeed('persisted-device-profile-2005'),
        deviceProfile: storedProfile,
      );

      await account.onChange();

      final restored = Accounts.account.get(account.mid.toString());
      expect(restored, isNotNull);
      expect(restored!.deviceProfile, isNotNull);
      expect(restored.deviceProfile!.brand, storedProfile.brand);
      expect(restored.deviceProfile!.model, storedProfile.model);
      expect(restored.deviceProfile!.osver, storedProfile.osver);
      expect(restored.toJson()!['deviceProfile'], storedProfile.toJson());
      final fromJson = LoginAccount.fromJson(restored.toJson()!);
      expect(fromJson.deviceProfile!.brand, storedProfile.brand);
      expect(fromJson.deviceProfile!.model, storedProfile.model);
      expect(fromJson.deviceProfile!.osver, storedProfile.osver);
      expect(fromJson.deviceProfile!.hasGenericPlaceholderFields, isFalse);
    });

    test('fallback device profile selection is deterministic for the same owner', () {
      final first = AppDeviceProfiles.defaultDeviceProfileForOwner('account:2333');
      final second = AppDeviceProfiles.defaultDeviceProfileForOwner('account:2333');
      final guest = AppDeviceProfiles.defaultDeviceProfileForOwner('guest');

      expect(first, second);
      expect(first.hasGenericPlaceholderFields, isFalse);
      expect(guest.hasGenericPlaceholderFields, isFalse);
    });

    test('logout clears account identity and creates a fresh guest profile', () async {
      await Pref.deleteGuestBuvid();
      final account = _createLoginAccount(mid: 2003)..activated = true;

      await Accounts.set(AccountType.video, account);
      await Accounts.deleteAll({account});

      expect(Accounts.get(AccountType.video), isA<AnonymousAccount>());
      expect(Accounts.account.get(account.mid.toString()), isNull);

      final freshGuestBuvid = Pref.guestBuvid;
      expect(
        IdentityCoreGenerators.validateBuvid(freshGuestBuvid).isValid,
        isTrue,
      );
      expect(GStorage.localCache.get(LocalCacheKey.guestBuvid), freshGuestBuvid);
    });
  });
}

LoginAccount _createLoginAccount({
  required int mid,
  String? buvid,
  Set<AccountType>? type,
  String? accessKey,
  AppDeviceProfile? deviceProfile,
}) {
  return LoginAccount(
    _createCookieJar(mid: mid),
    accessKey ?? 'ACCESS_KEY_$mid',
    'REFRESH_$mid',
    type,
    buvid,
    deviceProfile,
  );
}

DefaultCookieJar _createCookieJar({required int mid}) {
  final cookieJar = DefaultCookieJar(ignoreExpires: true);
  final cookies = <Cookie>[
    Cookie('DedeUserID', '$mid')..setBiliDomain(),
    Cookie('bili_jct', 'csrf_$mid')..setBiliDomain(),
    Cookie('SESSDATA', 'sess_$mid')..setBiliDomain(),
  ];
  cookieJar.domainCookies['bilibili.com'] = {
    '/': {
      for (final cookie in cookies) cookie.name: SerializableCookie(cookie),
    },
  };
  return cookieJar;
}
