import 'dart:convert' show ascii, utf8;

import 'package:crypto/crypto.dart' show md5, sha256;

import 'identity_contracts.dart';
import 'identity_owner.dart';
import 'identity_profile.dart';

final class IdentityCoreGenerationContext implements IdentityGenerationContext {
  const IdentityCoreGenerationContext({
    required this.owner,
    this.storedProfile,
  });

  @override
  final IdentityOwnerKey owner;

  @override
  final IdentityProfileView? storedProfile;
}

final class IdentityCoreProfileValidator
    implements IdentityProfileValidator<IdentityCoreProfile> {
  const IdentityCoreProfileValidator();

  @override
  IdentityValidationResult validate(IdentityCoreProfile profile) {
    final ownerKey = profile.owner.key.trim();
    if (ownerKey.isEmpty) {
      return const IdentityValidationResult.invalid(
        'Identity core profile requires a non-empty owner key.',
      );
    }
    return IdentityCoreGenerators.validateBuvid(profile.buvid);
  }
}

final class IdentityCoreProfileGenerator
    implements IdentityProfileGenerator<IdentityCoreProfile> {
  const IdentityCoreProfileGenerator();

  static const _validator = IdentityCoreProfileValidator();

  @override
  IdentityCoreProfile generate(IdentityGenerationContext context) {
    final storedProfile = context.storedProfile;
    if (storedProfile != null && storedProfile.owner.key == context.owner.key) {
      final profile = IdentityCoreProfile(
        owner: context.owner,
        buvid: storedProfile.buvid,
      );
      if (_validator.validate(profile).isValid) {
        return profile;
      }
    }

    return IdentityCoreProfile(
      owner: context.owner,
      buvid: IdentityCoreGenerators.generateBuvidForOwner(context.owner),
    );
  }
}

final class IdentityDerivedProfile {
  const IdentityDerivedProfile({
    required this.profile,
    required this.buvid3,
    required this.sessionId,
    required this.traceId,
    required this.fpLocal,
    required this.fpRemote,
  });

  final IdentityCoreProfile profile;
  final String buvid3;
  final String sessionId;
  final String traceId;
  final String fpLocal;
  final String fpRemote;

  /// 官方 `PassportCommParams.getBiliLocalId()` → `BiliIds.buvidLocal()`
  /// → BLKV `fp_local`（见 `reverse-output/device-fields/` §7.1）。
  String get biliLocalId => fpLocal;

  /// 官方 `PassportCommParams.getLocalId()` → `paramDelegate.getBuvid()`，
  /// 即 **BUVID 本身**（同一个类里 `getLocalId()` 直接返回 `getBuvid()`）。
  String get localId => profile.buvid;

  /// 官方 `getDeviceId()` → `BiliIds.fingerprint()`（= `fp_server` 优先，否则 `fp_local`）。
  ///
  /// 本项目**不做设备级持久化**（维护者要求保持隐私性与账号隔离），
  /// 因此这里按约定直接取 [fpLocal]。
  String get deviceId => fpLocal;
}

abstract final class IdentityCoreGenerators {
  static const _defaultBuvidPrefix = 'XY';
  static const _fpHexLength = 64;
  static const _deviceIdHexLength = 34;
  static const _sessionIdLength = 8;
  static const _traceBodyLength = 32;
  static const _traceSuffixLength = 16;
  static const _alphanumeric = '0123456789abcdefghijklmnopqrstuvwxyz';
  static const _hex = '0123456789abcdef';
  static const _buvidPrefixes = {
    'XX',
    'XU',
    'XZ',
    'XW',
    'XY',
    'XG',
    'XF',
  };

  static final RegExp buvidRegExp = RegExp(r'^X[A-Z][0-9A-F]{35}$');
  static final RegExp buvid3RegExp = RegExp(r'^[0-9A-F]{32}\d{5}infoc$');
  static final RegExp fpRegExp = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp sessionIdRegExp = RegExp(r'^[0-9a-z]{8}$');

  /// 官方 `Qa1/d.getXtraceId()` 把 16 个随机字节整体按 `%02x` 输出，
  /// 因此线上样本是**纯小写 hex**（不是 `[0-9a-z]`）。
  static final RegExp traceIdRegExp = RegExp(
    r'^[0-9a-f]{32}:[0-9a-f]{16}:0:0$',
  );

  static IdentityDerivedProfile deriveProfile({
    required IdentityOwnerKey owner,
    IdentityProfileView? storedProfile,
    DateTime? now,
  }) {
    final profile = const IdentityCoreProfileGenerator().generate(
      IdentityCoreGenerationContext(owner: owner, storedProfile: storedProfile),
    );
    final derivedNow =
        now ??
        _pseudoTimestamp(_seedBytes('runtime:${owner.key}:${profile.buvid}'));
    final fp = generateFp(owner: owner, buvid: profile.buvid, now: derivedNow);
    return IdentityDerivedProfile(
      profile: profile,
      buvid3: generateBuvid3(),
      sessionId: generateSessionId(scope: owner.key),
      // traceId 用真实秒（官方 `Xl1/a.a()` 把秒级时间戳写进末 4 字节），
      // 不再复用 fp 的伪时间戳。
      traceId: generateTraceId(now: now),
      fpLocal: fp,
      fpRemote: fp,
    );
  }

  static String generateBuvid({String prefix = _defaultBuvidPrefix}) {
    return generateBuvidForOwner(
      const IdentityOwnerKey.guest(),
      prefix: prefix,
    );
  }

  static String generateBuvidForOwner(
    IdentityOwnerKey owner, {
    String prefix = _defaultBuvidPrefix,
  }) {
    return deriveBuvidFromSeed('buvid:${owner.key}', prefix: prefix);
  }

  static String deriveBuvidFromSeed(
    String rawId, {
    String prefix = _defaultBuvidPrefix,
  }) {
    final normalizedPrefix = _normalizeBuvidPrefix(prefix);
    final normalizedId = rawId
        .replaceAll(RegExp(r'[^0-9A-Za-z]'), '')
        .toUpperCase();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(
        rawId,
        'rawId',
        'BUVID seed must contain at least one ASCII letter or digit.',
      );
    }

    final digest = md5
        .convert(ascii.encode(normalizedId))
        .toString()
        .toUpperCase();
    final extracted = '${digest[2]}${digest[12]}${digest[22]}';
    return '$normalizedPrefix$extracted$digest';
  }

  static IdentityValidationResult validateBuvid(String buvid) {
    final normalized = buvid.trim().toUpperCase();
    if (!buvidRegExp.hasMatch(normalized)) {
      return const IdentityValidationResult.invalid(
        'BUVID must be uppercase and 37 characters long.',
      );
    }

    final prefix = normalized.substring(0, 2);
    if (!_buvidPrefixes.contains(prefix)) {
      return IdentityValidationResult.invalid(
        'Unsupported BUVID prefix: $prefix.',
      );
    }

    final md5Body = normalized.substring(5);
    final expectedExtract = '${md5Body[2]}${md5Body[12]}${md5Body[22]}';
    if (normalized.substring(2, 5) != expectedExtract) {
      return const IdentityValidationResult.invalid(
        'BUVID extracted checksum characters do not match the MD5 body.',
      );
    }

    return const IdentityValidationResult.valid();
  }

  static String generateBuvid3() {
    return '${_randomUpperHex(32)}${_randomDigits(5)}infoc';
  }

  static IdentityValidationResult validateBuvid3(String buvid3) {
    return buvid3RegExp.hasMatch(buvid3)
        ? const IdentityValidationResult.valid()
        : const IdentityValidationResult.invalid(
            'buvid3 must match 32 uppercase hex chars + 5 digits + infoc.',
          );
  }

  static String generateFp({
    required IdentityOwnerKey owner,
    required String buvid,
    DateTime? now,
  }) {
    final seed = _seedBytes('fp:${owner.key}:${buvid.toUpperCase()}');
    final normalizedBuvid = _fpCompatibleBuvid(buvid);
    final model = 'PILI-${_hexBytes(seed.take(4)).toUpperCase()}';
    final radio = _hexBytes(seed.skip(4).take(8)).toUpperCase();
    final timestamp = _formatFpTimestamp(now ?? _pseudoTimestamp(seed));
    final randomTail = _hexBytes(seed.skip(12).take(8));
    final raw =
        '${md5.convert(ascii.encode('$normalizedBuvid$model$radio')).toString()}$timestamp$randomTail';
    return '$raw${_pairedHexChecksum(raw)}';
  }

  static IdentityValidationResult validateFp(String fp) {
    final normalized = fp.trim().toLowerCase();
    if (!fpRegExp.hasMatch(normalized)) {
      return const IdentityValidationResult.invalid(
        'fp must be exactly 64 lowercase hex characters.',
      );
    }

    final raw = normalized.substring(0, 62);
    final checksum = normalized.substring(62);
    if (_pairedHexChecksum(raw) != checksum) {
      return const IdentityValidationResult.invalid('fp checksum mismatch.');
    }

    return const IdentityValidationResult.valid();
  }

  /// 会话 ID：**每个 owner 在进程生命周期内恒等**。
  ///
  /// 官方 `Qa1/d.getSessionId()` ← `Sa1.a`（`by lazy`）是**每进程一次**；
  /// 本项目额外按 [scope]（= `owner.key`）分桶，以保持账号之间的隔离
  /// —— 维护者明确要求不要引入设备级共享身份。
  static final Map<String, String> _sessionIds = {};

  static String generateSessionId({String? scope}) {
    return _sessionIds.putIfAbsent(
      scope ?? '',
      () => _randomFromAlphabet(_sessionIdLength, _alphanumeric),
    );
  }

  static IdentityValidationResult validateSessionId(String sessionId) {
    return sessionIdRegExp.hasMatch(sessionId)
        ? const IdentityValidationResult.valid()
        : const IdentityValidationResult.invalid(
            'sessionId must be exactly 8 lowercase alphanumeric characters.',
          );
  }

  /// 官方 `Xl1/a.a()` / `n10/b.a()`：16 个随机字节，
  /// 把**秒级时间戳按大端写进最后 4 字节**，再整体 `%02x` 成 32 位小写 hex，
  /// 拼成 `<32 hex>:<body[16..32]>:0:0`。
  static String generateTraceId({DateTime? now}) {
    final bytes = _randomBytes(16);
    final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    bytes[12] = (seconds >> 24) & 0xff;
    bytes[13] = (seconds >> 16) & 0xff;
    bytes[14] = (seconds >> 8) & 0xff;
    bytes[15] = seconds & 0xff;
    final body = _hexBytes(bytes);
    return '$body:${body.substring(16, 32)}:0:0';
  }

  static IdentityValidationResult validateTraceId(String traceId) {
    final normalized = traceId.trim();
    if (!traceIdRegExp.hasMatch(normalized)) {
      return const IdentityValidationResult.invalid(
        'traceId must match <32 chars>:<16 chars>:0:0.',
      );
    }

    final parts = normalized.split(':');
    final body = parts.first;
    if (parts[1] != body.substring(16, 32)) {
      return const IdentityValidationResult.invalid(
        'traceId suffix segment must mirror body[16..32].',
      );
    }

    return const IdentityValidationResult.valid();
  }

  static String _normalizeBuvidPrefix(String prefix) {
    final normalized = prefix.trim().toUpperCase();
    if (!_buvidPrefixes.contains(normalized)) {
      throw ArgumentError.value(
        prefix,
        'prefix',
        'BUVID prefix must be one of ${_buvidPrefixes.join(', ')}.',
      );
    }
    return normalized;
  }

  static String _fpCompatibleBuvid(String buvid) {
    final normalized = buvid.trim().toUpperCase();
    if (normalized.length != 37) {
      return normalized;
    }
    return 'XU${normalized.substring(2)}';
  }

  static List<int> _seedBytes(String seed) =>
      sha256.convert(utf8.encode(seed)).bytes;

  static DateTime _pseudoTimestamp(List<int> seed) {
    return DateTime.utc(
      2020 + seed[0] % 10,
      1 + seed[1] % 12,
      1 + seed[2] % 28,
      seed[3] % 24,
      seed[4] % 60,
      seed[5] % 60,
    );
  }

  /// 取 [length] 个随机字节。与 [_secureishIndex] 同源（sha256 摘要），
  /// 混入自增计数器以保证同微秒内的连续调用也不重复。
  static List<int> _randomBytes(int length) {
    final out = <int>[];
    while (out.length < length) {
      out.addAll(
        _seedBytes('bytes:${_randomCounter++}:${DateTime.now().microsecondsSinceEpoch}'),
      );
    }
    return out.sublist(0, length);
  }

  static int _randomCounter = 0;


  static String _formatFpTimestamp(DateTime timestamp) {
    return '${timestamp.year.toString().padLeft(4, '0')}'
        '${timestamp.month.toString().padLeft(2, '0')}'
        '${timestamp.day.toString().padLeft(2, '0')}'
        '${timestamp.hour.toString().padLeft(2, '0')}'
        '${timestamp.minute.toString().padLeft(2, '0')}'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  static String _pairedHexChecksum(String raw) {
    final normalized = raw.toLowerCase();
    var checksum = 0;
    final evenLength = normalized.length - normalized.length % 2;
    final boundedLength = evenLength < 62 ? evenLength : 62;
    for (var index = 0; index < boundedLength; index += 2) {
      checksum +=
          int.tryParse(normalized.substring(index, index + 2), radix: 16) ?? 0;
    }
    return (checksum % 256).toRadixString(16).padLeft(2, '0');
  }

  static String _hexBytes(Iterable<int> bytes) {
    final buffer = StringBuffer();
    for (final value in bytes) {
      buffer.write(value.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _randomUpperHex(int length) {
    return _randomFromAlphabet(length, '0123456789ABCDEF');
  }

  static String _randomDigits(int length) {
    return _randomFromAlphabet(length, '0123456789');
  }

  static String _randomFromAlphabet(int length, String alphabet) {
    final codeUnits = alphabet.codeUnits;
    final buffer = StringBuffer();
    for (var index = 0; index < length; index++) {
      buffer.writeCharCode(
        codeUnits[_secureishIndex(length: codeUnits.length, salt: index)],
      );
    }
    return buffer.toString();
  }

  static int _secureishIndex({required int length, required int salt}) {
    // 计数器必须参与熵：否则同一微秒内的两次调用会得到完全相同的序列
    // （session_id 现在按 scope 缓存，两个账号若在同一微秒内首次取用就会撞值）。
    final bytes = _seedBytes(
      'random:$salt:${_randomCounter++}:${DateTime.now().microsecondsSinceEpoch}',
    );
    return bytes[salt % bytes.length] % length;
  }
}
