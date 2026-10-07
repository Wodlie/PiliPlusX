import 'package:PiliPlus/http/sensitive_log.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 日志拦截器：与原来的 `LogInterceptor` 配置完全一致，只多两条护栏。
///
/// ### 1) 生命周期账号校验请求整条静音
///
/// Dio 5 的 `LogInterceptor` 即使 `request: false`，`requestUrl` / `responseUrl`
/// / `error` 仍然默认开启，于是
/// - `_printRequest` 打印 `uri: <access_key 在 query 里的完整 URL>`；
/// - `_printResponse` 打印 `uri: <realUri>`；
/// - `onError` 打印 `uri: ...` **以及整个 DioException**（内含 requestOptions）。
///
/// 正则事后脱敏覆盖不了嵌套结构，所以对校验请求直接不调用 `super`：
/// 一条输出都不产生。
///
/// ### 2) 其余输出仍按原开关，并额外擦一遍
///
/// 构造参数与原调用点完全相同（`request` / `requestHeader` / `responseHeader`
/// 三个 false，其余沿用 Dio 默认 —— 因此 `requestBody` / `responseBody` 仍是
/// false，不会像之前的实现那样把**所有**响应体（含登录响应里的
/// `token_info.access_token`）打进日志）。`logPrint` 走 [SensitiveLog.maskLine]，
/// 同时用 `assert` 包裹以保持 dio 默认「仅 debug 打印」的行为。
class AuthProbeLogInterceptor extends LogInterceptor {
  AuthProbeLogInterceptor()
    : super(
        request: false,
        requestHeader: false,
        responseHeader: false,
        logPrint: _maskedLogPrint,
      );

  /// 该请求是否必须静音（校验请求可能带 `access_key` / 会话 cookie）。
  static bool shouldSilence(RequestOptions options) =>
      AccountManager.isAuthProbe(options);

  /// 与 dio 默认 `_debugPrint` 等价的输出开关，只是先擦一遍凭证。
  static void _maskedLogPrint(Object? object) {
    assert(() {
      debugPrint(SensitiveLog.maskLine('$object'));
      return true;
    }());
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (shouldSilence(options)) return handler.next(options);
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (shouldSilence(response.requestOptions)) return handler.next(response);
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (shouldSilence(err.requestOptions)) return handler.next(err);
    super.onError(err, handler);
  }
}
