import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/vip/play_device.dart';
import 'package:PiliPlus/models_new/vip/vip_center.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:dio/dio.dart';

/// 会员中心（big.bilibili.com/mobile/index / deviceManage）接口封装。
///
/// 接口解析来源：
/// - `GET /x/vip/web/vip_center/v2`：大会员中心状态
/// - `GET/POST /x/vip/play_devices/*`：会员播放设备管理
/// - `POST /x/vip/auto_renew/unfreeze`：解冻（解除冻结状态）
///
/// 全部走 web cookie 鉴权（[Request] 拦截器自动注入），POST 需带 csrf。
abstract final class VipHttp {
  /// 设备更新状态值（deviceManage JS 包 `_h` 常量）
  static const int statusUnFreeze = 1; // 允许播放
  static const int statusSetMainDevice = 2; // 设为主设备
  static const int statusPlayDisabled = 3; // 移出可播（踢出）

  /// 设备状态（deviceManage JS 包 `Ka` 常量）
  static const int deviceStatusMain = 2;
  static const int deviceStatusDisable = 3;

  /// 大会员中心状态
  static Future<LoadingState<VipCenterData>> vipCenter() async {
    final res = await Request().get(Api.vipCenter);
    if (res.data['code'] == 0) {
      return Success(
        VipCenterData.fromJson(res.data['data'] as Map<String, dynamic>),
      );
    }
    return Error(res.data['message']);
  }

  /// 播放设备列表
  static Future<LoadingState<VipDeviceData>> playDevicesList() async {
    final res = await Request().get(
      Api.playDevicesList,
      queryParameters: {..._deviceInfo(), 't': _nowMs()},
    );
    if (res.data['code'] == 0) {
      return Success(
        VipDeviceData.fromJson(res.data['data'] as Map<String, dynamic>),
      );
    }
    return Error(res.data['message']);
  }

  /// 发送短信验证码（设为主设备时）。极验验证码参数可选，失败返回原始响应。
  static Future<({bool status, int? code, String? msg, Map? data})>
  playDevicesSendSms({
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    final res = await Request().post(
      Api.playDevicesSendSms,
      data: {
        't': _nowMs(),
        'csrf': _csrf(),
        'gee_challenge': ?geeChallenge,
        'gee_seccode': ?geeSeccode,
        'gee_validate': ?geeValidate,
        'recaptcha_token': ?recaptchaToken,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return (status: true, code: 0, msg: null, data: res.data['data']);
    }
    return (
      status: false,
      code: res.data['code'],
      msg: res.data['message'],
      data: res.data['data'],
    );
  }

  /// 更新设备状态（设为主设备/允许播放/移出可播）
  static Future<LoadingState<Map?>> playDevicesUpdate({
    required int status,
    required PlayDevice target,
    String? smsCode,
  }) async {
    final res = await Request().post(
      Api.playDevicesUpdate,
      data: {
        't': _nowMs(),
        'csrf': _csrf(),
        'mid': Accounts.main.mid,
        'status': status,
        ..._deviceInfo(),
        'target_buvid': target.buvid,
        'target_mobi_app': target.mobiApp,
        'target_brand': target.brand,
        'target_device': target.device,
        'target_model': target.model,
        'target_platform': target.platform,
        'sms_code': ?smsCode,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data'] as Map?);
    }
    return Error(res.data['message']);
  }

  /// 解冻（解除冻结状态）
  static Future<LoadingState<Map?>> autoRenewUnfreeze() async {
    final res = await Request().post(
      Api.autoRenewUnfreeze,
      data: {'csrf': _csrf()},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data'] as Map?);
    }
    return Error(res.data['message']);
  }

  /// 当前设备信息（对应 deviceManage JS `global.getContainerInfo` 返回字段）
  static Map<String, dynamic> _deviceInfo() {
    final account = Accounts.main;
    final profile = account is LoginAccount && account.deviceProfile != null
        ? account.deviceProfile!
        : AppDeviceProfiles.defaultDeviceProfile;
    final isDesktop = !PlatformUtils.isMobile;
    return {
      'buvid': account.buvid,
      'device': isDesktop ? 'pc' : 'phone',
      'platform': 'android',
      'mobi_app': 'android',
      'model': profile.model,
      'modelName': profile.model,
      'brand': profile.brand,
      'deviceName': profile.deviceName,
    };
  }

  static String _csrf() {
    try {
      return Accounts.main.csrf;
    } catch (_) {
      return '';
    }
  }

  static String _nowMs() => DateTime.now().millisecondsSinceEpoch.toString();
}
