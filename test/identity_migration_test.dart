import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
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
}) {
  return LoginAccount(
    _createCookieJar(mid: mid),
    accessKey ?? 'ACCESS_KEY_$mid',
    'REFRESH_$mid',
    type,
    buvid,
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
