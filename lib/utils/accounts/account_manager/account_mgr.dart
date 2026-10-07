// edit from package:dio_cookie_manager
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/api_hosts.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/accounts/api_type.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_snapshot.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

class AccountManager extends Interceptor {
  AccountManager();

  static String blockServer = Pref.blockServer;

  /// 生命周期账号校验请求标记。
  ///
  /// 由 `AccountService` / `UserHttp` 的 probe 函数设置，普通请求不含这些键，
  /// 因此行为完全不变。
  static const authProbeExtra = 'pili.authProbe';

  /// token-only：请求该实例不带任何 cookie（普通 retry/HK 仍然生效）。
  static const tokenOnlyExtra = 'pili.tokenOnly';

  /// 发送前核对「发起校验的账号」是否仍然是当前选中的那个账号。
  static const expectedIdentityExtra = 'pili.expectedAccountIdentity';

  static bool isAuthProbe(RequestOptions options) =>
      options.extra[authProbeExtra] == true;

  static String getCookies(List<Cookie> cookies) {
    // Sort cookies by path (longer path first).
    cookies.sort((a, b) {
      if (a.path == null && b.path == null) {
        return 0;
      } else if (a.path == null) {
        return -1;
      } else if (b.path == null) {
        return 1;
      } else {
        return b.path!.length.compareTo(a.path!.length);
      }
    });
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    final resolved = _resolveAccountSelection(options, path);
    final identity = resolved.identity;
    final account = resolved.account;

    if (account is NoAccount || _skipCookie(path)) return handler.next(options);

    // 代际核对：发起校验的账号若已被替换（同 mid 重新登录换 key/设备/cookie，
    // 或角色被切到别的账号），不能拿旧身份继续发这次请求。
    final expected = options.extra[expectedIdentityExtra];
    if (expected is AccountHealthIdentity && !expected.matches(account)) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    if (!identity.isLogin && path == Api.heartBeat) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    // 自定义主机还原为官方视角：app/gRPC 身份判定与 cookie 注入不因
    // 自定义主机而失效（cookieJar 按官方域名匹配）。
    final officialUri = officializeUri(options.uri);
    final isApp = officialUri.toString().startsWith(HttpString.appBaseUrl);

    if (isApp && options.responseType == ResponseType.bytes) {
      options.headers.addAll(account.grpcHeaders);
      return handler.next(options);
    }

    // 账号级公共头（env / app-key / x-bili-aurora-zone，登录号另有 x-bili-mid 等）。
    //
    // 用 putIfAbsent 而不是 addAll：**请求级已设的键优先**。app 请求的 header 由
    // RequestIdentityAdapter 按 AppRequestProfile 派生，其中 `app-key` 必须与请求里的
    // `mobi_app`（以及签名用的 appkey）同源；若在这里被 `Constants.baseHeaders` 的全局
    // 值覆盖，就会出现「签名用 A 的 appkey、app-key 头写 B」的身份错位。
    // web 请求不设这些键，仍然是账号级值生效（行为不变）。
    for (final entry in account.headers.entries) {
      options.headers.putIfAbsent(entry.key, () => entry.value);
    }
    options.headers['referer'] ??= HttpString.baseUrl;

    // app端不需要管理cookie
    if (isApp) {
      // if (kDebugMode) debugPrint('is app: ${options.path}');
      final dataPtr = (options.method == 'POST' && options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : options.queryParameters);
      if (dataPtr.isNotEmpty) {
        if (!account.accessKey.isNullOrEmpty) {
          dataPtr['access_key'] = account.accessKey!;
        }
        // 签名 key 与请求里的 mobi_app 同源：显式走海外版的接口用海外版那一对，
        // 其余用国内基线，避免「签名用 A 的 key、mobi_app 写 B」。
        final profile = AppDeviceProfiles.forMobiApp(
          dataPtr['mobi_app']?.toString(),
        );
        AppSign.appSign(
          dataPtr..remove('sign'),
          appkey: profile.appKey,
          appsec: profile.appSec,
        );
        // if (kDebugMode) debugPrint(dataPtr.toString());
      }
      return handler.next(options);
    } else if (options.extra[tokenOnlyExtra] == true) {
      // token-only 校验：保留所选账号的公共身份头，但**不带任何 cookie**。
      // 否则「cookie 有效 + access_key 已失效」会被 cookie 洗成有效，
      // 从而错误地对根评论使用 gRPC。NoAccount / 空 cookie 头都做不到这一点
      // ——NoAccount 会先被归一成 Anonymous 并注入匿名 jar。
      options.headers.removeWhere(
        (key, _) => key.toLowerCase() == HttpHeaders.cookieHeader,
      );
      return handler.next(options);
    } else {
      account.cookieJar
          .loadForRequest(officialUri)
          .then((cookies) {
            final previousCookies =
                options.headers[HttpHeaders.cookieHeader] as String?;
            final newCookies = getCookies([
              ...?previousCookies
                  ?.split(';')
                  .where((e) => e.isNotEmpty)
                  .map(Cookie.fromSetCookieValue),
              ...cookies,
            ]);
            options.headers[HttpHeaders.cookieHeader] = newCookies.isNotEmpty
                ? newCookies
                : '';
            handler.next(options);
          })
          .catchError((Object e, StackTrace s) {
            final err = DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            );
            handler.reject(err, true);
          });
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final options = response.requestOptions;
    final path = options.path;
    if (options.extra['account'] is NoAccount ||
        isAuthProbe(options) ||
        officializeUri(
          options.uri,
        ).toString().startsWith(HttpString.appBaseUrl) ||
        _skipCookie(path)) {
      return handler.next(response);
    } else {
      final future = _saveCookies(
        response,
      ).whenComplete(() => handler.next(response));
      assert(() {
        future.catchError(
          (Object e, StackTrace s) {
            throw DioException(
              requestOptions: response.requestOptions,
              error: e,
              stackTrace: s,
            );
          },
        );
        return true;
      }());
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.requestOptions.method != 'POST' &&
        !isAuthProbe(err.requestOptions)) {
      toast(err);
    }
    // 校验请求不得把 Set-Cookie 写回 jar：校验过程本身不能改动被检查的凭证。
    if (isAuthProbe(err.requestOptions)) {
      return handler.next(err);
    }
    if (err.response != null &&
        !officializeUri(
          err.response!.requestOptions.uri,
        ).toString().startsWith(HttpString.appBaseUrl)) {
      _saveCookies(
        err.response!,
      ).whenComplete(() => handler.next(err)).catchError(
        (Object e, StackTrace s) {
          final error = DioException(
            requestOptions: err.response!.requestOptions,
            error: e,
            stackTrace: s,
          );
          handler.next(error);
        },
      );
    } else {
      handler.next(err);
    }
  }

  static void toast(DioException err) {
    // 校验请求可能带着 access_key，绝不进入 toast/debug 输出。
    if (isAuthProbe(err.requestOptions)) return;
    const skipShow = [
      'heartbeat',
      'history/report',
      'roomEntryAction',
      'seg.so',
      'online/total',
      'github',
      'hdslb.com',
      'biliimg.com',
      'site/getCoin',
    ];
    String url = err.requestOptions.uri.toString();
    if (kDebugMode) debugPrint('🌹🌹ApiInterceptor: $url\n$err');
    if (skipShow.any(url.contains) ||
        (url.contains('skipSegments') && err.requestOptions.method == 'GET')) {
      // skip
    } else {
      dioError(err).then((res) => SmartDialog.showToast(res + url)).catchError((
        e,
      ) {
        debugPrint('dioError handler error: $e');
      });
    }
  }

  Future<void> _saveCookies(Response response) async {
    // 校验过程中的 Set-Cookie 不写回：检查凭证不能顺手改动凭证。
    if (isAuthProbe(response.requestOptions)) return;
    final Account account = Accounts.canonicalize(
      response.requestOptions.extra['account'] ??
          _findAccount(response.requestOptions.path),
    );
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }
    final List<Cookie> cookies = setCookies
        .map((str) => str.split(_setCookieReg))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .map(Cookie.fromSetCookieValue)
        .toList();
    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? const [];
    final isRedirectRequest = statusCode >= 300 && statusCode < 400;
    // 按官方域名保存 cookie，避免自定义主机导致 cookie 分裂
    final originalUri = officializeUri(response.requestOptions.uri);
    final realUri = originalUri.resolveUri(response.realUri);
    await account.cookieJar.saveFromResponse(realUri, cookies);
    if (isRedirectRequest && locations.isNotEmpty) {
      final originalUri = response.realUri;
      await Future.wait(
        locations.map(
          (location) => account.cookieJar.saveFromResponse(
            // Resolves the location based on the current Uri.
            originalUri.resolve(location),
            cookies,
          ),
        ),
      );
    }
    await account.onChange();
  }

  static bool _skipCookie(String path) {
    return path.startsWith(blockServer) ||
        path.contains('hdslb.com') ||
        path.contains('biliimg.com');
  }

  ({
    OwnerScopedIdentitySnapshot identity,
    Account account,
  })
  _resolveAccountSelection(
    RequestOptions options,
    String path,
  ) {
    final bound = options.extra['account'];
    // 将选定的账号绑定回请求，使响应/错误 cookie 落回到发起该请求的账号
    if (bound is Account && bound is! NoAccount) {
      final canonical = Accounts.canonicalize(bound);
      options.extra['account'] = canonical;
      return (
        identity: OwnerScopedIdentitySnapshot.fromAccount(canonical),
        account: canonical,
      );
    }
    // 当明确指定 NoAccount 时，使用真正匿名的身份
    if (bound is NoAccount) {
      final anonymous = AnonymousAccount();
      options.extra['account'] = anonymous;
      return (
        identity: OwnerScopedIdentitySnapshot.fromAccount(anonymous),
        account: anonymous,
      );
    }
    if (_isLoginApi(path)) {
      final anonymous = AnonymousAccount();
      options.extra['account'] = anonymous;
      return (
        identity: OwnerScopedIdentitySnapshot.fromAccount(anonymous),
        account: anonymous,
      );
    }
    final type = _accountTypeFor(path);
    final account = Accounts.get(type);
    options.extra['account'] = account;
    return (
      identity: Accounts.snapshot(type),
      account: account,
    );
  }

  Account _findAccount(String path) => _isLoginApi(path)
      ? AnonymousAccount()
      : Accounts.get(_accountTypeFor(path));

  /// 将请求 URL 中的自定义 API 主机还原为官方主机，用于账号身份判定、
  /// cookie 注入与保存。自定义主机未配置/未启用/非法时原样返回。
  ///
  /// 同时还原自定义主机的路径前缀（如 https://mirror.example.com/bili/...），
  /// 使 [ApiType.loginApi]/[ApiType.apiTypeSet] 的官方路径匹配恢复生效。
  static Uri officializeUri(Uri uri) {
    for (final entry in apiHostEntries) {
      final custom =
          GStorage.setting.get(entry.settingKey, defaultValue: '') as String;
      if (custom.isEmpty || !isValidCustomHost(custom)) continue;
      final customUri = Uri.parse(custom);
      if (customUri.host != uri.host) continue;
      final official = Uri.parse(entry.defaultHost);
      var path = uri.path;
      final prefix = customUri.path.endsWith('/')
          ? customUri.path.substring(0, customUri.path.length - 1)
          : customUri.path;
      if (prefix.isNotEmpty && prefix != '/' && path.startsWith(prefix)) {
        path = path.substring(prefix.length);
        if (!path.startsWith('/')) path = '/$path';
      }
      return uri.replace(
        scheme: official.scheme,
        host: official.host,
        port: official.port,
        path: path,
      );
    }
    return uri;
  }

  /// path 官方化：全 URL 还原官方 host；相对路径原样返回。
  static String _officializePath(String path) {
    if (!path.startsWith('http')) return path;
    return officializeUri(Uri.parse(path)).toString();
  }

  /// 登录/匿名接口判定：同时支持相对路径与官方化后的全 URL。
  static bool _isLoginApi(String path) =>
      ApiType.loginApi.contains(path) ||
      ApiType.loginApi.contains(_officializePath(path));

  /// 账号类型判定：同时支持相对路径与官方化后的全 URL。
  static AccountType _accountTypeFor(String path) =>
      AccountType.values.firstWhere(
        (i) =>
            ApiType.apiTypeSet[i]?.contains(path) == true ||
            ApiType.apiTypeSet[i]?.contains(_officializePath(path)) == true,
        orElse: () => AccountType.main,
      );

  static Future<String> dioError(DioException error) async {
    switch (error.type) {
      case .badCertificate:
        return '证书有误！';
      case .badResponse:
        return '服务器异常，请稍后重试！';
      case .cancel:
        return '请求已被取消，请重新请求';
      case .connectionError:
        return '连接错误，请检查网络设置';
      case .connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case .receiveTimeout:
        return '响应超时，请稍后重试！';
      case .sendTimeout:
        return '发送请求超时，请检查网络设置';
      case .transformTimeout:
        return '转换响应数据超时！';
      case .unknown:
        String desc;
        try {
          desc = PlatformUtils.isMobile
              ? (await Connectivity().checkConnectivity()).first.desc
              : '';
        } catch (_) {
          desc = '';
        }
        return '$desc网络异常 ${error.error}';
    }
  }
}

extension _ConnectivityResultExt on ConnectivityResult {
  String get desc => const ['蓝牙', 'Wi-Fi', '局域', '流量', '无', '代理', '其他'][index];
}
