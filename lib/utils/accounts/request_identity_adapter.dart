import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_owner.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_snapshot.dart';
import 'package:PiliPlus/utils/id_utils.dart';

final class RequestIdentityAdapter {
  RequestIdentityAdapter._({
    required this.ownerKey,
    required this.buvid,
    required this.localId,
    required this.biliLocalId,
    required this.deviceId,
    required this.sessionId,
    required this.fpLocal,
    required this.fpRemote,
    required this.profile,
    required this.deviceName,
    required this.devicePlatform,
    required this.traceId,
    required this.auroraZone,
    required this.isLogin,
    required this.mid,
    this.auroraEid,
  });

  factory RequestIdentityAdapter.fromAccount({
    required Account account,
    required String userAgent,
  }) {
    final snapshot = OwnerScopedIdentitySnapshot.fromAccount(account);
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: snapshot.owner,
      storedProfile: snapshot.profile,
    );
    return RequestIdentityAdapter._build(
      ownerKey: snapshot.owner.key,
      buvid: snapshot.profile.buvid,
      isLogin: snapshot.isLogin,
      mid: snapshot.mid,
      derived: derived,
      // 账号绑定的平台 + 设备（登录时确定，之后一直沿用）。
      boundProfile: account.appRequestProfile,
    );
  }

  factory RequestIdentityAdapter.fromBuvid({
    required String buvid,
    required String userAgent,
    String scope = 'login-rest',
  }) {
    final owner = IdentityOwnerKey.workflow(scope);
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: owner,
      storedProfile: IdentityCoreProfile(owner: owner, buvid: buvid),
    );
    return RequestIdentityAdapter._build(
      ownerKey: owner.key,
      buvid: buvid,
      isLogin: false,
      mid: 0,
      derived: derived,
      boundProfile: null,
    );
  }

  factory RequestIdentityAdapter._build({
    required String ownerKey,
    required String buvid,
    required bool isLogin,
    required int mid,
    required IdentityDerivedProfile derived,
    required AppRequestProfile? boundProfile,
  }) {
    final profile =
        boundProfile ??
        AppDeviceProfiles.resolve(ownerKey: ownerKey, deviceProfile: null);
    return RequestIdentityAdapter._(
      ownerKey: ownerKey,
      buvid: buvid,
      localId: derived.localId,
      biliLocalId: derived.biliLocalId,
      deviceId: derived.deviceId,
      sessionId: derived.sessionId,
      fpLocal: derived.fpLocal,
      fpRemote: derived.fpRemote,
      profile: profile,
      deviceName: profile.deviceName,
      devicePlatform: profile.devicePlatform,
      traceId: derived.traceId,
      auroraZone: Constants.baseHeaders['x-bili-aurora-zone'] ?? '',
      isLogin: isLogin,
      mid: mid,
      // REST 走官方的 okretro/OkHttp 全局 aurora 拦截器
      // （`p087dm1/a.java:43` → `Wl1.a.a()` = android `Base64(..., 10)`），
      // 该实现用 **URL-safe** 字母表；gRPC 侧才是标准字母表。
      auroraEid: isLogin && mid > 0
          ? IdUtils.genAuroraEid(mid, urlSafe: true)
          : null,
    );
  }

  final String ownerKey;
  final String buvid;
  final String localId;
  final String biliLocalId;
  final String deviceId;
  final String sessionId;
  final String fpLocal;
  final String fpRemote;
  final AppRequestProfile profile;
  final String deviceName;
  final String devicePlatform;
  final String traceId;
  final String auroraZone;
  final bool isLogin;
  final int mid;
  final String? auroraEid;

  Map<String, String> get loginPayloadFields => {
    'local_id': localId,
    'bili_local_id': biliLocalId,
    'device_id': deviceId,
    'device_name': deviceName,
    'device_platform': devicePlatform,
  };

  Map<String, String> get restPayloadFields => {
    'local_id': localId,
    'device_name': deviceName,
    'device_platform': devicePlatform,
  };

  /// REST 公共头。
  ///
  /// `env` / `app-key` **对所有请求都发**：它们来自官方 H5/WebView 桥接路径
  /// （`WebContainerOfflineRuntimeKt` 用 `fawkes_key` + `env`，真机抓包实证
  /// 该路径确实发 `app-key: android64` + `env: prod`），而本项目多数 web 端点
  /// 是照 H5 逆向的，需要它们在场。
  ///
  /// [appKey] 缺省取档案自带的 appkey —— 这一对必须与请求里的 `mobi_app` 同源。
  Map<String, String> appHeaders({
    String? appKey,
    required String userAgent,
    String? contentType,
  }) => {
    // 键名保持小写：HTTP/2 会把头名统一小写，改成 `Buvid` 无功能收益，
    // 却会在 HTTP/1.1 回退栈上与其它小写写法重复。
    'buvid': buvid,
    'env': 'prod',
    'app-key': appKey ?? profile.appKey,
    'user-agent': userAgent,
    'x-bili-trace-id': traceId,
    'x-bili-aurora-zone': auroraZone,
    // 官方全局 aurora 拦截器（`p087dm1/a.java:50-57`）**无条件**设置这个头：
    // 登录态为 `<mid>`，未登录为空串（不是不设，也不是 "0"）。
    'x-bili-mid': mid > 0 ? '$mid' : '',
    if (auroraEid != null) 'x-bili-aurora-eid': auroraEid!,
    // 官方的 moss/rest REST 栈（`Fn1/a.java:78` 与 `Bb1/d.java:58-62`）会**同时**发
    // `bili-rest-engine: moss` 与 `bili-http-engine: <运行时引擎名>`；
    // 本项目的 REST 身份头组（user-agent + fp_local/fp_remote/session_id）与这条栈最接近。
    //
    // 引擎名 `cronet` 并非自造：9.13.0 包里存在 `moss_grpc_cronet` /
    // `moss_rest_okhttp_cronet` / `okhttp_cronet` 等配置键，说明 cronet 是官方支持的引擎之一
    // （真机抓包中该头为 `ignet`，两者都是合法取值）。
    'bili-rest-engine': 'moss',
    'bili-http-engine': 'cronet',
    if (contentType != null) 'content-type': contentType,
  };

  Map<String, String> get appIdentityHeaders => {
    'fp_local': fpLocal,
    'fp_remote': fpRemote,
    'session_id': sessionId,
  };

  Map<String, String> webDeviceQueryFields({required String spmid}) => {
    'x-bili-device-req-json': webDeviceReqJson(spmid: spmid),
  };

  String webDeviceReqJson({required String spmid}) => jsonEncode({
    'platform': 'web',
    'device': 'pc',
    'spmid': spmid,
  });

  Map<String, String> get webDmImageQueryFields => {
    'dm_img_list': '[]',
    'dm_img_str': _deriveWebEncodedField('dm_img_str', targetLength: 32),
    'dm_cover_img_str': _deriveWebEncodedField(
      'dm_cover_img_str',
      targetLength: 64,
    ),
    'dm_img_inter': jsonEncode({
      'ds': <Object>[],
      'wh': [0, 0, 0],
      'of': [0, 0, 0],
    }),
  };

  static Map<String, String> preserveGaiaFields({
    String? gaiaVtoken,
    String? vVoucher,
    String? griskId,
  }) => {
    if (gaiaVtoken?.isNotEmpty == true) 'gaia_vtoken': gaiaVtoken!,
    if (vVoucher?.isNotEmpty == true) 'v_voucher': vVoucher!,
    if (griskId?.isNotEmpty == true) 'grisk_id': griskId!,
  };

  static Map<String, String> gaiaCookieHeaders({String? gaiaVtoken}) => {
    if (gaiaVtoken?.isNotEmpty == true)
      'cookie': 'x-bili-gaia-vtoken=$gaiaVtoken',
  };

  String _deriveWebEncodedField(String label, {required int targetLength}) {
    final chunks = <String>[];
    for (var index = 0; chunks.join().length < targetLength; index++) {
      final encoded = base64
          .encode(
            utf8.encode('$label:$ownerKey:$buvid:$deviceId:$index'),
          )
          .replaceAll('=', '');
      chunks.add(encoded);
    }
    return chunks.join().substring(0, targetLength);
  }
}
