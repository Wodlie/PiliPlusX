import 'dart:async' show FutureOr;
import 'dart:io' show Platform;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/main.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_owner.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

abstract final class LoginUtils {
  static FutureOr setWebCookie([Account? account]) {
    if (Platform.isLinux) {
      return null;
    }
    final cookies = (account ?? Accounts.main).cookieJar.toList();
    final webManager = web.CookieManager.instance(
      webViewEnvironment: webViewEnvironment,
    );
    final isWindows = Platform.isWindows;
    return Future.wait(
      cookies.map(
        (cookie) => webManager.setCookie(
          url: web.WebUri(
            '${isWindows ? 'https://' : ''} ${cookie.domain}',
          ),
          name: cookie.name,
          value: cookie.value,
          path: cookie.path ?? '/',
          domain: cookie.domain,
          isSecure: cookie.secure,
          isHttpOnly: cookie.httpOnly,
        ),
      ),
    );
  }

  static Future<void> onLoginMain() async {
    final account = Accounts.main;
    final res = await UserHttp.userInfo();
    if (res case Success(:final response)) {
      setWebCookie(account);
      RequestUtils.syncHistoryStatus();
      if (response.isLogin == true) {
        final accountService = Get.find<AccountService>()
          ..face.value = response.face!;

        if (accountService.isLogin.value) {
          accountService.isLogin.refresh();
        } else {
          accountService.isLogin.value = true;
        }

        SmartDialog.showToast('main登录成功');
        if (response != Pref.userInfoCache) {
          await GStorage.userInfo.put('userInfoCache', response);
        }
      }
    } else {
      // 获取用户信息失败
      await Accounts.deleteAll({account});
      SmartDialog.showNotify(
        msg: '登录失败，请检查cookie是否正确，${res.toString()}',
        notifyType: NotifyType.warning,
      );
    }
  }

  static Future<void> onLogoutMain() {
    Get.find<AccountService>()
      ..face.value = ''
      ..isLogin.value = false;

    return Future.wait([
      if (!Platform.isLinux)
        web.CookieManager.instance(
          webViewEnvironment: webViewEnvironment,
        ).deleteAllCookies(),
      GStorage.userInfo.delete('userInfoCache'),
    ]);
  }

  static String generateBuvid() {
    return IdentityCoreGenerators.generateBuvid();
  }

  /// Guest-compatibility wrapper kept only to avoid breaking old callers.
  ///
  /// Login/request business paths must read `Account.buvid` or
  /// `Pref.guestBuvid` directly instead of routing through this legacy alias.
  @Deprecated(
    'Guest-compatibility wrapper only. Use Account.buvid or Pref.guestBuvid instead.',
  )
  static String get buvid => Pref.guestBuvid;

  // static String getUUID() {
  //   return const Uuid().v4().replaceAll('-', '');
  // }

  // static String generateBuvid() {
  //   String uuid = getUUID() + getUUID();
  //   return 'XY${uuid.substring(0, 35).toUpperCase()}';
  // }

  static String genDeviceId() {
    final owner = IdentityOwnerKey.workflow('legacy-device-id');
    final buvid = IdentityCoreGenerators.deriveBuvidFromSeed(owner.key);
    return IdentityCoreGenerators.generateDeviceLocalId(
      owner: owner,
      buvid: buvid,
    );
  }
}
