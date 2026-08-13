import 'dart:convert' show utf8;

import 'package:PiliPlus/common/constants.dart';
import 'package:hive_ce/hive.dart';

final class AppDeviceProfile {
  factory AppDeviceProfile({
    required String brand,
    required String model,
    required String osver,
  }) => AppDeviceProfile._(
    brand: _normalizeBrand(brand),
    model: _normalizeModel(model),
    osver: _normalizeOsver(osver),
  );

  const AppDeviceProfile._({
    required this.brand,
    required this.model,
    required this.osver,
  });

  final String brand;
  final String model;
  final String osver;

  static const _brandAliases = <String, String>{
    'honor': 'HONOR',
    'huawei honor': 'HONOR',
    'oneplus': 'OnePlus',
    'oppo': 'OPPO',
    'redmi': 'Redmi',
    'samsung': 'Samsung',
    'xiaomi': 'Xiaomi',
  };

  Map<String, dynamic> toJson() => {
    'brand': brand,
    'model': model,
    'osver': osver,
  };

  factory AppDeviceProfile.fromJson(Map json) => AppDeviceProfile(
    brand: json['brand'] as String,
    model: json['model'] as String,
    osver: json['osver'] as String,
  );

  static String _normalizeBrand(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        value,
        'brand',
        'Device brand cannot be empty.',
      );
    }
    return _brandAliases[normalized.toLowerCase()] ?? normalized;
  }

  static String _normalizeModel(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .toUpperCase();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        value,
        'model',
        'Device model cannot be empty.',
      );
    }
    return normalized;
  }

  static String _normalizeOsver(String value) {
    final normalized = value.trim();
    if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(normalized)) {
      throw ArgumentError.value(
        value,
        'osver',
        'Device Android version must be a numeric string.',
      );
    }
    return normalized;
  }

  String get deviceName => model;

  String get devicePlatform => 'Android$osver$model';

  bool get hasGenericPlaceholderFields {
    final normalizedBrand = brand.trim().toLowerCase();
    final normalizedModel = model.trim().toLowerCase();
    return normalizedBrand == 'android' ||
        normalizedModel == 'android' ||
        normalizedModel == 'device' ||
        normalizedModel == 'phone';
  }

  @override
  int get hashCode => Object.hash(brand, model, osver);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppDeviceProfile &&
          brand == other.brand &&
          model == other.model &&
          osver == other.osver;
}

class AppDeviceProfileAdapter extends TypeAdapter<AppDeviceProfile> {
  @override
  final int typeId = 13;

  @override
  AppDeviceProfile read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AppDeviceProfile(
      brand: fields[0] as String,
      model: fields[1] as String,
      osver: fields[2] as String,
    );
  }

  @override
  void write(BinaryWriter writer, AppDeviceProfile obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.brand)
      ..writeByte(1)
      ..write(obj.model)
      ..writeByte(2)
      ..write(obj.osver);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppDeviceProfileAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

final class AppRequestProfile {
  const AppRequestProfile({
    required this.deviceProfile,
    required this.mobiApp,
    required this.platform,
    required this.channel,
    required this.build,
    required this.versionName,
    required this.statistics,
    required this.requestDevice,
    required this.userAgent,
  });

  final AppDeviceProfile deviceProfile;
  final String mobiApp;
  final String platform;
  final String channel;
  final int build;
  final String versionName;
  final String statistics;
  final String requestDevice;
  final String userAgent;

  String get brand => deviceProfile.brand;

  String get model => deviceProfile.model;

  String get osver => deviceProfile.osver;

  String get deviceName => deviceProfile.deviceName;

  String get devicePlatform => deviceProfile.devicePlatform;

  AppRequestProfile copyWithDeviceProfile(AppDeviceProfile value) =>
      AppRequestProfile(
        deviceProfile: value,
        mobiApp: mobiApp,
        platform: platform,
        channel: channel,
        build: build,
        versionName: versionName,
        statistics: statistics,
        requestDevice: requestDevice,
        userAgent: userAgent,
      );
}

abstract final class AppDeviceProfiles {
  static const List<AppDeviceProfile> _curatedPool = [
    AppDeviceProfile._(
      brand: 'Xiaomi',
      model: '23046RP50C',
      osver: '15',
    ),
    AppDeviceProfile._(
      brand: 'HONOR',
      model: 'ELP-AN10',
      osver: '16',
    ),
    AppDeviceProfile._(
      brand: 'Samsung',
      model: 'SM-S9280',
      osver: '16',
    ),
    AppDeviceProfile._(
      brand: 'OnePlus',
      model: 'PJZ110',
      osver: '16',
    ),
    AppDeviceProfile._(
      brand: 'Xiaomi',
      model: '23127PN0CC',
      osver: '14',
    ),
    AppDeviceProfile._(
      brand: 'Samsung',
      model: 'SM-A5560',
      osver: '15',
    ),
  ];

  static const AppDeviceProfile _sharedDevice = AppDeviceProfile._(
    brand: 'Xiaomi',
    model: '23046RP50C',
    osver: '15',
  );

  static const AppRequestProfile androidHd = AppRequestProfile(
    deviceProfile: _sharedDevice,
    mobiApp: 'android_hd',
    platform: 'android',
    channel: 'master',
    build: 2001100,
    versionName: '2.0.1',
    statistics: Constants.statistics,
    requestDevice: 'pad',
    userAgent: Constants.userAgent,
  );

  static const AppRequestProfile androidApp = AppRequestProfile(
    deviceProfile: _sharedDevice,
    mobiApp: 'android',
    platform: 'android',
    channel: 'master',
    build: 8430300,
    versionName: '8.43.0',
    statistics: Constants.statisticsApp,
    requestDevice: 'android',
    userAgent: Constants.userAgentApp,
  );

  static AppDeviceProfile get defaultDeviceProfile =>
      defaultDeviceProfileForOwner('guest');

  static List<AppDeviceProfile> get curatedPool =>
      List.unmodifiable(_curatedPool);

  static AppDeviceProfile defaultDeviceProfileForOwner(String ownerKey) {
    final normalizedOwnerKey = ownerKey.trim().isEmpty
        ? 'guest'
        : ownerKey.trim();
    return _curatedPool[_stableIndex('device-profile:$normalizedOwnerKey')];
  }

  static AppRequestProfile resolve({
    required String userAgent,
    String? ownerKey,
    AppDeviceProfile? deviceProfile,
  }) {
    final baseProfile = userAgent == androidApp.userAgent
        ? androidApp
        : androidHd;
    final resolvedDeviceProfile =
        deviceProfile ?? defaultDeviceProfileForOwner(ownerKey ?? 'guest');
    if (identical(resolvedDeviceProfile, baseProfile.deviceProfile) ||
        resolvedDeviceProfile == baseProfile.deviceProfile) {
      return baseProfile;
    }
    return baseProfile.copyWithDeviceProfile(resolvedDeviceProfile);
  }

  static AppRequestProfile fromUserAgent(String userAgent) =>
      resolve(userAgent: userAgent);

  /// 生成官方 App 内 WebView 风格 UA（对应真实抓包格式，非 API 的
  /// `BiliDroid/...` 格式）：标准 WebView 内核 UA + 附加 B 站字段。
  ///
  /// 结构（字段序列与官方 WebView UA 一致）：
  /// ```text
  /// Mozilla/5.0 (Linux; Android <osver>; <model> Build/<brand><model>; wv)
  /// AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/<ver>
  /// [Mobile ]Safari/537.36 os/android model/<model> build/<versionCode>
  /// osVer/<osver> sdkInt/<sdkInt> network/1 BiliApp/<versionCode>
  /// mobi_app/<mobiApp> channel/master [Buvid/<buvid>] innerVer/<versionCode>
  /// ```
  ///
  /// [profile.brand] / [profile.model] / [profile.osver] 取自账号伪装档案，
  /// `sdkInt` 由 [profile.osver] 推导，`BiliApp/<versionCode>` 与 API 版本
  /// 一致（android 8430300 / android_hd 2001100），可选 [buvid] 写入
  /// `Buvid/` 字段。全程不暴露第三方标识。
  static String buildUserAgent(
    AppDeviceProfile profile, {
    bool hd = false,
    String? buvid,
  }) {
    final versionCode = hd ? '2001100' : '8430300';
    final mobiApp = hd ? 'android_hd' : 'android';
    final osver = profile.osver;
    final sdkInt = _sdkIntForOsver(osver);
    final mobilePart = hd ? '' : ' Mobile';
    return 'Mozilla/5.0 (Linux; Android $osver; ${profile.model} '
        'Build/${profile.brand}${profile.model}; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/114.0.5735.196$mobilePart Safari/537.36 '
        'os/android model/${profile.model} build/$versionCode osVer/$osver '
        'sdkInt/$sdkInt network/1 BiliApp/$versionCode mobi_app/$mobiApp '
        'channel/master${buvid == null ? '' : ' Buvid/$buvid'} '
        'innerVer/$versionCode';
  }

  /// Android 版本号（主版本）→ SDK int 映射，用于 UA 中 `sdkInt/` 字段。
  static const Map<int, int> _sdkIntByOsver = {
    10: 29,
    11: 30,
    12: 31,
    13: 33,
    14: 34,
    15: 35,
    16: 36,
  };

  static int _sdkIntForOsver(String osver) {
    final major = int.tryParse(osver.split('.').first);
    return major == null ? 31 : (_sdkIntByOsver[major] ?? 31);
  }

  static int _stableIndex(String seed) {
    var hash = 0x811c9dc5;
    for (final value in utf8.encode(seed)) {
      hash ^= value;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash % _curatedPool.length;
  }
}
