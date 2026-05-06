import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/login/model.dart';
import 'package:PiliPlus/models_new/login_devices/data.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart';

abstract final class LoginHttp {
  static Map<String, String> appHeaders({
    required String buvid,
    required String appKey,
    required String userAgent,
    String? contentType,
    Account? account,
  }) {
    final identity = account == null
        ? RequestIdentityAdapter.fromBuvid(
            buvid: buvid,
            userAgent: userAgent,
            scope: 'login-http:$appKey',
          )
        : RequestIdentityAdapter.fromAccount(
            account: account,
            userAgent: userAgent,
          );
    return identity.appHeaders(
      appKey: appKey,
      userAgent: userAgent,
      contentType: contentType,
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<({String authCode, String url})>>
  getHDcode() async {
    final identity = RequestIdentityAdapter.fromAccount(
      account: AnonymousAccount(),
      userAgent: Constants.userAgent,
    );
    final params = {
      'local_id': identity.localId,
      'platform': 'android',
      'mobi_app': 'android_hd',
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

  static Future codePoll(String authCode) async {
    final identity = RequestIdentityAdapter.fromAccount(
      account: AnonymousAccount(),
      userAgent: Constants.userAgent,
    );
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

  static Future queryCaptcha() async {
    final res = await Request().get(Api.getCaptcha);
    if (res.data['code'] == 0) {
      return {
        'status': true,
        'data': CaptchaDataModel.fromJson(res.data['data']),
      };
    } else {
      return {'status': false, 'data': res.data['message']};
    }
  }

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
    // String? deviceTouristId,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    final guestBuvid = AnonymousAccount().buvid;
    final identity = RequestIdentityAdapter.fromAccount(
      account: AnonymousAccount(),
      userAgent: Constants.userAgent,
    );
    int timestamp = DateTime.now().millisecondsSinceEpoch;
    final data = {
      'build': '2001100',
      'buvid': guestBuvid,
      'c_locale': 'zh_CN',
      'channel': 'master',
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
      'mobi_app': 'android_hd',
      'platform': 'android',
      'recaptcha_token': ?recaptchaToken,
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'tel': tel,
      'ts': (timestamp ~/ 1000).toString(),
    };
    AppSign.appSign(data);

    final res = await Request().post(
      Api.appSmsCode,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          appKey: 'android_hd',
          userAgent: Constants.userAgent,
          contentType: Headers.formUrlEncodedContentType,
          account: AnonymousAccount(),
        ),
      ),
    );

    if (res.data['code'] == 0 && res.data['data']['recaptcha_url'] == "") {
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

  // static Future getGuestId(String key) async {
  //   dynamic publicKey = RSAKeyParser().parse(key);
  //   final params = {
  //     'appkey': Constants.appKey,
  //     'build': '2001100',
  //     'buvid': buvid,
  //     'c_locale': 'zh_CN',
  //     'channel': 'master',
  //     'deviceInfo': 'xxxxxx',
  //     'disable_rcmd': '0',
  //     'dt': Uri.encodeComponent(Encrypter(RSA(publicKey: publicKey))
  //         .encrypt(generateRandomString(16))
  //         .base64),
  //     'local_id': buvid,
  //     'mobi_app': 'android_hd',
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
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    final guestBuvid = AnonymousAccount().buvid;
    final identity = RequestIdentityAdapter.fromAccount(
      account: AnonymousAccount(),
      userAgent: Constants.userAgent,
    );
    dynamic publicKey = RSAKeyParser().parse(key);
    String passwordEncrypted = Encrypter(
      RSA(publicKey: publicKey),
    ).encrypt(salt + password).base64;

    Map<String, String> data = {
      ...identity.loginPayloadFields,
      'build': '2001100',
      'buvid': guestBuvid,
      'c_locale': 'zh_CN',
      'channel': 'master',
      'device': 'phone',
      //'device_meta': '',
      'disable_rcmd': '0',
      'dt': Uri.encodeComponent(
        Encrypter(
          RSA(publicKey: publicKey),
        ).encrypt(Utils.generateRandomString(16)).base64,
      ),
      'from_pv': 'main.homepage.avatar-nologin.all.click',
      'from_url': Uri.encodeComponent('bilibili://pegasus/promo'),
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'mobi_app': 'android_hd',
      'password': passwordEncrypted,
      'permission': 'ALL',
      'platform': 'android',
      'recaptcha_token': ?recaptchaToken,
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'username': username,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.loginByPwdApi,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          appKey: 'android_hd',
          userAgent: Constants.userAgent,
          contentType: Headers.formUrlEncodedContentType,
          account: AnonymousAccount(),
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
  }) async {
    final guestBuvid = AnonymousAccount().buvid;
    final identity = RequestIdentityAdapter.fromAccount(
      account: AnonymousAccount(),
      userAgent: Constants.userAgent,
    );
    dynamic publicKey = RSAKeyParser().parse(key);
    Map<String, Object> data = {
      ...identity.loginPayloadFields,
      'build': '2001100',
      'buvid': guestBuvid,
      'c_locale': 'zh_CN',
      'captcha_key': captchaKey,
      'channel': 'master',
      'cid': cid,
      'code': code,
      'device': 'phone',
      //'device_meta': '',
      // 'device_tourist_id': '',
      'disable_rcmd': '0',
      'dt': Uri.encodeComponent(
        Encrypter(
          RSA(publicKey: publicKey),
        ).encrypt(Utils.generateRandomString(16)).base64,
      ),
      'from_pv': 'main.my-information.my-login.0.click',
      'from_url': Uri.encodeComponent('bilibili://user_center/mine'),
      'mobi_app': 'android_hd',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'tel': tel,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.logInByAppSms,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          appKey: 'android_hd',
          userAgent: Constants.userAgent,
          contentType: Headers.formUrlEncodedContentType,
          account: AnonymousAccount(),
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
        contentType: Headers.formUrlEncodedContentType,
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
        contentType: Headers.formUrlEncodedContentType,
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
  }) async {
    final guestBuvid = AnonymousAccount().buvid;
    final identity = RequestIdentityAdapter.fromAccount(
      account: AnonymousAccount(),
      userAgent: Constants.userAgent,
    );
    final Map<String, String> data = {
      'build': '2001100',
      'buvid': guestBuvid,
      // 'c_locale': 'zh_CN',
      // 'channel': 'master',
      'code': code,
      'disable_rcmd': '0',
      'grant_type': 'authorization_code',
      'local_id': identity.localId,
      'mobi_app': 'android_hd',
      'platform': 'android',
      // 's_locale': 'zh_CN',
      // 'statistics': Constants.statistics,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.oauth2AccessToken,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: appHeaders(
          buvid: guestBuvid,
          appKey: 'android_hd',
          userAgent: Constants.userAgent,
          contentType: Headers.formUrlEncodedContentType,
          account: AnonymousAccount(),
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

  static Future<Map> logout(Account account) async {
    final res = await Request().post(
      Api.logout,
      data: {'biliCSRF': account.csrf},
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
    return {'status': res.data['code'] == 0, 'msg': res.data['message']};
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
      'mobi_app': 'android_hd',
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
