import 'dart:io';

import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/pages/login/controller.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 登录落库时的「平台 + 设备」绑定契约。
///
/// 回归背景：`setAccount` 曾经在调用方不传 profile 时回落到控制器上的
/// `_smsFlowProfile`。于是「先试 WhatsApp 发码（把该字段钉成 android_i）→ 再改用
/// 密码或扫码登录」会把国内登录的账号落库成海外版，之后该账号的签名 key、
/// 参数里的 mobi_app / build / statistics 与 gRPC metadata 全部跟着错位。
///
/// 现在 profile 是必传参数，落库一律经过 [LoginPageController.buildLoginAccount]；
/// 这里把该函数的绑定语义钉死。
///
/// 为什么不走完整 `loginByXxx → setAccount` 流程：`Accounts.set` 会进入
/// `LoginUtils.onLoginMain`，那里依赖 flutter_inappwebview 的平台实现
/// （`InAppWebViewPlatform.instance`），单测宿主没有，属既有测试宿主限制。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_login_binding_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  RequestIdentityAdapter identityFor(String scope) =>
      LoginHttp.createLoginSessionIdentity(scope: scope);

  Map<String, dynamic> tokenInfo({int mid = 9101}) => {
    'access_token': 'ACCESS_KEY_$mid',
    'refresh_token': 'REFRESH_$mid',
  };

  /// 与登录接口返回的 `cookie_info.cookies` 同构（`BiliCookieJar.fromList` 读
  /// `name` / `value` 两个键）。
  List<Map<String, dynamic>> cookies({int mid = 9101}) => [
    {'name': 'DedeUserID', 'value': '$mid'},
    {'name': 'bili_jct', 'value': 'csrf_$mid'},
  ];

  test('profile 决定落库平台，设备取登录会话身份', () {
    final identity = identityFor('binding-domestic');
    final expectDevice = identity.profile.deviceProfile;

    final domestic = LoginPageController.buildLoginAccount(
      tokenInfo(),
      cookies(),
      identity: identity,
      profile: AppDeviceProfiles.android,
    );

    expect(domestic.mid, 9101);
    expect(domestic.accessKey, 'ACCESS_KEY_9101');
    expect(domestic.buvid, identity.buvid);
    expect(domestic.boundDeviceProfile, expectDevice);
    expect(domestic.boundMobiApp, AppDeviceProfiles.android.mobiApp);
    expect(domestic.appRequestProfile.mobiApp, 'android');
    expect(domestic.appRequestProfile.appKey, AppDeviceProfiles.android.appKey);
    expect(
      domestic.appRequestProfile.deviceProfile,
      expectDevice,
      reason: '设备来自本次登录会话，不随平台档案走',
    );
  });

  test('WhatsApp 流程落库为海外版（发码与登录同源）', () {
    final identity = identityFor('binding-intl');

    final intl = LoginPageController.buildLoginAccount(
      tokenInfo(mid: 9102),
      cookies(mid: 9102),
      identity: identity,
      profile: AppDeviceProfiles.androidIntl,
    );

    expect(intl.boundMobiApp, AppDeviceProfiles.androidIntl.mobiApp);
    expect(intl.appRequestProfile.mobiApp, 'android_i');
    expect(
      intl.appRequestProfile.appKey,
      AppDeviceProfiles.androidIntl.appKey,
    );
    expect(
      intl.appRequestProfile.statistics,
      AppDeviceProfiles.androidIntl.statistics,
    );
  });

  test('平台只由入参决定：同一身份传不同档案得到不同平台', () {
    final identity = identityFor('binding-same-identity');

    LoginAccount build(AppRequestProfile profile) =>
        LoginPageController.buildLoginAccount(
          tokenInfo(mid: 9103),
          cookies(mid: 9103),
          identity: identity,
          profile: profile,
        );

    final domestic = build(AppDeviceProfiles.android);
    final intl = build(AppDeviceProfiles.androidIntl);

    // 这正是被修掉的错误来源：控制器上残留的短信状态不能决定平台。
    expect(domestic.boundMobiApp, 'android');
    expect(intl.boundMobiApp, 'android_i');
    expect(domestic.buvid, intl.buvid);
    expect(domestic.boundDeviceProfile, intl.boundDeviceProfile);
  });

  test('落库结果经 Hive 往返后平台与设备保持', () {
    final identity = identityFor('binding-roundtrip');

    final intl = LoginPageController.buildLoginAccount(
      tokenInfo(mid: 9104),
      cookies(mid: 9104),
      identity: identity,
      profile: AppDeviceProfiles.androidIntl,
    );

    // toJson/fromJson 就是 Hive adapter 的持久化路径（mobiApp 为字段 6）。
    final restored = LoginAccount.fromJson(intl.toJson()!);
    expect(restored.boundMobiApp, AppDeviceProfiles.androidIntl.mobiApp);
    expect(restored.boundDeviceProfile, intl.boundDeviceProfile);
    expect(restored.appRequestProfile.mobiApp, 'android_i');
  });
}
