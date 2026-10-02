import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';

abstract final class Constants {
  static const appName = 'PiliPlusX';
  static const sourceCodeUrl = 'https://github.com/Wodlie/PiliPlusX';
  static const upstreamCodeUrl = 'https://github.com/cnctem/PiliPlusX';

  // AppKey / AppSec 不再放这里：它们与 mobi_app 配套，统一收在
  // `lib/utils/accounts/app_device_profile.dart` 的 AppRequestProfile 上
  // （国内基线 `AppDeviceProfiles.android` / 海外版 `androidIntl`），
  // 避免出现「签名用 A 的 key、参数写 B 的 mobi_app」这种身份错位。

  static String get traceId => IdentityCoreGenerators.generateTraceId();

  /// API UA：国内版 `tv.danmaku.bili` 9.13.0 / versionCode 9130500 / `mobi_app=android`。
  static const String userAgent =
      'Mozilla/5.0 BiliDroid/9.13.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/9130500 channel/master innerVer/9130500 osVer/15 network/2';
  static const String statistics =
      '{"appId":1,"platform":3,"version":"9.13.0","abtest":""}';

  /// 海外版 `com.bilibili.app.in` 6.6.0 / versionCode 9130300 / `mobi_app=android_i`。
  /// 仅 `AppDeviceProfiles.androidIntl` 引用。
  static const String userAgentIntl =
      'Mozilla/5.0 BiliDroid/6.6.0 (bbcallen@gmail.com) os/android model/android_i mobi_app/android_i build/9130300 channel/master innerVer/9130300 osVer/15 network/2';
  static const String statisticsIntl =
      '{"appId":14,"platform":3,"version":"6.6.0","abtest":""}';

  // 请求时会自动encodeComponent

  static const baseHeaders = {
    // 'referer': HttpString.baseUrl,
    'env': 'prod',
    'app-key': 'android64',
    'x-bili-aurora-zone': 'sh001',
  };

  /// 公共参数 `c_locale` / `s_locale`。
  ///
  /// 官方格式（`p780n10/a.java`）是 `<lang>-<Script>_<COUNTRY>`（无 script 时为
  /// `<lang>_<COUNTRY>`），国内机实测为 `zh-Hans_CN`。
  /// 这里**保持常量**、不读系统 locale —— 避免随设备变动（维护者要求）。
  static const cLocale = 'zh-Hans_CN';
  static const sLocale = 'zh-Hans_CN';

  /// 表单请求的 Content-Type（**带 charset**）。
  ///
  /// 官方 okretro 栈（`DefaultRequestInterceptor.java:157`）用
  /// `application/x-www-form-urlencoded; charset=utf-8`，而 moss/rest 栈
  /// （`Fn1/a.java:43`）不带。登录/通行证走的是前者 —— 该栈的账号子类
  /// `p263bq0/a.java` 正是加 `access_key`/`brand`/`deviceFingerprint` 的那个。
  static const formUrlEncodedContentType =
      'application/x-www-form-urlencoded; charset=utf-8';

  static final urlRegex = RegExp(
    r'https?://[-A-Za-z0-9+&@#/%?=~_|!:,.;]+[-A-Za-z0-9+&@#/%=~_|]',
  );

  static const goodsUrlPrefix = "https://gaoneng.bilibili.com/tetris";

  // 'itemOpusStyle,opusBigCover,onlyfansVote,endFooterHidden,decorationCard,onlyfansAssetsV2,ugcDelete,onlyfansQaCard,editable,opusPrivateVisible,avatarAutoTheme,sunflowerStyle,cardsEnhance,eva3CardOpus,eva3CardVideo,eva3CardComment,eva3CardVote,eva3CardUser'
  static const dynFeatures = 'itemOpusStyle,listOnlyfans,onlyfansQaCard';
}
