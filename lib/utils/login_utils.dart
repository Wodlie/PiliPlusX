import 'dart:async' show FutureOr;
import 'dart:io' show Platform;

import 'package:PiliPlus/main.dart' show webViewEnvironment;
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/linux_cookie_manager.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

abstract final class LoginUtils {
  /// 由 Cookie 的 Domain 构造 `CookieManager.setCookie` 的合法 URL。
  ///
  /// WebView 的 setCookie 要求 http(s) URL：host 不能带前导点、必须带 scheme。
  /// `cookie.domain` 形如 `.bilibili.com`（也可能为空），返回
  /// `https://bilibili.com`；空 domain 回退到 `.bilibili.com`。
  static String webCookieUrlFor(String? domain) {
    final rawDomain = (domain?.isNotEmpty ?? false) ? domain! : '.bilibili.com';
    final host = rawDomain.startsWith('.') ? rawDomain.substring(1) : rawDomain;
    return 'https://$host';
  }

  static FutureOr setWebCookie([Account? account]) {
    if (Platform.isLinux) return null;
    final cookies = (account ?? Accounts.main).cookieJar.toList();
    final webManager = web.CookieManager.instance(
      webViewEnvironment: webViewEnvironment,
    );
    return Future.wait(
      cookies.map(
        (cookie) {
          // Cookie 的 Domain 形如 `.bilibili.com`（可能为空）。WebView 的
          // setCookie 要求合法 http(s) URL：host 不能带前导点、必须带 scheme，
          // 否则 Android/iOS 直接失败、Windows 返回 false，Cookie 无法注入，
          // 导致 H5 页面（如举报列表）拿不到登录态。统一构造为
          // `https://bilibili.com`，Domain 属性仍用原始值（覆盖所有子域）。
          final rawDomain = (cookie.domain?.isNotEmpty ?? false)
              ? cookie.domain!
              : '.bilibili.com';
          return webManager.setCookie(
            url: web.WebUri(webCookieUrlFor(cookie.domain)),
            name: cookie.name,
            value: cookie.value,
            path: cookie.path ?? '/',
            domain: rawDomain,
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
          );
        },
      ),
    );
  }

  /// 主账号切换/登录后的收尾。
  ///
  /// cookie 有效性不再由这里单独发 nav 请求：账号发布时 `AccountService` 已经
  /// 统一校验（cookie / access token / 游客），这里只消费那份结果，避免同一
  /// 账号被重复查询。token 失效与 cookie 失效是两件事，前者不注销账号。
  static Future<void> onLoginMain([LoginAccount? account]) async {
    final selected = account ?? Accounts.main;
    if (selected is! LoginAccount) return;
    final service = Get.find<AccountService>();
    final pending = service.pendingFor(selected);
    final health = pending != null
        ? await pending
        : service.healthFor(selected);
    // 等待期间账号可能再次被切换：过时结果不写展示状态。
    if (!health.identity.matches(Accounts.main)) return;

    if (health.cookie == CookieHealth.valid) {
      setWebCookie(selected);
      RequestUtils.syncHistoryStatus();
      final response = health.cookieInfo;
      // 头像 / 登录态 / 金币由 `AccountService` 按**凭证指纹**统一投影：
      // 这里不再重复写 `face` / `isLogin`，否则等待期间的账号切换会被
      // 这份过时结果覆盖回上一个账号的展示。
      if (response != null) {
        SmartDialog.showToast('main登录成功');
        if (response != Pref.userInfoCache) {
          await GStorage.userInfo.put('userInfoCache', response);
        }
        if (response.mid != null && response.uname != null) {
          Pref.setAccountUname(response.mid!, response.uname!);
        }
      }
    } else if (health.cookie == CookieHealth.invalid) {
      SmartDialog.showNotify(
        msg: '登录失败，请检查cookie是否正确，账号未登录',
        notifyType: .warning,
      );
    } else {
      // 校验未完成/网络异常：不注销账号，也不谎报成功。
      SmartDialog.showToast('账号信息校验失败，请稍后重试');
    }
  }

  static Future<void> onLogoutMain() {
    Get.find<AccountService>()
      ..face.value = ''
      ..isLogin.value = false;

    return Future.wait([
      if (Platform.isLinux)
        LinuxCookieManager.deleteAllCookies()
      else
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
}
