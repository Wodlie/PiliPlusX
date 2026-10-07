import 'dart:convert';

/// 日志脱敏：凭证字段的值一律不进日志。
///
/// 两条防线：
/// 1. 生命周期校验请求由 `AuthProbeLogInterceptor` **整条静音**（`access_key`
///    在 URL、token 在响应体、`Set-Cookie` 在响应头，事后脱敏覆盖不全）；
/// 2. 其余输出再经这里擦一遍 —— 既支持普通 `k=v` / `k: v` 形态，也支持
///    **JSON 引号键**（`"access_key": "..."`）与嵌套结构，避免
///    `{'data': {'access_key': ...}}` 这种形态漏网。
///
/// 只做替换，不改变任何非敏感内容。
abstract final class SensitiveLog {
  /// 需要擦除的字段名（小写比较）。
  static const Set<String> keys = {
    'access_key',
    'access_token',
    'refresh_token',
    'cookie',
    'cookies',
    'sessdata',
    'bili_jct',
    'csrf',
    'buvid',
    'buvid3',
    'buvid4',
    'b_nut',
    'dedeuserid',
    'sid',
    'sign',
    'appkey',
    'ticket',
    'gaia_vtoken',
    'web_ticket',
    'token',
    'token_info',
  };

  static const String _mask = '***';

  /// 长键优先，避免 `token` 抢在 `token_info` 前面匹配。
  static String get _alternation =>
      (keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join('|');

  /// `key=value` / `key: value` / `"key": "value"` / `key%22=…` 形态。
  ///
  /// 值允许被引号包住（JSON），因此先吃掉可选的引号与冒号/等号。
  static final RegExp _kvRegExp = RegExp(
    '((?:"|\'|^|[?&;,\\s{])('
    '$_alternation'
    ')(?:"|\'|\\s)*\\s*(?:=|:)\\s*(?:"|\'|\\s)*)([^"\'&\\s;,}]+)',
    caseSensitive: false,
  );

  /// 整条 `Cookie: a=1; b=2` 头。
  static final RegExp _cookieHeaderRegExp = RegExp(
    r'((?:set-)?cookie\s*[:=]\s*)([^\r\n]+)',
    caseSensitive: false,
  );

  /// 对一行（或一整段）文本脱敏。
  static String maskLine(String source) {
    if (source.isEmpty) return source;
    var result = source.replaceAllMapped(
      _cookieHeaderRegExp,
      (match) => '${match[1]}$_mask',
    );
    result = result.replaceAllMapped(
      _kvRegExp,
      (match) => '${match[1]}$_mask',
    );
    return result;
  }

  /// 对结构化数据脱敏（递归 Map / List / JSON 字符串）。
  ///
  /// 给「将来要打印结构化对象」的场景用：嵌套的
  /// `{'data': {'token_info': {'access_token': ...}}}` 也必须被擦掉。
  static Object? maskDeep(Object? value, [int depth = 0]) {
    if (depth > 8) return value;
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString():
              keys.contains(
                entry.key.toString().toLowerCase(),
              )
              ? _mask
              : maskDeep(entry.value, depth + 1),
      };
    }
    if (value is List) {
      return [for (final item in value) maskDeep(item, depth + 1)];
    }
    if (value is String) {
      final trimmed = value.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(value);
          return jsonEncode(maskDeep(decoded, depth + 1));
        } catch (_) {
          // 不是合法 JSON：按普通文本处理。
        }
      }
      return maskLine(value);
    }
    return value;
  }
}
