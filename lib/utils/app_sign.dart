import 'dart:convert' show utf8;

import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:crypto/crypto.dart';

abstract final class AppSign {
  /// APP 签名：`md5(按键升序拼接的 query + appsec)`。
  ///
  /// [appkey] / [appsec] 缺省取国家基线档案 [AppDeviceProfiles.android]；
  /// 走海外版档案的请求必须显式传 `AppDeviceProfiles.androidIntl` 那一对，
  /// 否则会出现「签名用国内 key、参数写 android_i」的身份错位。
  static void appSign(
    Map<String, dynamic> params, {
    String? appkey,
    String? appsec,
  }) {
    const profile = AppDeviceProfiles.android;
    params['appkey'] = appkey ?? profile.appKey;
    params['ts'] = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final sorted = params.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    params['sign'] = md5
        .convert(
          utf8.encode(
            _makeQueryFromParametersDefault(sorted) + (appsec ?? profile.appSec),
          ),
        )
        .toString(); // 获取MD5哈希值
  }

  /// from [Uri]
  static String _makeQueryFromParametersDefault(
    List<MapEntry<String, dynamic /*String?|Iterable<String>*/>>
    queryParameters,
  ) {
    final result = StringBuffer();
    var separator = '';

    void writeParameter(String key, String? value) {
      assert(value != null, 'remove null value');
      result.write(separator);
      separator = '&';
      result.write(Uri.encodeComponent(key));
      if (value != null && value.isNotEmpty) {
        result
          ..write('=')
          ..write(Uri.encodeComponent(value));
      }
    }

    for (final i in queryParameters) {
      if (i.value case final Iterable<String> values) {
        for (final String value in values) {
          writeParameter(i.key, value);
        }
      } else {
        writeParameter(i.key, i.value?.toString());
      }
    }
    return result.toString();
  }
}
