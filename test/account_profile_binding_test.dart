import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

/// 账号级「设备 + 平台」绑定。
///
/// 登录时用的设备与平台会落到 [LoginAccount.deviceProfile] / [LoginAccount.mobiApp]，
/// 之后该账号的参数、UA、身份头、gRPC metadata 全部取自
/// [Account.appRequestProfile] —— 这里把这些契约钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_account_profile_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  final boundDevice = AppDeviceProfile(
    brand: 'OnePlus',
    model: 'PJZ110',
    osver: '16',
  );

  LoginAccount domesticAccount({AppDeviceProfile? device}) => LoginAccount(
    _createCookieJar(mid: 8001),
    'ACCESS_KEY_8001',
    'REFRESH_8001',
    null,
    null,
    device ?? boundDevice,
    AppDeviceProfiles.android.mobiApp,
  );

  LoginAccount intlAccount() => LoginAccount(
    _createCookieJar(mid: 8002),
    'ACCESS_KEY_8002',
    'REFRESH_8002',
    null,
    null,
    boundDevice,
    AppDeviceProfiles.androidIntl.mobiApp,
  );

  group('绑定契约', () {
    test('登录时绑定的平台与设备决定 appRequestProfile', () {
      final account = intlAccount();
      final profile = account.appRequestProfile;

      expect(account.boundMobiApp, 'android_i');
      expect(account.boundDeviceProfile, boundDevice);
      // 平台来自绑定档位，设备来自绑定设备（伪装档案，非真机）。
      expect(profile.mobiApp, 'android_i');
      expect(profile.appId, AppDeviceProfiles.androidIntl.appId);
      expect(profile.appKey, AppDeviceProfiles.androidIntl.appKey);
      expect(profile.build, AppDeviceProfiles.androidIntl.build);
      expect(profile.statistics, AppDeviceProfiles.androidIntl.statistics);
      expect(profile.brand, 'OnePlus');
      expect(profile.model, 'PJZ110');
      // 两个平台共用同一台绑定设备。
      expect(profile.deviceProfile, boundDevice);
    });

    test('国内账号走国内基线；访客回落到 guest 设备池', () {
      final domestic = domesticAccount();
      expect(domestic.appRequestProfile.mobiApp, 'android');
      expect(domestic.appRequestProfile.appKey, AppDeviceProfiles.android.appKey);
      expect(domestic.appRequestProfile.appId, 1);

      final guest = AnonymousAccount();
      expect(guest.boundMobiApp, AppDeviceProfiles.android.mobiApp);
      expect(guest.boundDeviceProfile, isNull);
      // 访客仍按 ownerKey 从设备池稳定取一台，不会因为「账号级」而拿到空档案。
      expect(
        guest.appRequestProfile.deviceProfile,
        AppDeviceProfiles.defaultDeviceProfileForOwner('guest'),
      );
    });

    test('mobiApp 经 Hive 字段与 toJson 往返保持', () {
      final restored = LoginAccount.fromJson(intlAccount().toJson()!);
      expect(restored.mobiApp, 'android_i');
      expect(restored.boundDeviceProfile, boundDevice);
      expect(restored.appRequestProfile.mobiApp, 'android_i');

      // 老记录没有 mobiApp → 回落国内基线（不抛异常）。
      final legacy = LoginAccount.fromJson({
        'cookies': {'DedeUserID': '8003', 'bili_jct': 'csrf'},
        'accessKey': null,
        'refresh': null,
        'type': <int>[],
        'buvid': null,
      });
      expect(legacy.mobiApp, AppDeviceProfiles.android.mobiApp);
      expect(legacy.appRequestProfile.mobiApp, 'android');
    });
  });

  group('下游一致性', () {
    test('REST 身份头与参数同源于绑定档位', () {
      final account = intlAccount();
      final identity = RequestIdentityAdapter.fromAccount(
        account: account,
        userAgent: account.appRequestProfile.userAgent,
      );

      expect(identity.profile.mobiApp, 'android_i');
      expect(identity.deviceName, 'OnePlusPJZ110');
      expect(identity.devicePlatform, 'Android16OnePlusPJZ110');
      // app-key 头必须与请求里的 mobi_app 配套。
      expect(
        identity.appHeaders(userAgent: 'UA').values,
        contains(AppDeviceProfiles.androidIntl.appKey),
      );
    });

    test('gRPC metadata 的设备/平台/Fawkes 全部取绑定档位', () {
      final account = intlAccount();
      final headers = account.grpcHeaders;

      final device = Device.fromBuffer(
        base64Decode(base64.normalize(headers['x-bili-device-bin']!)),
      );
      expect(device.mobiApp, 'android_i');
      expect(device.appId, AppDeviceProfiles.androidIntl.appId);
      expect(device.build, AppDeviceProfiles.androidIntl.build);
      expect(device.brand, 'OnePlus');
      expect(device.model, 'PJZ110');
      expect(device.versionName, AppDeviceProfiles.androidIntl.versionName);

      final metadata = Metadata.fromBuffer(
        base64Decode(base64.normalize(headers['x-bili-metadata-bin']!)),
      );
      expect(metadata.mobiApp, 'android_i');
      expect(metadata.build, AppDeviceProfiles.androidIntl.build);

      final fawkes = FawkesReq.fromBuffer(
        base64Decode(base64.normalize(headers['x-bili-fawkes-req-bin']!)),
      );
      // 海外档的 Fawkes 档位串（未验证值，但必须与平台配套而非恒为 android64）。
      expect(fawkes.appkey, AppDeviceProfiles.androidIntl.fawkesAppKey);
      expect(fawkes.appkey, isNot(AppDeviceProfiles.android.fawkesAppKey));
    });
  });
}

DefaultCookieJar _createCookieJar({required int mid}) {
  final cookieJar = DefaultCookieJar(ignoreExpires: true);
  final cookies = <Cookie>[
    Cookie('DedeUserID', '$mid')..setBiliDomain(),
    Cookie('bili_jct', 'csrf_$mid')..setBiliDomain(),
  ];
  cookieJar.domainCookies['bilibili.com'] = {
    '/': {
      for (final cookie in cookies) cookie.name: SerializableCookie(cookie),
    },
  };
  return cookieJar;
}
