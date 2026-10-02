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

  /// 官方 `PassportCommParams.getDeviceName()`：
  /// `androidx.camera.core.impl.i.a(Build.MANUFACTURER, Build.MODEL)`，
  /// 而该辅助类的方法体就是 `return str + str2;` —— **厂商与型号裸拼、无分隔符**。
  ///
  /// 这里用**伪装档案**的 brand/model（不是真机 `Build.*`），
  /// 既对齐服务端看到的形态，又不泄露真实设备。
  String get deviceName => '$brand$model';

  /// 官方 `PassportCommParams.getDevicePlatFrom()`：
  /// `C.i.a("Android", Build.VERSION.RELEASE, Build.MANUFACTURER, Build.MODEL)`，
  /// 同样是四串裸拼（`C/i.java` 方法体 `str + str2 + str3 + str4`）。
  String get devicePlatform => 'Android$osver$brand$model';

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
    required this.appKey,
    required this.appSec,
    required this.appId,
    required this.fawkesAppKey,
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

  /// 与 [mobiApp] 配套的 AppKey / AppSec。
  ///
  /// key 必须与 `mobi_app` 同源：服务端按 appkey 记账，混用会签名通过但身份错位。
  final String appKey;
  final String appSec;

  /// neuronAppId，写进 `statistics` 的 `appId`，也是 gRPC `Device.appId`。
  final int appId;

  /// Fawkes 档位串 —— `GFoundation.getFawkesAppKey()`。
  ///
  /// 用途：gRPC `x-bili-fawkes-req-bin` 的 `appkey` 字段，以及官方 H5/离线容器
  /// 请求头里的 `fawkes_key` / `app-key`。**不是**签名用的 appkey。
  ///
  /// 国内 arm64 包 = `android64`（真机抓包 + `tflite/a.java` 的
  /// `android` / `android64` / `android_b` 三档字面量 + `gripper/update/a.java`
  /// 的「fawkesAppKey == android 且 ABI 含 64 ⇒ 追加 "64"」规则，三源印证）。
  final String fawkesAppKey;

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
        appKey: appKey,
        appSec: appSec,
        appId: appId,
        fawkesAppKey: fawkesAppKey,
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

  /// 国内版基线（`tv.danmaku.bili` 9.13.0 / versionCode 9130500，`MOBI_APP=android`）。
  ///
  /// 全部接口默认走这一档：参数、header、签名 key 都由同一个档案派生，身份自洽。
  /// appkey/appsec 与 `mobi_app=android` 配套（见 `reverse-output/domestic-profile/`）。
  static const AppRequestProfile android = AppRequestProfile(
    deviceProfile: _sharedDevice,
    mobiApp: 'android',
    platform: 'android',
    channel: 'master',
    build: 9130500,
    versionName: '9.13.0',
    statistics: Constants.statistics,
    requestDevice: 'phone',
    userAgent: Constants.userAgent,
    appKey: '1d8b6e7d45233436',
    appSec: '560c52ccd288fed045859ed18bffd973',
    appId: 1,
    fawkesAppKey: 'android64',
  );

  /// 海外版（`com.bilibili.app.in` 6.6.0 / versionCode 9130300，`MOBI_APP=android_i`）。
  ///
  /// 与 [android] 的差异只有 mobi_app / appkey+appsec / build+version / appId 四项。
  ///
  /// **当前唯一使用点**：WhatsApp 取码流程（`lib/pages/login/controller.dart` 的
  /// `_smsFlowProfile`）—— WhatsApp 是海外版能力，用海外身份更稳；SMS 走 [android]。
  ///
  /// 之所以不像其它接口那样直接切国内版：静态上国内版有同一套登录代码
  /// （`otp_channel` / `actual_channel` / 门控齐全），但"参数能发"不等于"服务端照办"——
  /// 极验之前服务端不校验 `otp_channel` 的取值，国内身份下会不会被降级没有实测证据，
  /// 而 [androidIntl] 这一套是已被端到端实测跑通（`actual_channel:"whatsapp"`）的。
  static const AppRequestProfile androidIntl = AppRequestProfile(
    deviceProfile: _sharedDevice,
    mobiApp: 'android_i',
    platform: 'android',
    channel: 'master',
    build: 9130300,
    versionName: '6.6.0',
    statistics: Constants.statisticsIntl,
    requestDevice: 'phone',
    userAgent: Constants.userAgentIntl,
    appKey: 'bb3101000e232e27',
    appSec: '36efcfed79309338ced0380abd824ac1',
    appId: 14,
    // ⚠️ 未验证：海外档的 Fawkes 档位串没有抓包证据。
    // 依据 `gripper/update/a.java` 的规则（仅当 fawkesAppKey == "android"
    // 且 ABI 含 64 才追加 "64"），海外档保持 mobi_app 原值。
    fawkesAppKey: 'android_i',
  );

  /// 按 `mobi_app` 反查档案 —— 让「签名 key」与「请求里的 mobi_app」同源。
  ///
  /// 请求显式带了别的 `mobi_app`（例如某接口固定走海外版）时，签名必须跟着换，
  /// 否则会出现「签名用 A 的 key、参数写 B 的 mobi_app」这种身份错位。
  static AppRequestProfile forMobiApp(String? mobiApp) => switch (mobiApp) {
    'android_i' => androidIntl,
    _ => android,
  };

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

  /// 把某个设备档案套到请求档案上（国家基线默认 [android]）。
  static AppRequestProfile resolve({
    String? ownerKey,
    AppDeviceProfile? deviceProfile,
    AppRequestProfile base = android,
  }) {
    final resolvedDeviceProfile =
        deviceProfile ?? defaultDeviceProfileForOwner(ownerKey ?? 'guest');
    if (identical(resolvedDeviceProfile, base.deviceProfile) ||
        resolvedDeviceProfile == base.deviceProfile) {
      return base;
    }
    return base.copyWithDeviceProfile(resolvedDeviceProfile);
  }

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
  /// `sdkInt` 由 [profile.osver] 推导，`BiliApp/<versionCode>` 与基线档案
  /// [android] 保持一致；[desktop] 为真时去掉 ` Mobile` 段（PC 版页面用），
  /// 可选 [buvid] 写入 `Buvid/` 字段。全程不暴露第三方标识。
  static String buildUserAgent(
    AppDeviceProfile profile, {
    bool desktop = false,
    String? buvid,
  }) {
    final versionCode = '${android.build}';
    final mobiApp = android.mobiApp;
    final osver = profile.osver;
    final sdkInt = _sdkIntForOsver(osver);
    final mobilePart = desktop ? '' : ' Mobile';
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
