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
  static const _profile = AppDeviceProfiles.androidHd;

  static String fawkes(String sessionId) => base64Encode(
    FawkesReq(
      appkey: _profile.mobiApp,
      env: 'prod',
      sessionId: sessionId,
    ).writeToBuffer(),
  );

  static Map<String, String> newHeaders([
    String? accessKey,
    String? buvid,
    AppDeviceProfile? deviceProfile,
  ]) {
    final identity = _resolveHeaderIdentity(
      accessKey: accessKey,
      buvid: buvid,
      fallbackDeviceProfile: deviceProfile,
    );
    final resolvedBuvid = identity.profile.buvid;
    final profile = AppDeviceProfiles.resolve(
      userAgent: _profile.userAgent,
      ownerKey: identity.profile.owner.key,
      deviceProfile: deviceProfile ?? identity.deviceProfile,
    );
    return {
      'grpc-encoding': 'gzip',
      'gzip-accept-encoding': 'gzip,identity',
      'user-agent': profile.userAgent,
      'x-bili-gaia-vtoken': '',
      'x-bili-aurora-zone': Constants.baseHeaders['x-bili-aurora-zone'] ?? '',
      'x-bili-trace-id': identity.derived.traceId,
      'buvid': resolvedBuvid,
      'bili-http-engine': 'cronet',
      if (identity.auroraEid != null) 'x-bili-aurora-eid': identity.auroraEid!,
      'x-bili-device-bin': base64Encode(
        Device(
          appId: 5,
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
      'x-bili-network-bin': base64Encode(
        network.Network(type: network.NetworkType.WIFI).writeToBuffer(),
      ),
      'x-bili-locale-bin': base64Encode(
        Locale(
          cLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
          sLocale: LocaleIds(language: 'zh', region: 'CN', script: 'Hans'),
          timezone: 'Asia/Shanghai',
        ).writeToBuffer(),
      ),
      'x-bili-exps-bin': '',
      if (accessKey != null) 'authorization': 'identify_v1 $accessKey',
      'x-bili-fawkes-req-bin': fawkes(identity.derived.sessionId),
      'x-bili-metadata-bin': base64Encode(
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
