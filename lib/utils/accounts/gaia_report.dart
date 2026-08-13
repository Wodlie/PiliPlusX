import 'dart:convert';
import 'dart:math' show Random;

import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// gaia-gateway 风控指纹上报 payload 构造器。
///
/// 依据官方 APK 9.1.0 逆向结果实现(ExClimbCongLing 自发上报路径):
/// - body 为 `{"header":{...},"encrypt_payload":<AES-CBC密文>}`;
/// - AES key 为 16 字符随机串(字符池 a-zA-Z0-9),同时用作 key 与 IV;
/// - AES key 经 RSA/ECB/PKCS1PADDING 加密后 base64 放入 `encoded_aes_key`;
/// - 内层采集 JSON 字段名混淆为 4-hex 键(映射表见 [_collectJson]);
/// - `encoded_version` 取线上 dd.json 覆盖值 "v1",RSA 公钥为配套的 4096 位
///   `risk.gaia_rsa_public_key`(随包 dd.json 内置,服务端可能更新,失效需重新校准);
/// - dt1 为 37 项采集函数位图与 SipHash 变体的组合,第三方不执行采集,
///   按"init 上报、0 命中"路径计算(count=0, bitmap=0);
/// - dt2 无 `risk.detect_app_list` 配置时输出 "0"。
abstract final class GaiaRiskReport {
  static const String encodedVersion = 'v1';

  /// 线上使用的 RSA-4096 公钥(dd.json 覆盖值 `risk.gaia_rsa_public_key`)。
  static const String _rsaPublicKey4096 = '''
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA1SomDTbicibEZdRNTFIf
G0MZI9Vm+VLvXvoS6YGtHkMexd+O8ImALMxiMkydZ0h5XPPfiUXGiyfWawVW1Q6Q
L8E9HV8tXgI82zMc/2ZnAyAp5dACWfcsqF1lH4hh63W424c9EJ/Ryqk4ZFss+vDr
n33+FN1LOyJtg8nPqCt9DN9PFaRvJTEXT0Bt2ZQTiSznHPIpalgHUNsg1OPV3ou9
5ahf5CpRl89QeIptrbObEqsmRqC0rDwsMUhY1NnvPKGYnCqOWl006q6OBP77qHa9
HRLZS0EuCEuLUnKRQq2vbbpqKrgIQln+HjMy4oIjV7Bdv9e6SJSxwausegaCQ+pt
Izy6O41iIQSISCRf+2iywvKGxvi3Jhhc39GxvhBPl9W3QF4knJmWHHbqAb94mDNE
T0GzjbU6c3j7FJcC2JjK7PeC44+VSyiY7N+9Dc0ulw7OIoigPl+R6zyWEPCdKems
9Cd8vn/njM+o7BRaBzyqJSYSOjQQiQHJYzcMRhhue/2W1wSx2S9Ry/zNvpP/Qapw
4Z6IlDt+wL9omIwcFMndUruAaRKQEDgDRKZHspUIRkXhCiaV4MwUH1rF6EFq8BRc
IsoS5O0o8ew5mzW81q2I1Mkvx2wDRyX9+zlVBMkKAvv3xMzU5l7sUM1eP3tw3mhg
6D6utwZfuFFb7Zj1oGJq4VMCAwEAAQ==
-----END PUBLIC KEY-----
''';

  static final Random _random = Random.secure();

  static const String _aesKeyChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  // MurmurHash3 x64 128(seed=0)的常数与轮常量。
  // (逆向报告误标为 "SipHash-1-3 变体 + XXH64 混合";实际为标准
  // MurmurHash3:c1/c2/fmix 常数与 0x52dce729/0x38495ab5 轮常量均吻合,
  // 已用报告测试向量 12cd732547f19f6a 验证。)
  static const int _c1 = -8663945395140668459; // 0x87c37b91114253d5
  static const int _c2 = 5545529020109919103; // 0x4cf5ad432745937f
  static const int _c3 = -49064778989728563; // 0xff51afd7ed558ccd
  static const int _c4 = -4265267296055464877; // 0xc4ceb9fe1a85ec53
  static const int _round1 = 0x52dce729;
  static const int _round2 = 0x38495ab5;

  /// 构造 ExClimbCongLing 完整请求体。
  static Map<String, dynamic> buildBody(Account account) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final aesKey = _randomAesKey();
    final keyBytes = utf8.encode(aesKey);
    final encrypter = Encrypter(AES(Key(keyBytes), mode: AESMode.cbc));
    final encryptPayload = encrypter
        .encryptBytes(
          utf8.encode(json.encode(_collectJson(account, now))),
          iv: IV(keyBytes),
        )
        .base64;
    // RSAKeyParser().parse 返回 RSAAsymmetricKey(实际为 RSAPublicKey),
    // 与 login.dart 相同,用 dynamic 以匹配 encrypt 包 API。
    dynamic publicKey = RSAKeyParser().parse(_rsaPublicKey4096);
    final encodedAesKey = Encrypter(
      RSA(publicKey: publicKey, encoding: RSAEncoding.PKCS1),
    ).encryptBytes(keyBytes).base64;
    return {
      'header': {
        'encode_type': 2,
        'payload_type': 2,
        'encoded_aes_key': encodedAesKey,
        'ts': now,
        'encoded_version': encodedVersion,
      },
      'encrypt_payload': encryptPayload,
    };
  }

  /// 内层采集 JSON(自发上报,init=true),字段名按官方 4-hex 混淆映射表。
  static Map<String, dynamic> _collectJson(Account account, int now) {
    final profile = AppDeviceProfiles.defaultDeviceProfile;
    return {
      'ddf9': profile.model, // model
      'd1e7': profile.brand, // brand
      '1f52': profile.osver, // osver
      'e962': account.buvid, // buvid
      '6456': 'zh-CN', // languages
      '5204': '1080x2400', // screen
      '2aa4': _randomBattery(), // battery(电量,运行态随机)
      '6414': '8589934592', // memory(8GB,固定与伪装机型配套)
      '1d6f': '268435456000', // totalSpace(250GB,固定)
      'c5ea': now.toString(), // sys_ts (仅 init 上报)
      'adb8': dt1(account.buvid), // dt1
      '602b': '0', // dt2 (无 detect_app_list 配置)
      '7f86': 'spontaneous', // collect_api
    };
  }

  /// dt1:init 上报、0 命中路径 → `a(0,0)` 的无符号十进制。
  @visibleForTesting
  static String dt1(String buvid) => _toUnsignedDecimal(hashA(buvid, 0, 0));

  static String _randomAesKey() {
    return String.fromCharCodes(
      Iterable.generate(
        16,
        (_) => _aesKeyChars.codeUnitAt(_random.nextInt(_aesKeyChars.length)),
      ),
    );
  }

  /// 电量百分比(20-100,避开 0/个位数这类可疑值)。
  static String _randomBattery() => (20 + _random.nextInt(81)).toString();

  static String _toUnsignedDecimal(int v) =>
      BigInt.from(v).toUnsigned(64).toString();

  /// RiskCollect.a.a(count, group) 的哈希。
  ///
  /// 输入为全局 buvid;输出与 Java long 语义一致(64 位有符号补码)。
  @visibleForTesting
  static int hashA(String buvid, int count, int group) {
    final hash0 = murmurHash3(buvid);
    final hexs = BigInt.from(
      hash0,
    ).toUnsigned(64).toRadixString(16).padLeft(16, '0');
    final sub = hexs.substring(group, group + 3);
    var i3 = count;
    var j31 = 0;
    for (var pos = 0; pos < 3; pos++) {
      final ch = sub.codeUnitAt(pos);
      if (ch >= 0x61 && ch <= 0x66) {
        // 'a'-'f':Java Character.isLetter 对 hex 字母为 true
        i3 += 1;
        // Java 中 `1 << (64-(pos+2))` 是 int 移位(移位量 &31):
        // pos=0 → bit30, pos=1 → bit29, pos=2 → bit28,结果均为正 int。
        j31 |= 1 << ((64 - (pos + 2)) & 31);
      }
    }
    if (i3.isOdd) {
      j31 |= 1 << 63; // Long.MIN_VALUE
    }
    return j31;
  }

  /// MurmurHash3 x64 128(seed=0),返回 finalize 后的 h1。
  @visibleForTesting
  static int murmurHash3(String buvid) {
    final data = utf8.encode(buvid);
    var h1 = 0;
    var h2 = 0;
    final nblocks = data.length ~/ 16;
    for (var i = 0; i < nblocks; i++) {
      final off = i * 16;
      var k1 = _le64(data, off);
      var k2 = _le64(data, off + 8);
      k1 = _mul(k1, _c1);
      k1 = _rotl(k1, 31);
      k1 = _mul(k1, _c2);
      h1 ^= k1;
      h1 = _rotl(h1, 27);
      h1 = _add(h1, h2);
      h1 = _add(_mul(h1, 5), _round1);
      k2 = _mul(k2, _c2);
      k2 = _rotl(k2, 33);
      k2 = _mul(k2, _c1);
      h2 ^= k2;
      h2 = _rotl(h2, 31);
      h2 = _add(h2, h1);
      h2 = _add(_mul(h2, 5), _round2);
    }
    // 尾部(1..15 字节):k2 需 >= 9 字节才参与。
    final tailOff = nblocks * 16;
    final tailLen = data.length - tailOff;
    var k1 = 0;
    var k2 = 0;
    if (tailLen >= 9) k2 = _le64(data, tailOff + 8);
    if (tailLen >= 1) k1 = _le64(data, tailOff);
    if (tailLen >= 9) {
      k2 = _mul(k2, _c2);
      k2 = _rotl(k2, 33);
      k2 = _mul(k2, _c1);
      h2 ^= k2;
    }
    if (tailLen >= 1) {
      k1 = _mul(k1, _c1);
      k1 = _rotl(k1, 31);
      k1 = _mul(k1, _c2);
      h1 ^= k1;
    }
    // finalize
    h1 ^= data.length;
    h2 ^= data.length;
    h1 = _add(h1, h2);
    h2 = _add(h2, h1);
    h1 = _fmix(h1);
    h2 = _fmix(h2);
    h1 = _add(h1, h2);
    h2 = _add(h2, h1);
    return h1;
  }

  static int _fmix(int k) {
    k ^= _logicalShiftRight(k, 33);
    k = _mul(k, _c3);
    k ^= _logicalShiftRight(k, 33);
    k = _mul(k, _c4);
    k ^= _logicalShiftRight(k, 33);
    return k;
  }

  /// 逻辑右移(Java `>>>` / smali ushr;Dart `>>` 为算术右移)。
  static int _logicalShiftRight(int x, int n) =>
      (x >> n) & ((1 << (64 - n)) - 1);

  /// 64 位补码乘法(wrap-around,与 Java long 一致)。
  static int _mul(int a, int b) => a * b;

  /// 64 位补码加法(wrap-around,与 Java long 一致)。
  static int _add(int a, int b) => a + b;

  /// 小端 64 位读取,越界字节按 0 补(尾部不足 8 字节时)。
  static int _le64(List<int> bytes, int offset) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v |= (offset + i < bytes.length ? bytes[offset + i] : 0) << (8 * i);
    }
    return v;
  }

  static int _rotl(int x, int n) {
    n &= 63;
    if (n == 0) return x;
    // x >>> (64-n) 保留低 n 位;Dart `>>` 为算术右移,需显式掩码。
    return (x << n) | ((x >> (64 - n)) & ((1 << n) - 1));
  }
}
