// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'dart:convert' show ascii, base64, base64Url;

import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';

extension on List {
  void swap(int i, int j) {
    final temp = this[i];
    this[i] = this[j];
    this[j] = temp;
  }
}

abstract final class IdUtils {
  static const XOR_CODE = 23442827791579;
  static const MASK_CODE = 2251799813685247;
  static const MAX_AID = 1 << 51;
  static const BASE = 58;

  static const data =
      'FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf';
  static final invData = {for (final (i, c) in data.codeUnits.indexed) c: i};

  static final bvRegex = RegExp(r'bv1[0-9a-zA-Z]{9}', caseSensitive: false);
  static final bvRegexExact = RegExp(
    r'^bv1[0-9a-zA-Z]{9}$',
    caseSensitive: false,
  );
  static final avRegex = RegExp(r'av(\d+)', caseSensitive: false);
  static final avRegexExact = RegExp(r'^av(\d+)$', caseSensitive: false);
  static final digitOnlyRegExp = RegExp(r'^\d+$');

  /// av转bv
  static String av2bv(int aid) {
    final bytes = ['B', 'V', '1', '0', '0', '0', '0', '0', '0', '0', '0', '0'];
    int bvIndex = bytes.length - 1;
    int tmp = (MAX_AID | aid) ^ XOR_CODE;
    while (tmp > 0) {
      bytes[bvIndex--] = data[tmp % BASE];
      tmp ~/= BASE;
    }

    bytes
      ..swap(3, 9)
      ..swap(4, 7);

    return bytes.join();
  }

  /// bv转av
  static int bv2av(String bvid) {
    final bvidArr = bvid.codeUnits.sublist(3)
      ..swap(0, 6)
      ..swap(1, 4);

    final tmp = bvidArr.fold(0, (pre, char) => pre * BASE + invData[char]!);
    return (tmp & MASK_CODE) ^ XOR_CODE;
  }

  // 匹配
  static AvBvRes matchAvorBv({String? input}) {
    if (input == null || input.isEmpty) {
      return const (av: null, bv: null);
    }
    String? bvid = bvRegex.firstMatch(input)?.group(0);

    late String? aid = avRegex.firstMatch(input)?.group(1);

    if (bvid != null) {
      return (av: null, bv: bvid);
    } else if (aid != null) {
      return (av: int.parse(aid), bv: null);
    }
    return const (av: null, bv: null);
  }

  static String genBuvid3() {
    return IdentityCoreGenerators.generateBuvid3();
  }

  /// `x-bili-aurora-eid`：mid 的十进制串逐字节 XOR 密钥后 Base64。
  ///
  /// 保留 Base64 padding —— 官方两处实现**都带 `=`**：
  /// - REST：`p087dm1/a.java:43` → `Wl1.a.a()` → `android.util.Base64.encodeToString(bytes, 10)`
  ///   = `URL_SAFE | NO_WRAP`（**URL-safe 字母表**，带 padding）；
  /// - gRPC：`kntr/base/net/comm/m.java:45` → Kotlin `Base64.Default`
  ///   （**标准字母表**，带 padding）。
  ///
  /// 因此 [urlSafe] 区分两条路径（默认 false = gRPC 的标准字母表）。
  /// 真机抓包 `UlEFQFcBAFgFWk9YWFcDQg==` 亦带 `==`。
  static String genAuroraEid(int uid, {bool urlSafe = false}) {
    if (uid == 0) {
      return '';
    }

    final midByte = ascii.encode(uid.toString());

    const key = 'ad1va46a7lza';
    for (int i = 0; i < midByte.length; i++) {
      midByte[i] ^= key.codeUnitAt(i % key.length);
    }

    return urlSafe ? base64Url.encode(midByte) : base64.encode(midByte);
  }

  // https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/grpc_api/readme.md#x-bili-trace-id-生成算法
  static String genTraceId() {
    return IdentityCoreGenerators.generateTraceId();
  }
}

typedef AvBvRes = ({int? av, String? bv});

extension AvBvExt on AvBvRes {
  bool get isNotEmpty => this != const (av: null, bv: null);
}
