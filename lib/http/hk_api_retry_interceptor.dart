import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class HkApiRetryInterceptor extends Interceptor {
  /// 提示出口。默认走 `SmartDialog.showToast`；测试可注入捕获出口，从而对
  /// **真实管线**产生的文案做断言，而不是把 helper 重算一遍。
  @visibleForTesting
  static void Function(String message)? debugToastSink;

  static void _notify(String message) {
    final sink = debugToastSink;
    if (sink != null) {
      sink(message);
      return;
    }
    SmartDialog.showToast(message);
  }

  /// 港澳台重试失败的提示文案。
  ///
  /// 普通请求保持原样（便于诊断）。账号校验请求可能带 `access_key`，因此只给
  /// 中性提示、不回显 URL 与响应体 —— 港澳台重试本身照常执行，只是失败提示
  /// 不再携带凭证。
  static String hkFailureToast(RequestOptions options, Object? body) {
    if (AccountManager.isAuthProbe(options)) {
      return '港澳台解析失败（账号校验请求，已省略详情）';
    }
    return '港澳台解析失败 url:${options.uri} body: $body';
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    String apiHKUrl = Pref.apiHKUrl;
    final originalOptions = response.requestOptions;
    if ((originalOptions.method == 'GET') && (apiHKUrl.isNotEmpty)) {
      final data = response.data;
      if (data is Map && ((data['code'] == -404) || (data['code'] == -10403))) {
        try {
          String newUrl;

          if (originalOptions.path.startsWith('http')) {
            final originalUri = Uri.parse(originalOptions.path);

            if (originalUri.host != HttpString.apiBaseUrl) {
              return handler.next(response);
            }

            newUrl = apiHKUrl + originalUri.path;
            if (originalUri.query.isNotEmpty) {
              newUrl += '?${originalUri.query}';
            }
          } else {
            newUrl = apiHKUrl + originalOptions.path;
          }

          final newResponse = await _retryWithNewDomain(
            originalOptions,
            newUrl,
          );
          return handler.resolve(newResponse);
        } catch (e) {
          _notify(hkFailureToast(originalOptions, response.data));
          return handler.next(response);
        }
      }
    }

    return handler.next(response);
  }

  Future<Response> _retryWithNewDomain(
    RequestOptions originalOptions,
    String newUrl,
  ) async {
    final newOptions = Options(
      method: originalOptions.method,
      sendTimeout: originalOptions.sendTimeout,
      receiveTimeout: originalOptions.receiveTimeout,
      extra: originalOptions.extra,
      headers: originalOptions.headers,
      responseType: originalOptions.responseType,
      contentType: originalOptions.contentType,
      validateStatus: originalOptions.validateStatus,
      receiveDataWhenStatusError: originalOptions.receiveDataWhenStatusError,
      followRedirects: originalOptions.followRedirects,
      maxRedirects: originalOptions.maxRedirects,
      requestEncoder: originalOptions.requestEncoder,
      responseDecoder: originalOptions.responseDecoder,
      listFormat: originalOptions.listFormat,
    );

    return await Request.dio.request(
      newUrl,
      data: originalOptions.data,
      queryParameters: originalOptions.queryParameters,
      options: newOptions,
      cancelToken: originalOptions.cancelToken,
    );
  }
}
