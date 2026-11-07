import 'dart:convert' show jsonEncode;
import 'dart:io' show Cookie, Platform;

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;
import 'package:webview_all_linux/webview_all_linux.dart';

abstract final class LinuxCookieManager {
  static bool isBiliDomain(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == 'bilibili.com' || host.endsWith('.bilibili.com');
  }

  static List<Cookie> getCookies([Account? account]) {
    final targetAccount = account ?? Accounts.main;
    return targetAccount.cookieJar.toList();
  }

  static Future<void> deleteAllCookies() async {
    if (!Platform.isLinux) return;
    try {
      await LinuxWebViewCookieManager(
        const LinuxWebViewCookieManagerCreationParams(),
      ).clearCookies();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LinuxCookieManager: deleteAllCookies failed: $e');
      }
    }
  }

  /// Matches the original Linux cache action, which cleared all website data.
  static Future<void> clearAllWebsiteData() async {
    final result = await LinuxWebViewDataManager(
      const LinuxWebViewDataManagerCreationParams(),
    ).clearAllWebsiteData();
    if (!result.isComplete) {
      final errors = result.failures.values.toSet().join('; ');
      throw StateError(errors.isEmpty ? '未能清理全部网站数据' : errors);
    }
  }

  /// Native cookie injection. webview_all_linux only exposes cookie clearing
  /// (no CookieManager setter), so on Linux this stays a best-effort attempt
  /// through flutter_inappwebview and may be a silent no-op. The mechanism that
  /// actually injects cookies on Linux is [generateCookieInjectionJs], applied as
  /// a start-time user script and on cookie reset.
  static Future<void> setCookies([Account? account]) async {
    if (!Platform.isLinux) return;
    try {
      final manager = web.CookieManager.instance();
      await Future.wait(
        getCookies(account).map(
          (cookie) => manager.setCookie(
            url: web.WebUri('https://bilibili.com'),
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain ?? '.bilibili.com',
            path: cookie.path ?? '/',
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
          ),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LinuxCookieManager: setCookies failed: $e');
      }
    }
  }

  static String generateCookieInjectionJs([List<Cookie>? cookieList]) {
    final cookies = cookieList ?? getCookies();
    if (cookies.isEmpty) return '';

    final cookieMaps = cookies.map((c) {
      final rawDomain = c.domain ?? 'bilibili.com';
      final domain = rawDomain.startsWith('.') ? rawDomain : '.$rawDomain';
      return {
        'name': c.name,
        'value': c.value,
        'domain': domain,
        'path': c.path ?? '/',
        'secure': c.secure,
      };
    }).toList();

    final jsonStr = jsonEncode(cookieMaps);

    return '''
(function() {
  try {
    var cookies = $jsonStr;
    for (var i = 0; i < cookies.length; i++) {
      var c = cookies[i];
      var str = c.name + '=' + c.value + '; path=' + (c.path || '/') + '; domain=' + c.domain + '; max-age=31536000; SameSite=Lax';
      if (c.secure) str += '; Secure';
      document.cookie = str;
    }
  } catch (e) {
    console.error('[LinuxWebview] Cookie injection error:', e);
  }
})();
''';
  }
}
