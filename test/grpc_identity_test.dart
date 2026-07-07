import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
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
    test(
      'login metadata and device-bin use the owner-scoped identity source',
      () async {
        final account = _createLoginAccount(
          mid: 2101,
          buvid: IdentityCoreGenerators.deriveBuvidFromSeed(
            'grpc-login-owner-2101',
          ),
          type: {AccountType.main},
          accessKey: 'ACCESS_KEY_2101',
        )..activated = true;

        await Accounts.set(AccountType.main, account);

        final grpcProfile = AppDeviceProfiles.defaultDeviceProfileForOwner(
          'account:2101',
        );
        final snapshot = Accounts.mainIdentity;
        final derived = IdentityCoreGenerators.deriveProfile(
          owner: snapshot.owner,
          storedProfile: snapshot.profile,
        );
        final restIdentity = RequestIdentityAdapter.fromAccount(
          account: account,
          userAgent: AppDeviceProfiles.androidHd.userAgent,
        );
        final headers = Accounts.main.grpcHeaders;
        final metadata = Metadata.fromBuffer(
          base64Decode(headers['x-bili-metadata-bin']!),
        );
        final fawkes = FawkesReq.fromBuffer(
          base64Decode(headers['x-bili-fawkes-req-bin']!),
        );
        final device = Device.fromBuffer(
          base64Decode(headers['x-bili-device-bin']!),
        );
        final sendMsgRequest = ImGrpc.buildSendMsgRequest(
          senderUid: account.mid,
          receiverId: 9001,
          content: 'hello',
        );
        final syncRequest = ImGrpc.buildSyncFetchSessionMsgsRequest(
          talkerId: 9001,
        );

        expect(snapshot.owner.key, 'account:2101');
        expect(restIdentity.profile.deviceProfile, grpcProfile);
        expect(restIdentity.deviceName, grpcProfile.deviceName);
        expect(restIdentity.devicePlatform, grpcProfile.devicePlatform);
        expect(headers['user-agent'], AppDeviceProfiles.androidHd.userAgent);
        expect(headers['authorization'], 'identify_v1 ACCESS_KEY_2101');
        expect(headers['buvid'], account.buvid);
        expect(
          IdentityCoreGenerators.validateTraceId(
            headers['x-bili-trace-id']!,
          ).isValid,
          isTrue,
        );
        expect(headers['x-bili-aurora-zone'], 'sh001');
        expect(headers['x-bili-aurora-eid'], IdUtils.genAuroraEid(account.mid));
        expect(metadata.buvid, account.buvid);
        expect(metadata.accessKey, 'ACCESS_KEY_2101');
        expect(
          IdentityCoreGenerators.validateSessionId(fawkes.sessionId).isValid,
          isTrue,
        );
        expect(device.buvid, account.buvid);
        expect(device.build, AppDeviceProfiles.androidHd.build);
        expect(device.mobiApp, AppDeviceProfiles.androidHd.mobiApp);
        expect(device.platform, AppDeviceProfiles.androidHd.platform);
        expect(device.channel, AppDeviceProfiles.androidHd.channel);
        expect(device.brand, grpcProfile.brand);
        expect(device.model, grpcProfile.model);
        expect(device.osver, grpcProfile.osver);
        expect(device.versionName, AppDeviceProfiles.androidHd.versionName);
        expect(device.fpLocal, derived.fpLocal);
        expect(device.fpRemote, derived.fpRemote);
        expect(device.fp, derived.fpLocal);
        expect(device.guestId, derived.deviceId);
        expect(metadata.mobiApp, AppDeviceProfiles.androidHd.mobiApp);
        expect(metadata.device, AppDeviceProfiles.androidHd.platform);
        expect(metadata.build, AppDeviceProfiles.androidHd.build);
        expect(metadata.channel, AppDeviceProfiles.androidHd.channel);
        expect(metadata.platform, AppDeviceProfiles.androidHd.platform);
        expect(sendMsgRequest.devId, derived.deviceId);
        expect(syncRequest.devId, derived.deviceId);
        expect(sendMsgRequest.devId, isNot('1'));
        expect(syncRequest.devId, isNot('1'));
        expect(device.brand.toLowerCase(), isNot('android'));
      },
    );

    test(
      'anonymous grpc and im requests use guest identity without placeholder devId',
      () async {
        await Accounts.refresh();

        final guest = Accounts.main as AnonymousAccount;
        final grpcProfile = AppDeviceProfiles.defaultDeviceProfileForOwner(
          'guest',
        );
        final snapshot = Accounts.mainIdentity;
        final derived = IdentityCoreGenerators.deriveProfile(
          owner: snapshot.owner,
          storedProfile: snapshot.profile,
        );
        final restIdentity = RequestIdentityAdapter.fromAccount(
          account: guest,
          userAgent: AppDeviceProfiles.androidHd.userAgent,
        );
        final headers = guest.grpcHeaders;
        final metadata = Metadata.fromBuffer(
          base64Decode(headers['x-bili-metadata-bin']!),
        );
        final fawkes = FawkesReq.fromBuffer(
          base64Decode(headers['x-bili-fawkes-req-bin']!),
        );
        final device = Device.fromBuffer(
          base64Decode(headers['x-bili-device-bin']!),
        );
        final sendMsgRequest = ImGrpc.buildSendMsgRequest(
          senderUid: 0,
          receiverId: 9002,
          content: 'guest',
        );
        final syncRequest = ImGrpc.buildSyncFetchSessionMsgsRequest(
          talkerId: 9002,
        );

        expect(snapshot.owner.key, 'guest');
        expect(restIdentity.profile.deviceProfile, grpcProfile);
        expect(restIdentity.deviceName, grpcProfile.deviceName);
        expect(restIdentity.devicePlatform, grpcProfile.devicePlatform);
        expect(headers['user-agent'], AppDeviceProfiles.androidHd.userAgent);
        expect(snapshot.profile.buvid, Pref.guestBuvid);
        expect(headers.containsKey('authorization'), isFalse);
        expect(headers.containsKey('x-bili-aurora-eid'), isFalse);
        expect(headers['buvid'], guest.buvid);
        expect(
          IdentityCoreGenerators.validateTraceId(
            headers['x-bili-trace-id']!,
          ).isValid,
          isTrue,
        );
        expect(headers['x-bili-aurora-zone'], 'sh001');
        expect(metadata.buvid, guest.buvid);
        expect(metadata.accessKey, isEmpty);
        expect(
          IdentityCoreGenerators.validateSessionId(fawkes.sessionId).isValid,
          isTrue,
        );
        expect(device.buvid, guest.buvid);
        expect(device.brand, grpcProfile.brand);
        expect(device.model, grpcProfile.model);
        expect(device.osver, grpcProfile.osver);
        expect(device.versionName, AppDeviceProfiles.androidHd.versionName);
        expect(device.fpLocal, derived.fpLocal);
        expect(device.fpRemote, derived.fpRemote);
        expect(device.fp, derived.fpLocal);
        expect(device.guestId, derived.deviceId);
        expect(sendMsgRequest.devId, derived.deviceId);
        expect(syncRequest.devId, derived.deviceId);
        expect(sendMsgRequest.devId, isNot('1'));
        expect(syncRequest.devId, isNot('1'));
        expect(device.brand.toLowerCase(), isNot('android'));
      },
    );

    test(
      'grpc and rest hd identity share one profile source for the same stored account',
      () async {
        final storedProfile = AppDeviceProfile(
          brand: 'Samsung',
          model: 'SM-S9280',
          osver: '16',
        );
        final account = _createLoginAccount(
          mid: 2103,
          buvid: IdentityCoreGenerators.deriveBuvidFromSeed(
            'grpc-rest-shared-2103',
          ),
          type: {AccountType.main},
          accessKey: 'ACCESS_KEY_2103',
          deviceProfile: storedProfile,
        )..activated = true;

        await Accounts.set(AccountType.main, account);

        final restIdentity = RequestIdentityAdapter.fromAccount(
          account: account,
          userAgent: AppDeviceProfiles.androidHd.userAgent,
        );
        final headers = account.grpcHeaders;
        final device = Device.fromBuffer(
          base64Decode(headers['x-bili-device-bin']!),
        );

        expect(restIdentity.profile.deviceProfile, storedProfile);
        expect(restIdentity.deviceName, storedProfile.deviceName);
        expect(restIdentity.devicePlatform, storedProfile.devicePlatform);
        expect(device.brand, storedProfile.brand);
        expect(device.model, storedProfile.model);
        expect(device.osver, storedProfile.osver);
        expect(storedProfile.hasGenericPlaceholderFields, isFalse);
      },
    );

    test(
      'grpc headers prefer stored login device profile when present',
      () async {
        final storedProfile = AppDeviceProfile(
          brand: 'HONOR',
          model: 'ELP-AN10',
          osver: '16',
        );
        final account = _createLoginAccount(
          mid: 2102,
          buvid: IdentityCoreGenerators.deriveBuvidFromSeed(
            'grpc-login-owner-2102',
          ),
          type: {AccountType.main},
          accessKey: 'ACCESS_KEY_2102',
          deviceProfile: storedProfile,
        )..activated = true;

        await Accounts.set(AccountType.main, account);

        final headers = Accounts.main.grpcHeaders;
        final device = Device.fromBuffer(
          base64Decode(headers['x-bili-device-bin']!),
        );

        expect(device.brand, storedProfile.brand);
        expect(device.model, storedProfile.model);
        expect(device.osver, storedProfile.osver);
        expect(headers['user-agent'], AppDeviceProfiles.androidHd.userAgent);
        expect(device.build, AppDeviceProfiles.androidHd.build);
        expect(device.mobiApp, AppDeviceProfiles.androidHd.mobiApp);
      },
    );
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
