import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_request_identity_adapters_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDown(() async {
    await GStorage.clear();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('login and app rest requests use normalized identity fields', () {
    const hdProfile = AppDeviceProfiles.androidHd;
    final account = _createLoginAccount(
      mid: 2201,
      buvid: IdentityCoreGenerators.generateBuvid(),
    );
    final identity = RequestIdentityAdapter.fromAccount(
      account: account,
      userAgent: Constants.userAgent,
    );
    final headers = LoginHttp.appHeaders(
      buvid: account.buvid,
      appKey: 'android_hd',
      userAgent: Constants.userAgent,
      account: account,
    );

    expect(
      identity.loginPayloadFields,
      containsPair('local_id', identity.deviceId),
    );
    expect(
      identity.loginPayloadFields,
      containsPair('bili_local_id', identity.deviceId),
    );
    expect(
      identity.loginPayloadFields,
      containsPair('device_id', identity.deviceId),
    );
    expect(
      IdentityCoreGenerators.validateDeviceLocalId(identity.deviceId).isValid,
      isTrue,
    );
    expect(identity.profile, same(hdProfile));
    expect(identity.deviceName, hdProfile.deviceName);
    expect(identity.deviceName, isNot('vivo'));
    expect(identity.devicePlatform, hdProfile.devicePlatform);
    expect(identity.devicePlatform, isNot('Android14vivo'));
    expect(
      VideoHttp.recommendAppIdentityHeaders(account)['user-agent'],
      hdProfile.userAgent,
    );
    expect(
      IdentityCoreGenerators.validateTraceId(headers['x-bili-trace-id']!).isValid,
      isTrue,
    );
    expect(headers['x-bili-aurora-eid'], isNotEmpty);
    expect(
      headers['x-bili-aurora-zone'],
      Constants.baseHeaders['x-bili-aurora-zone'],
    );
  });

  test('guest rest requests do not emit account-only identity fields', () {
    const hdProfile = AppDeviceProfiles.androidHd;
    final guest = AnonymousAccount();
    final identity = RequestIdentityAdapter.fromAccount(
      account: guest,
      userAgent: Constants.userAgent,
    );
    final headers = LoginHttp.appHeaders(
      buvid: guest.buvid,
      appKey: 'android_hd',
      userAgent: Constants.userAgent,
      account: guest,
    );

    expect(IdentityCoreGenerators.validateDeviceLocalId(identity.localId).isValid, isTrue);
    expect(identity.restPayloadFields, containsPair('local_id', identity.localId));
    expect(identity.restPayloadFields, containsPair('device_name', hdProfile.deviceName));
    expect(identity.restPayloadFields, containsPair('device_platform', hdProfile.devicePlatform));
    expect(headers.containsKey('x-bili-aurora-eid'), isFalse);
    expect(headers.containsKey('authorization'), isFalse);
    expect(
      IdentityCoreGenerators.validateTraceId(headers['x-bili-trace-id']!).isValid,
      isTrue,
    );
    expect(
      headers['x-bili-aurora-zone'],
      Constants.baseHeaders['x-bili-aurora-zone'],
    );
  });

  test('app identity headers expose derived fp and session values', () {
    const appProfile = AppDeviceProfiles.androidApp;
    final account = _createLoginAccount(
      mid: 2202,
      buvid: IdentityCoreGenerators.generateBuvid(),
    );
    final identity = RequestIdentityAdapter.fromAccount(
      account: account,
      userAgent: Constants.userAgentApp,
    );

    expect(
      IdentityCoreGenerators.validateFp(identity.fpLocal).isValid,
      isTrue,
    );
    expect(identity.fpRemote, identity.fpLocal);
    expect(
      IdentityCoreGenerators.validateSessionId(identity.sessionId).isValid,
      isTrue,
    );
    expect(identity.appIdentityHeaders, containsPair('fp_local', identity.fpLocal));
    expect(
      identity.appIdentityHeaders,
      containsPair('fp_remote', identity.fpRemote),
    );
    expect(
      identity.appIdentityHeaders,
      containsPair('session_id', identity.sessionId),
    );
    expect(identity.profile, same(appProfile));
    expect(
      LiveHttp.appIdentityHeaders(account)['user-agent'],
      appProfile.userAgent,
    );
    expect(
      identity.appIdentityHeaders['fp_local'],
      isNot(
        '1111111111111111111111111111111111111111111111111111111111111111',
      ),
    );
    expect(identity.appIdentityHeaders['session_id'], isNot('11111111'));
  });

  test('request identity prefers stored login device profile when present', () {
    const storedProfile = AppDeviceProfile(
      brand: 'OnePlus',
      model: 'PJZ110',
      osver: '16',
    );
    final account = _createLoginAccount(
      mid: 2203,
      buvid: IdentityCoreGenerators.generateBuvid(),
      deviceProfile: storedProfile,
    );

    final identity = RequestIdentityAdapter.fromAccount(
      account: account,
      userAgent: Constants.userAgent,
    );

    expect(identity.profile.deviceProfile.brand, storedProfile.brand);
    expect(identity.profile.deviceProfile.model, storedProfile.model);
    expect(identity.profile.deviceProfile.osver, storedProfile.osver);
    expect(identity.deviceName, storedProfile.deviceName);
    expect(identity.devicePlatform, storedProfile.devicePlatform);
    expect(identity.profile.build, AppDeviceProfiles.androidHd.build);
    expect(identity.profile.mobiApp, AppDeviceProfiles.androidHd.mobiApp);
  });

  test('video and live app params read shared device profiles', () {
    const hdProfile = AppDeviceProfiles.androidHd;
    const appProfile = AppDeviceProfiles.androidApp;

    final videoParams = VideoHttp.recommendAppQueryParameters(freshIdx: 7);
    final liveParams = LiveHttp.liveFeedIndexQueryParameters(
      account: AnonymousAccount(),
      pn: 3,
    );

    expect(videoParams['build'], hdProfile.build);
    expect(videoParams['channel'], hdProfile.channel);
    expect(videoParams['device'], hdProfile.requestDevice);
    expect(videoParams['device_name'], hdProfile.deviceName);
    expect(videoParams['mobi_app'], hdProfile.mobiApp);
    expect(videoParams['platform'], hdProfile.platform);
    expect(videoParams['statistics'], hdProfile.statistics);

    expect(liveParams['build'], appProfile.build);
    expect(liveParams['channel'], appProfile.channel);
    expect(liveParams['device'], appProfile.requestDevice);
    expect(liveParams['device_name'], appProfile.deviceName);
    expect(liveParams['mobi_app'], appProfile.mobiApp);
    expect(liveParams['platform'], appProfile.platform);
    expect(liveParams['statistics'], appProfile.statistics);
  });
}

LoginAccount _createLoginAccount({
  required int mid,
  required String buvid,
  Set<AccountType>? type,
  AppDeviceProfile? deviceProfile,
}) {
  return LoginAccount(
    _createCookieJar(mid: mid),
    'ACCESS_KEY_$mid',
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
