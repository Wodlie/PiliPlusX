import 'dart:convert' show utf8;

import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:crypto/crypto.dart';

abstract final class AppSign {
  /// APP 签名：`md5(按键升序拼接的 query + appsec)`。
  ///
  /// 签名 key 必须与请求里的 `mobi_app` **同源**：未显式传 [appkey] 时按
  /// `params['mobi_app']` 反查档案（账号可能绑定 `android_i`），否则回落国内基线。
  /// 显式传 [appkey] 时仍以国内基线取 [appsec]（与原行为一致）。
  static void appSign(
    Map<String, dynamic> params, {
    String? appkey,
    String? appsec,
  }) {
    final profile = appkey == null
        ? AppDeviceProfiles.forMobiApp(params['mobi_app']?.toString())
        : AppDeviceProfiles.android;
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
