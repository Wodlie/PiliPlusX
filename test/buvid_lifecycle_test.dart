import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
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
    tempDir = await Directory.systemTemp.createTemp('pili_buvid_lifecycle_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    expect(
      Accounts.account.isOpen,
      isTrue,
      reason: 'GStorage.init() must open the account box via Accounts.init() before tests run.',
    );
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

  group('BUVID lifecycle', () {
    test('guest flow keeps guest BUVID isolated and regenerates it after delete', () async {
      final anonymous = AnonymousAccount();
      final initialBuvid = anonymous.buvid;

      expect(initialBuvid, startsWith('XY'));
      expect(Pref.guestBuvid, initialBuvid);
      expect(anonymous.grpcHeaders['buvid'], initialBuvid);
      expect(anonymous.grpcHeaders.containsKey('authorization'), isFalse);

      await anonymous.delete();

      final regeneratedBuvid = Pref.guestBuvid;
      expect(regeneratedBuvid, startsWith('XY'));
      expect(regeneratedBuvid, isNot(initialBuvid));
      expect(anonymous.buvid, regeneratedBuvid);
      expect(
        anonymous.cookieJar.domainCookies['bilibili.com']?['/']?['buvid3']?.cookie.value,
        isNotEmpty,
      );
    });

    test('legacy login account without stored BUVID regenerates one and marks it for persistence', () async {
      final account = _createLoginAccount(mid: 1001);

      expect(account.buvid, startsWith('XY'));
      expect(account.needsBuvidPersist, isTrue);

      await account.onChange();

      final persisted = Accounts.account.get(account.mid.toString());
      expect(persisted, isNotNull);
      expect(persisted!.buvid, account.buvid);
      expect(persisted.accessKey, account.accessKey);
    });

    test('refresh restores account ownership and clears legacy global BUVID key', () async {
      final account = _createLoginAccount(
        mid: 1002,
        buvid: 'ACCOUNT_BUVID_RESTORED',
        type: {AccountType.recommend},
      )..activated = true;

      await Accounts.account.put(account.mid.toString(), account);
      await GStorage.localCache.put(LocalCacheKey.legacyBuvid, 'LEGACY_GLOBAL_BUVID');

      await Accounts.refresh();

      expect(Accounts.get(AccountType.recommend).buvid, account.buvid);
      expect(GStorage.localCache.get(LocalCacheKey.legacyBuvid), isNull);
      expect(Accounts.account.get(account.mid.toString())!.buvid, account.buvid);
    });

    test('switching account ownership makes app headers follow the active account BUVID', () async {
      final first = _createLoginAccount(
        mid: 1003,
        buvid: 'ACCOUNT_BUVID_A',
      )..activated = true;
      final second = _createLoginAccount(
        mid: 1004,
        buvid: 'ACCOUNT_BUVID_B',
      )..activated = true;

      await Accounts.set(AccountType.recommend, first);
      final firstHeaders = LoginHttp.appHeaders(
        buvid: Accounts.get(AccountType.recommend).buvid,
        appKey: 'android_hd',
        userAgent: Constants.userAgent,
      );

      await Accounts.set(AccountType.recommend, second);
      final secondHeaders = LoginHttp.appHeaders(
        buvid: Accounts.get(AccountType.recommend).buvid,
        appKey: 'android_hd',
        userAgent: Constants.userAgent,
      );

      expect(first.type.contains(AccountType.recommend), isFalse);
      expect(second.type.contains(AccountType.recommend), isTrue);
      expect(firstHeaders['buvid'], 'ACCOUNT_BUVID_A');
      expect(secondHeaders['buvid'], 'ACCOUNT_BUVID_B');
    });

    test('delete plus relogin keeps BUVID account-owned instead of reusing the deleted account value', () async {
      final oldAccount = _createLoginAccount(
        mid: 1005,
        buvid: 'ACCOUNT_BUVID_OLD',
      )..activated = true;

      await Accounts.set(AccountType.video, oldAccount);
      await Accounts.deleteAll({oldAccount});

      expect(Accounts.get(AccountType.video), isA<AnonymousAccount>());
      expect(Accounts.account.get(oldAccount.mid.toString()), isNull);

      final reloginAccount = _createLoginAccount(
        mid: 1005,
        buvid: 'ACCOUNT_BUVID_NEW',
      )..activated = true;

      await Accounts.set(AccountType.video, reloginAccount);

      expect(Accounts.get(AccountType.video).buvid, 'ACCOUNT_BUVID_NEW');
      expect(Accounts.get(AccountType.video).buvid, isNot(oldAccount.buvid));
    });

    test('startup guest snapshot stays guest until login replaces the main owner snapshot', () async {
      await Accounts.refresh();

      final startupSnapshot = Accounts.mainIdentity;
      final startupAccount = Accounts.main;

      expect(startupSnapshot.isLogin, isFalse);
      expect(startupSnapshot.owner.key, 'guest');
      expect(startupSnapshot.profile.buvid, Pref.guestBuvid);
      expect(startupAccount.buvid, Pref.guestBuvid);

      final loggedIn = _createLoginAccount(
        mid: 1101,
        buvid: 'LOGIN_OWNER_BUVID_1101',
        type: {AccountType.main},
      )..activated = true;

      await Accounts.account.put(loggedIn.mid.toString(), loggedIn);
      await Accounts.refresh();

      expect(Accounts.mainIdentity.isLogin, isTrue);
      expect(Accounts.mainIdentity.owner.key, 'account:1101');
      expect(Accounts.mainIdentity.profile.buvid, 'LOGIN_OWNER_BUVID_1101');
      expect(Accounts.main.buvid, 'LOGIN_OWNER_BUVID_1101');
      expect(Accounts.mainIdentity.profile.buvid, isNot(startupSnapshot.profile.buvid));
      expect(Accounts.main.buvid, isNot(startupAccount.buvid));
    });

    test('account switch updates the published snapshot and active role together', () async {
      final first = _createLoginAccount(
        mid: 1201,
        buvid: 'ACCOUNT_SWITCH_A',
      )..activated = true;
      final second = _createLoginAccount(
        mid: 1202,
        buvid: 'ACCOUNT_SWITCH_B',
      )..activated = true;

      await Accounts.set(AccountType.recommend, first);
      final firstSnapshot = Accounts.snapshot(AccountType.recommend);

      await Accounts.set(AccountType.recommend, second);
      final secondSnapshot = Accounts.snapshot(AccountType.recommend);

      expect(firstSnapshot.owner.key, 'account:1201');
      expect(firstSnapshot.profile.buvid, 'ACCOUNT_SWITCH_A');
      expect(Accounts.get(AccountType.recommend).mid, 1202);
      expect(secondSnapshot.owner.key, 'account:1202');
      expect(secondSnapshot.profile.buvid, 'ACCOUNT_SWITCH_B');
      expect(secondSnapshot.profile.buvid, isNot(firstSnapshot.profile.buvid));
      expect(Accounts.get(AccountType.recommend).buvid, 'ACCOUNT_SWITCH_B');
      expect(Accounts.snapshot(AccountType.recommend).profile.buvid, 'ACCOUNT_SWITCH_B');
    });
  });

  group('BUVID header builders', () {
    test('REST app headers use the supplied BUVID and optional content type', () {
      final headers = LoginHttp.appHeaders(
        buvid: 'REST_BUVID',
        appKey: 'android_hd',
        userAgent: Constants.userAgent,
        contentType: 'application/x-www-form-urlencoded',
      );

      expect(headers['buvid'], 'REST_BUVID');
      expect(headers['app-key'], 'android_hd');
      expect(headers['user-agent'], Constants.userAgent);
      expect(headers['content-type'], 'application/x-www-form-urlencoded');
    });

    test('gRPC headers encode BUVID from the owning login account and refresh maps per access', () {
      final account = _createLoginAccount(
        mid: 1006,
        buvid: 'GRPC_LOGIN_BUVID',
        accessKey: 'ACCESS_KEY_1006',
      );

      final firstHeaders = account.grpcHeaders;
      final secondHeaders = account.grpcHeaders;
      final metadata = Metadata.fromBuffer(
        base64Decode(firstHeaders['x-bili-metadata-bin']!),
      );
      final device = Device.fromBuffer(
        base64Decode(firstHeaders['x-bili-device-bin']!),
      );

      expect(identical(firstHeaders, secondHeaders), isFalse);
      expect(firstHeaders['buvid'], 'GRPC_LOGIN_BUVID');
      expect(firstHeaders['authorization'], 'identify_v1 ACCESS_KEY_1006');
      expect(metadata.buvid, 'GRPC_LOGIN_BUVID');
      expect(metadata.accessKey, 'ACCESS_KEY_1006');
      expect(device.buvid, 'GRPC_LOGIN_BUVID');
    });

    test('anonymous gRPC headers encode guest BUVID without authorization', () {
      final anonymous = AnonymousAccount();
      final headers = anonymous.grpcHeaders;
      final metadata = Metadata.fromBuffer(
        base64Decode(headers['x-bili-metadata-bin']!),
      );
      final device = Device.fromBuffer(
        base64Decode(headers['x-bili-device-bin']!),
      );

      expect(headers['buvid'], anonymous.buvid);
      expect(headers.containsKey('authorization'), isFalse);
      expect(metadata.buvid, anonymous.buvid);
      expect(metadata.accessKey, isEmpty);
      expect(device.buvid, anonymous.buvid);
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
