// Wbi签名 用于生成 REST API 请求中的 w_rid 和 wts 字段
// https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md
// import md5 from 'md5'
// import axios from 'axios'
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';

abstract final class WbiSign {
  static Box get _localCache => GStorage.localCache;
  static final RegExp _chrFilter = RegExp(r"[!\'\(\)\*]");
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  static Future<String?>? _future;
  static DateTime? _failedAt;
  static int _failureCount = 0;

  /// 连续失败后的退避步长；首次失败立即允许重试，避免把一次网络抖动放大成
  /// 「本进程不再重取」（F08）。
  static const Duration _backoffStep = Duration(seconds: 5);
  static const Duration _maxBackoff = Duration(seconds: 60);

  static Duration get _retryBackoff {
    final int seconds = _backoffStep.inSeconds * (_failureCount - 1);
    if (seconds <= 0) {
      return Duration.zero;
    }
    return Duration(
      seconds: seconds < _maxBackoff.inSeconds
          ? seconds
          : _maxBackoff.inSeconds,
    );
  }

  // 对 imgKey 和 subKey 进行字符顺序打乱编码
  static String getMixinKey(String orig) {
    return String.fromCharCodes(_mixinKeyEncTab.map(orig.codeUnitAt));
  }

  // 为请求参数进行 wbi 签名
  static void encWbi(Map<String, Object> params, String mixinKey) {
    // 追加 web 端风控指纹参数（与官方 Web 端一致）
    appendRiskFingerprintParams(params);
    params['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 按照 key 重排参数
    final List<String> keys = params.keys.toList()..sort();
    final queryStr = keys
        .map(
          (i) =>
              '${Uri.encodeComponent(i)}=${Uri.encodeComponent(params[i].toString().replaceAll(_chrFilter, ''))}',
        )
        .join('&');
    params['w_rid'] = md5
        .convert(utf8.encode(queryStr + mixinKey))
        .toString(); // 计算 w_rid
  }

  /// 追加 Web 端风控指纹参数
  /// 对应官方 Web 端 / BiliPai WbiUtils.kt::appendRiskFingerprintParams()
  /// 这些参数会参与 w_rid 签名计算，缺失会触发 -352 / -412 风控
  static void appendRiskFingerprintParams(Map<String, Object> params) {
    // 已存在则不覆盖（允许调用方自定义）
    params['dm_img_list'] ??= '[]';
    params['dm_img_str'] ??= 'V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ';
    params['dm_cover_img_str'] ??=
        'QU5HTEUgKE5WSURJQSwgTlZJRElBIEdlRm9yY2UgR1RYIDEwNjAgNkdCIERpcmVjdDNEMTEgdnNfNV8wIHBzXzVfMCwgRDNEMTEp';
    params['dm_img_inter'] ??= '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}';
  }

  /// 当日已缓存的 mixinKey；跨日或缺失时返回 null（跨日不复用旧 key）。
  static String? _cachedKeyOfDay(DateTime nowDate) {
    final timeStamp = DateTime.fromMillisecondsSinceEpoch(
      _localCache.get(LocalCacheKey.timeStamp, defaultValue: 0) as int,
    );
    if (timeStamp.day != nowDate.day) return null;
    final key = _localCache.get(LocalCacheKey.mixinKey);
    return (key is String && key.isNotEmpty) ? key : null;
  }

  static Future<String?> _getWbiKeys() async {
    try {
      final resp = await Request().get(Api.userInfo);
      final wbiUrls = resp.data['data']['wbi_img'];

      final mixinKey = getMixinKey(
        Utils.getFileName(wbiUrls['img_url'], fileExt: false) +
            Utils.getFileName(wbiUrls['sub_url'], fileExt: false),
      );
      if (mixinKey.isEmpty) {
        throw const FormatException('empty wbi mixin key');
      }

      // 只在取到当日 key 后才落盘（时间戳同写）：失败时不推进日期，
      // 否则跨日失败会把昨日 key 当今日 key 复用。
      _localCache
        ..put(LocalCacheKey.mixinKey, mixinKey)
        ..put(
          LocalCacheKey.timeStamp,
          DateTime.now().millisecondsSinceEpoch,
        );

      _failureCount = 0;
      _failedAt = null;
      return mixinKey;
    } catch (e) {
      debugPrint('WBI sign error: $e');
      _failureCount++;
      _failedAt = DateTime.now();
      return null;
    }
  }

  /// 取当日的 mixinKey。不可用时返回 null —— 调用方必须跳过签名，
  /// 不得用空 key 生成 w_rid。失败不会被进程缓存：退避窗口一过即重取。
  static FutureOr<String?> getWbiKeys() {
    final nowDate = DateTime.now();
    final String? cached = _cachedKeyOfDay(nowDate);
    if (cached != null) return cached;

    if (_future case final future?) return future;

    final failedAt = _failedAt;
    if (failedAt != null && nowDate.difference(failedAt) < _retryBackoff) {
      return null;
    }
    return _future = _getWbiKeys().whenComplete(() => _future = null);
  }

  static Future<Map<String, Object>> makSign(
    Map<String, Object> params,
  ) async {
    // params 为需要加密的请求参数
    final String? mixinKey = await getWbiKeys();
    if (mixinKey == null || mixinKey.isEmpty) {
      // 无 key 时不生成签名：空 key 算出的 w_rid 只会被服务端判成风控请求
      debugPrint('WBI sign skipped: mixin key unavailable');
      return params;
    }
    encWbi(params, mixinKey);
    return params;
  }
}
