import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/identity_core.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_grpc_identity_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    expect(Accounts.account.isOpen, isTrue);
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

  group('gRPC identity', () {
    test('login metadata and device-bin use the owner-scoped identity source', () async {
      final account = _createLoginAccount(
        mid: 2101,
        buvid: IdentityCoreGenerators.deriveBuvidFromSeed('grpc-login-owner-2101'),
        type: {AccountType.main},
        accessKey: 'ACCESS_KEY_2101',
      )..activated = true;

      await Accounts.set(AccountType.main, account);

      final snapshot = Accounts.mainIdentity;
      final derived = IdentityCoreGenerators.deriveProfile(
        owner: snapshot.owner,
        storedProfile: snapshot.profile,
      );
      final headers = Accounts.main.grpcHeaders;
      final metadata = Metadata.fromBuffer(
        base64Decode(headers['x-bili-metadata-bin']!),
      );
      final device = Device.fromBuffer(
        base64Decode(headers['x-bili-device-bin']!),
      );
      final sendMsgRequest = ImGrpc.buildSendMsgRequest(
        senderUid: account.mid,
        receiverId: 9001,
        content: 'hello',
      );
      final syncRequest = ImGrpc.buildSyncFetchSessionMsgsRequest(talkerId: 9001);

      expect(snapshot.owner.key, 'account:2101');
      expect(headers['authorization'], 'identify_v1 ACCESS_KEY_2101');
      expect(headers['buvid'], account.buvid);
      expect(headers['x-bili-trace-id'], derived.traceId);
      expect(headers['x-bili-aurora-zone'], 'sh001');
      expect(headers['x-bili-aurora-eid'], IdUtils.genAuroraEid(account.mid));
      expect(metadata.buvid, account.buvid);
      expect(metadata.accessKey, 'ACCESS_KEY_2101');
      expect(device.buvid, account.buvid);
      expect(device.fpLocal, derived.fpLocal);
      expect(device.fpRemote, derived.fpRemote);
      expect(device.fp, derived.fpLocal);
      expect(device.guestId, derived.deviceId);
      expect(sendMsgRequest.devId, derived.deviceId);
      expect(syncRequest.devId, derived.deviceId);
      expect(sendMsgRequest.devId, isNot('1'));
      expect(syncRequest.devId, isNot('1'));
    });

    test('anonymous grpc and im requests use guest identity without placeholder devId', () async {
      await Accounts.refresh();

      final guest = Accounts.main as AnonymousAccount;
      final snapshot = Accounts.mainIdentity;
      final derived = IdentityCoreGenerators.deriveProfile(
        owner: snapshot.owner,
        storedProfile: snapshot.profile,
      );
      final headers = guest.grpcHeaders;
      final metadata = Metadata.fromBuffer(
        base64Decode(headers['x-bili-metadata-bin']!),
      );
      final device = Device.fromBuffer(
        base64Decode(headers['x-bili-device-bin']!),
      );
      final sendMsgRequest = ImGrpc.buildSendMsgRequest(
        senderUid: 0,
        receiverId: 9002,
        content: 'guest',
      );
      final syncRequest = ImGrpc.buildSyncFetchSessionMsgsRequest(talkerId: 9002);

      expect(snapshot.owner.key, 'guest');
      expect(snapshot.profile.buvid, Pref.guestBuvid);
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('x-bili-aurora-eid'), isFalse);
      expect(headers['buvid'], guest.buvid);
      expect(headers['x-bili-trace-id'], derived.traceId);
      expect(headers['x-bili-aurora-zone'], 'sh001');
      expect(metadata.buvid, guest.buvid);
      expect(metadata.accessKey, isEmpty);
      expect(device.buvid, guest.buvid);
      expect(device.fpLocal, derived.fpLocal);
      expect(device.fpRemote, derived.fpRemote);
      expect(device.fp, derived.fpLocal);
      expect(device.guestId, derived.deviceId);
      expect(sendMsgRequest.devId, derived.deviceId);
      expect(syncRequest.devId, derived.deviceId);
      expect(sendMsgRequest.devId, isNot('1'));
      expect(syncRequest.devId, isNot('1'));
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
