import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/locale.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/network.pb.dart' as network;
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

abstract final class GrpcHeaders {
  static const _profile = AppDeviceProfiles.android;

  /// 所有 `x-bili-*-bin` 的统一编码。
  ///
  /// gRPC 规范要求二进制 metadata 的 base64 **不带 padding**，官方用的正是
  /// `com.bilibili.lib.moss.utils.MetadataCodeC.encode` =
  /// `io.grpc.InternalMetadata.BASE64_ENCODING_OMIT_PADDING`。
  ///
  /// （对比：官方 kntr 的**纯头**通道用 Kotlin `Base64.Default`（带 padding），
  /// 例如 `x-bili-aurora-eid`；两者不可混用。）
  static String _bin(List<int> bytes) =>
      base64Encode(bytes).replaceAll('=', '');

  /// `x-bili-fawkes-req-bin`。
  ///
  /// `appkey` 是 **Fawkes 档位串**（`GFoundation.getFawkesAppKey()`），
  /// 不是签名 appkey、也不是 `mobi_app`：国内 arm64 包为 `android64`
  /// （真机抓包 + `tflite/a.java` 三档字面量 + `gripper/update/a.java` 的 64 规则）。
  static String fawkes(String sessionId) => _bin(
    FawkesReq(
      appkey: _profile.fawkesAppKey,
      env: 'prod',
      sessionId: sessionId,
    ).writeToBuffer(),
  );

  /// `x-bili-locale-bin` —— **固定头**，不随设备变动。
  ///
  /// 官方 `BiliConfig.Delegate.getLocalBin()`（`gripper/container/bilow/b.java:110`）
  /// 会取 App 内语言 / 系统语言 / 设备时区 / UTC 偏移 / 夏令时 / 自动翻译；
  /// 本项目按要求一律用常量，避免泄露设备信息。
  ///
  /// 第 5 字段 `utcOffset` 是抓包里实际出现的值（`x-bili-locale-bin` 解码 →
  /// `timezone=Asia/Shanghai`, `utcOffset=+08:00`）；`isDaylightTime` /
  /// `alwaysTranslate` 为 proto 默认 `false`，不会序列化。
  ///
  /// Base64 **不带 padding** —— 与其它 `-bin` 一致走 gRPC 的 omit-padding 约定
  /// （官方 moss 库 `MetadataCodec.encode`）。注意官方 kntr 的**纯头**通道
  /// （`imp/n.java:27` 的 Kotlin `Base64.Default`）才带 padding，本函数不在那条路径上。
  static String localeBin() => _bin(
    Locale(
      cLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
      sLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
      timezone: 'Asia/Shanghai',
      utcOffset: '+08:00',
    ).writeToBuffer(),
  );

  static Map<String, String> newHeaders([
    String? accessKey,
    String? buvid,
    AppDeviceProfile? deviceProfile,
    int? mid,
  ]) {
    final identity = _resolveHeaderIdentity(
      accessKey: accessKey,
      buvid: buvid,
      fallbackDeviceProfile: deviceProfile,
    );
    final resolvedBuvid = identity.profile.buvid;
    final profile = AppDeviceProfiles.resolve(
      ownerKey: identity.profile.owner.key,
      deviceProfile: deviceProfile ?? identity.deviceProfile,
    );
    return {
      'grpc-encoding': 'gzip',
      // 官方用 `grpc-accept-encoding`（Ktor 回退路径 = "gzip"，
      // 见 `kntr/base/moss/ignet/impl/grpc/ignet/fallback/a.java:32`；
      // chronos 插件 = "identity, gzip"）。原来的 `gzip-accept-encoding`
      // 在官方代码里**不存在**，是自造的头名。
      'grpc-accept-encoding': 'gzip',
      'user-agent': profile.userAgent,
      'x-bili-gaia-vtoken': '',
      'x-bili-aurora-zone': Constants.baseHeaders['x-bili-aurora-zone'] ?? '',
      'x-bili-trace-id': identity.derived.traceId,
      'buvid': resolvedBuvid,
      // 与 REST 侧一致：官方 ignet 的 gRPC 回退路径同样发这一对
      // （`fallback/a.java:33-37`：`bili-rest-engine: moss` + `bili-http-engine: <引擎名>`）。
      'bili-rest-engine': 'moss',
      'bili-http-engine': 'cronet',
      if (identity.auroraEid != null) 'x-bili-aurora-eid': identity.auroraEid!,
      // 官方 gRPC 侧由 Gripper provider `Ib1/a.java:35-41` 提供：
      // 未登录时 `Ib1/g.getMid()` 返回 **null** → provider 返回 null →
      // 被 `header/b.java` 的 null 过滤跳过 ⇒ **整键不发**（不是发 "0"）。
      if (mid != null && mid > 0) 'x-bili-mid': '$mid',
      'x-bili-device-bin': _bin(
        Device(
          appId: profile.appId,
          build: profile.build,
          buvid: resolvedBuvid,
          mobiApp: profile.mobiApp,
          platform: profile.platform,
          channel: profile.channel,
          brand: profile.brand,
          model: profile.model,
          osver: profile.osver,
          fpLocal: identity.derived.fpLocal,
          fpRemote: identity.derived.fpRemote,
          versionName: profile.versionName,
          fp: identity.derived.fpLocal,
          guestId: identity.derived.deviceId,
        ).writeToBuffer(),
      ),
      'x-bili-network-bin': _bin(
        network.Network(type: network.NetworkType.WIFI).writeToBuffer(),
      ),
      // 固定头（不随设备变动）—— 见 [localeBin] 的说明。
      'x-bili-locale-bin': localeBin(),
      'x-bili-exps-bin': '',
      // 由 Jc0.a（主 Metadata 构建器）始终加入：
      // - x-bili-restriction-bin（Restriction proto，无登录态约束时为空）
      // 见 Jc0/a.java line 48: metadata.put(aVar.e, runtimeHelper.restriction().toByteArray())
      'x-bili-restriction-bin': '',
      if (accessKey != null) 'authorization': 'identify_v1 $accessKey',
      'x-bili-fawkes-req-bin': fawkes(identity.derived.sessionId),
      // 由 Sc0.a（Ticket 拦截器）总是接续 Aurora 处理之后无条件添加
      'x-bili-ticket': '',
      'x-bili-metadata-bin': _bin(
        Metadata(
          accessKey: accessKey,
          mobiApp: profile.mobiApp,
          device: profile.platform,
          build: profile.build,
          channel: profile.channel,
          buvid: resolvedBuvid,
          platform: profile.platform,
        ).writeToBuffer(),
      ),
    };
  }

  static String currentImDeviceId() {
    final snapshot = Accounts.snapshot(AccountType.main);
    return IdentityCoreGenerators.deriveProfile(
      owner: snapshot.owner,
      storedProfile: snapshot.profile,
    ).deviceId;
  }

  static _GrpcResolvedIdentity _resolveHeaderIdentity({
    required String? accessKey,
    required String? buvid,
    required AppDeviceProfile? fallbackDeviceProfile,
  }) {
    final normalizedBuvid = _normalizeBuvid(accessKey: accessKey, buvid: buvid);
    for (final type in AccountType.values) {
      final snapshot = Accounts.snapshot(type);
      if (_matchesSnapshot(
        snapshot,
        accessKey: accessKey,
        buvid: normalizedBuvid,
      )) {
        final account = Accounts.get(type);
        return _resolvedIdentityFromSnapshot(snapshot, account: account);
      }
    }

    final owner = accessKey == null
        ? const IdentityOwnerKey.guest()
        : IdentityOwnerKey.workflow('grpc:${normalizedBuvid.toLowerCase()}');
    final profile = IdentityCoreProfile(owner: owner, buvid: normalizedBuvid);
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: owner,
      storedProfile: profile,
    );
    return (
      profile: profile,
      derived: derived,
      deviceProfile: fallbackDeviceProfile,
      auroraEid: null,
    );
  }

  static bool _matchesSnapshot(
    OwnerScopedIdentitySnapshot snapshot, {
    required String? accessKey,
    required String buvid,
  }) {
    if (snapshot.profile.buvid != buvid) {
      return false;
    }
    if (accessKey == null) {
      return !snapshot.isLogin;
    }
    return snapshot.isLogin && snapshot.accessKey == accessKey;
  }

  static _GrpcResolvedIdentity _resolvedIdentityFromSnapshot(
    OwnerScopedIdentitySnapshot snapshot, {
    required Account account,
  }) {
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: snapshot.owner,
      storedProfile: snapshot.profile,
    );
    return (
      profile: snapshot.profile,
      derived: derived,
      deviceProfile: switch (account) {
        final LoginAccount account => account.deviceProfile,
        _ => null,
      },
      auroraEid: snapshot.isLogin && snapshot.mid > 0
          ? IdUtils.genAuroraEid(snapshot.mid)
          : null,
    );
  }

  static String _normalizeBuvid({
    required String? accessKey,
    required String? buvid,
  }) {
    final normalized = buvid?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
    if (accessKey == null) {
      return Pref.guestBuvid;
    }
    final owner = IdentityOwnerKey.workflow('grpc-login');
    return IdentityCoreGenerators.deriveProfile(owner: owner).profile.buvid;
  }
}

typedef _GrpcResolvedIdentity = ({
  IdentityCoreProfile profile,
  IdentityDerivedProfile derived,
  AppDeviceProfile? deviceProfile,
  String? auroraEid,
});
