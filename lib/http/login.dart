import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/login_devices/data.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_owner.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart';

abstract final class LoginHttp {
  static RequestIdentityAdapter createLoginSessionIdentity({
    String scope = 'login-session',
  }) {
    final buvid = IdentityCoreGenerators.generateBuvidForOwner(
      IdentityOwnerKey.workflow(scope),
    );
    return RequestIdentityAdapter.fromBuvid(
      buvid: buvid,
      userAgent: Constants.userAgent,
      scope: scope,
    );
  }

  /// 登录请求的公共 header。
  ///
  /// [scope] 只用于派生**本次登录会话**的临时身份（buvid 等），与 appkey 无关；
  /// `app-key` header 默认取档案自带的 appkey，[appKey] 用于显式覆盖
  /// （例如 WhatsApp 流程走 `android_i` 时，必须与请求里的 `mobi_app` 配套）。
  static Map<String, String> appHeaders({
    required String buvid,
    required String userAgent,
    String? appKey,
    String? contentType,
    String scope = 'login-http',
    Account? account,
    RequestIdentityAdapter? identity,
  }) {
    final resolvedIdentity =
        identity ??
        (account == null
            ? RequestIdentityAdapter.fromBuvid(
                buvid: buvid,
                userAgent: userAgent,
                scope: scope,
              )
            : RequestIdentityAdapter.fromAccount(
                account: account,
                userAgent: userAgent,
              ));
    return resolvedIdentity.appHeaders(
      appKey: appKey,
      userAgent: userAgent,
      contentType: contentType,
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<({String authCode, String url})>> getHDcode({
    required RequestIdentityAdapter identity,
  }) async {
    final params = {
      'local_id': identity.localId,
      'platform': 'android',
      'mobi_app': AppDeviceProfiles.android.mobiApp,
    };
    AppSign.appSign(params);
    final res = await Request().post(Api.getTVCode, queryParameters: params);

    if (res.data['code'] == 0) {
      try {
        final Map<String, dynamic> data = res.data['data'];
        return Success((authCode: data['auth_code'], url: data['url']));
      } catch (e, s) {
        return Error('$e\n\n$s');
      }
    } else {
      return Error(res.data['message']);
    }
  }

  static Future codePoll(
    String authCode, {
    required RequestIdentityAdapter identity,
  }) async {
    final params = {
      'auth_code': authCode,
      'local_id': identity.localId,
    };
    AppSign.appSign(params);
    final res = await Request().post(Api.qrcodePoll, queryParameters: params);
    return {
      'status': res.data['code'] == 0,
      'code': res.data['code'],
      'data': res.data['data'],
      'msg': res.data['message'],
    };
  }

  // static Future queryCaptcha() async {
  //   final res = await Request().get(Api.getCaptcha);
  //   if (res.data['code'] == 0) {
  //     return {
  //       'status': true,
  //       'data': CaptchaDataModel.fromJson(res.data['data']),
  //     };
  //   } else {
  //     return {'status': false, 'data': res.data['message']};
  //   }
  // }

  // 获取salt与PubKey
  static Future getWebKey() async {
    final res = await Request().get(Api.getWebKey);
    //data: {'disable_rcmd': 0, 'local_id': LoginUtils.generateBuvid()});
    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {'status': false, 'data': {}, 'msg': res.data['message']};
    }
  }

  static Future sendSmsCode({
    required Object cid,
    required String tel,
    required RequestIdentityAdapter identity,
    /// 请求身份档案。默认国内基线；走 WhatsApp 通道时传
    /// [AppDeviceProfiles.androidIntl]（`mobi_app=android_i`）——WhatsApp 发码是
    /// 海外版能力，用海外身份更稳；签名 key 会由 `account_mgr` 按 `mobi_app`
    /// 自动换成配套的 appkey/appsec。
    AppRequestProfile profile = AppDeviceProfiles.android,
    /// 验证码下发通道：`sms`（默认）或 `whatsapp`。
    ///
    /// 服务端未必照办 —— 实际通道以响应里的 `actual_channel` 为准
    /// （可能被静默降级回 `sms`）。
    String? otpChannel,
    // String? deviceTouristId,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    final guestBuvid = identity.buvid;
    int timestamp = DateTime.now().millisecondsSinceEpoch;
    final data = {
      'build': '${profile.build}',
      'buvid': guestBuvid,
      'c_locale': Constants.cLocale,
      'channel': profile.channel,
      'cid': cid,
      // if (deviceTouristId != null) 'device_tourist_id': deviceTouristId,
      'disable_rcmd': '0',
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'local_id': identity.localId,
      // https://chinggg.github.io/post/appre/
      'login_session_id': md5
          .convert(ascii.encode(guestBuvid + timestamp.toString()))
          .toString(),
      'mobi_app': profile.mobiApp,
      'otp_channel': ?otpChannel,
      'platform': profile.platform,
      'recaptcha_token': ?recaptchaToken,
      's_locale': Constants.sLocale,
      'statistics': profile.statistics,
      'tel': tel,
      'ts': (timestamp ~/ 1000).toString(),
    };
    AppSign.appSign(data);

    final res = await Request().post(
      Api.appSmsCode,
      data: data,
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          userAgent: profile.userAgent,
          appKey: profile.appKey,
          contentType: Constants.formUrlEncodedContentType,
          identity: identity,
        ),
      ),
    );

    if (res.data['code'] == 0 && res.data['data']['recaptcha_url'] == "") {
      // 走到这里才是「真的把码发出去了」。此时 data 里才会有 actual_channel；
      // 被极验拦下时（recaptcha_url 非空）该字段根本不存在，所以只能在这里读。
      return {
        'status': true,
        'data': res.data['data'],
        // 服务端实际使用的通道（`sms` / `whatsapp`），可能为 null（老服务端不下发）
        'actualChannel': res.data['data']['actual_channel'] as String?,
        'isNew': res.data['data']['is_new'] as bool?,
      };
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // static Future getGuestId(String key) async {
  //   dynamic publicKey = RSAKeyParser().parse(key);
  //   final params = {
  //     'appkey': Constants.appKey,
  //     'build': '${AppDeviceProfiles.android.build}',
  //     'buvid': buvid,
  //     'c_locale': 'zh_CN',
  //     'channel': 'master',
  //     'deviceInfo': 'xxxxxx',
  //     'disable_rcmd': '0',
  //     'dt': Uri.encodeComponent(Encrypter(RSA(publicKey: publicKey))
  //         .encrypt(generateRandomString(16))
  //         .base64),
  //     'local_id': buvid,
  //     'mobi_app': AppDeviceProfiles.android.mobiApp,
  //     'platform': 'android',
  //     's_locale': 'zh_CN',
  //     'statistics': Constants.statistics,
  //     'ts': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
  //   };
  //   String sign = AppSign.appSign(
  //     params,
  //     Constants.appKey,
  //     Constants.appSec,
  //   );
  //   final res = await Request().post(Api.getGuestId,
  //       queryParameters: {...params, 'sign': sign},
  //       options: Options(
  //         contentType: Headers.formUrlEncodedContentType,
  //         headers: headers,
  //       ));
  //   print("getGuestId: $res");
  //   if (res.data['code'] == 0) {
  //     return {'status': true, 'data': res.data['data']};
  //   } else {
  //     return {'status': false, 'msg': res.data['message']};
  //   }
  // }

  // app端密码登录
  static Future loginByPwd({
    required String username,
    required String password,
    required String key,
    required String salt,
    required RequestIdentityAdapter identity,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    final guestBuvid = identity.buvid;
    dynamic publicKey = RSAKeyParser().parse(key);
    String passwordEncrypted = Encrypter(
      RSA(publicKey: publicKey),
    ).encrypt(salt + password).base64;

    Map<String, String> data = {
      ...identity.loginPayloadFields,
      'build': '${AppDeviceProfiles.android.build}',
      'buvid': guestBuvid,
      'c_locale': Constants.cLocale,
      'channel': 'master',
      'device': 'phone',
      //'device_meta': '',
      'disable_rcmd': '0',
      'dt': Uri.encodeComponent(
        Encrypter(
          RSA(publicKey: publicKey),
        ).encrypt(Utils.generateSecureRandomString(16)).base64,
      ),
      'from_pv': 'main.homepage.avatar-nologin.all.click',
      'from_url': Uri.encodeComponent('bilibili://pegasus/promo'),
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'mobi_app': AppDeviceProfiles.android.mobiApp,
      'password': passwordEncrypted,
      'permission': 'ALL',
      'platform': 'android',
      'recaptcha_token': ?recaptchaToken,
      's_locale': Constants.sLocale,
      'statistics': Constants.statistics,
      'username': username,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.loginByPwdApi,
      data: data,
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          userAgent: Constants.userAgent,
          contentType: Constants.formUrlEncodedContentType,
          identity: identity,
        ),
        //responseType: ResponseType.plain
      ),
    );

    if (res.data['code'] == 0) {
      return {
        'status': true,
        'data': res.data['data'],
        'msg': res.data['message'],
      };
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // app端短信验证码登录
  static Future loginBySms({
    required String captchaKey,
    required String tel,
    required String code,
    required Object cid,
    required String key,
    required RequestIdentityAdapter identity,
    /// 必须与发码时用的是同一个档案 —— `captcha_key` 是那一次发码签发的一次性凭据，
    /// 中途换身份会把「发码身份」和「登录身份」拆开。
    AppRequestProfile profile = AppDeviceProfiles.android,
  }) async {
    final guestBuvid = identity.buvid;
    dynamic publicKey = RSAKeyParser().parse(key);
    Map<String, Object> data = {
      ...identity.loginPayloadFields,
      'build': '${profile.build}',
      'buvid': guestBuvid,
      'c_locale': Constants.cLocale,
      'captcha_key': captchaKey,
      'channel': profile.channel,
      'cid': cid,
      'code': code,
      'device': profile.requestDevice,
      //'device_meta': '',
      // 'device_tourist_id': '',
      'disable_rcmd': '0',
      'dt': Uri.encodeComponent(
        Encrypter(
          RSA(publicKey: publicKey),
        ).encrypt(Utils.generateSecureRandomString(16)).base64,
      ),
      'from_pv': 'main.my-information.my-login.0.click',
      'from_url': Uri.encodeComponent('bilibili://user_center/mine'),
      'mobi_app': profile.mobiApp,
      'platform': profile.platform,
      's_locale': Constants.sLocale,
      'statistics': profile.statistics,
      'tel': tel,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.logInByAppSms,
      data: data,
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          userAgent: profile.userAgent,
          appKey: profile.appKey,
          contentType: Constants.formUrlEncodedContentType,
          identity: identity,
        ),
        //responseType: ResponseType.plain
      ),
    );

    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // 密码登录时风控验证手机
  static Future safeCenterGetInfo({
    required String tmpCode,
  }) async {
    final res = await Request().get(
      Api.safeCenterGetInfo,
      queryParameters: {
        'tmp_code': tmpCode,
      },
    );
    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // 风控验证手机前的极验验证码
  static Future preCapture() async {
    final res = await Request().post(Api.preCapture);

    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // 风控验证手机：发送短信验证码
  static Future safeCenterSmsCode({
    String? smsType,
    required String tmpCode,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
    required String refererUrl,
  }) async {
    Map<String, String> data = {
      'disable_rcmd': '0',
      'sms_type': smsType ?? 'loginTelCheck',
      'tmp_code': tmpCode,
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'recaptcha_token': ?recaptchaToken,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.safeCenterSmsCode,
      data: data,
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        headers: {
          "Referer": refererUrl,
        },
      ),
    );

    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // 风控验证手机：提交短信验证码
  static Future safeCenterSmsVerify({
    String? type,
    required String code,
    required String tmpCode,
    required String requestId,
    required String source,
    required String captchaKey,
    required String refererUrl,
  }) async {
    Map<String, String> data = {
      'type': type ?? 'loginTelCheck',
      'code': code,
      'tmp_code': tmpCode,
      'request_id': requestId,
      'source': source,
      'captcha_key': captchaKey,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.safeCenterSmsVerify,
      data: data,
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        headers: {
          "Referer": refererUrl,
        },
      ),
    );

    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  // 风控验证手机：用oauthCode换回accessToken
  static Future oauth2AccessToken({
    required String code,
    required RequestIdentityAdapter identity,
  }) async {
    final guestBuvid = identity.buvid;
    final Map<String, String> data = {
      'build': '${AppDeviceProfiles.android.build}',
      'buvid': guestBuvid,
      // 'c_locale': 'zh_CN',
      // 'channel': 'master',
      'code': code,
      'disable_rcmd': '0',
      'grant_type': 'authorization_code',
      'local_id': identity.localId,
      'mobi_app': AppDeviceProfiles.android.mobiApp,
      'platform': 'android',
      // 's_locale': 'zh_CN',
      // 'statistics': Constants.statistics,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.oauth2AccessToken,
      data: data,
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          userAgent: Constants.userAgent,
          contentType: Constants.formUrlEncodedContentType,
          identity: identity,
        ),
      ),
    );

    if (res.data['code'] == 0) {
      return {'status': true, 'data': res.data['data']};
    } else {
      return {
        'status': false,
        'code': res.data['code'],
        'msg': res.data['message'],
        'data': res.data['data'],
      };
    }
  }

  static Future<LoadingState<void>> logout(LoginAccount account) async {
    final res = await Request().post(
      Api.logout,
      data: {'biliCSRF': account.csrf},
      options: Options(
        contentType: Constants.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<LoginDevicesData>> loginDevices() async {
    final account = Accounts.main;
    final buvid = account.buvid;
    final identity = RequestIdentityAdapter.fromAccount(
      account: account,
      userAgent: Constants.userAgent,
    );
    final params = {
      'local_id': identity.localId,
      'buvid': buvid,
      'device_name': identity.deviceName,
      'device_platform': identity.devicePlatform,
      'csrf': account.csrf,
      'mobi_app': AppDeviceProfiles.android.mobiApp,
      'platform': 'android',
      'access_key': account.accessKey,
      'statistics': Constants.statistics,
    };
    AppSign.appSign(params);
    final res = await Request().get(
      Api.loginDevices,
      queryParameters: params,
    );
    if (res.data['code'] == 0) {
      return Success(LoginDevicesData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }
}
