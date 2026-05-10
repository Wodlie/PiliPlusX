import 'package:PiliPlus/common/constants.dart';

final class AppDeviceProfile {
  const AppDeviceProfile({
    required this.brand,
    required this.model,
    required this.osver,
  });

  final String brand;
  final String model;
  final String osver;

  String get deviceName => model;

  String get devicePlatform => 'Android$osver$model';
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
}

abstract final class AppDeviceProfiles {
  static const AppDeviceProfile _sharedDevice = AppDeviceProfile(
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

  static AppRequestProfile resolve({required String userAgent}) {
    if (userAgent == androidApp.userAgent) {
      return androidApp;
    }
    return androidHd;
  }

  static AppRequestProfile fromUserAgent(String userAgent) =>
      resolve(userAgent: userAgent);
}
