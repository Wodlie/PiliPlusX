import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/metadata.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/device.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/locale.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/network.pb.dart' as network;
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/identity_core.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';

abstract final class GrpcHeaders {
  static const _build = 2001100;
  static const _versionName = '2.0.1';
  static const _biliChannel = 'master';
  static const _mobiApp = 'android_hd';
  static const _device = 'android';
  static String get _sessionId => Utils.generateRandomString(8);

  static String get fawkes => base64Encode(
    FawkesReq(
      appkey: _mobiApp,
      env: 'prod',
      sessionId: _sessionId,
    ).writeToBuffer(),
  );

  static Map<String, String> newHeaders([String? accessKey, String? buvid]) {
    final identity = _resolveHeaderIdentity(accessKey: accessKey, buvid: buvid);
    final resolvedBuvid = identity.profile.buvid;
    return {
      'grpc-encoding': 'gzip',
      'gzip-accept-encoding': 'gzip,identity',
      'user-agent': Constants.userAgent,
      'x-bili-gaia-vtoken': '',
      'x-bili-aurora-zone': Constants.baseHeaders['x-bili-aurora-zone'] ?? '',
      'x-bili-trace-id': identity.derived.traceId,
      'buvid': resolvedBuvid,
      'bili-http-engine': 'cronet',
      if (identity.auroraEid != null) 'x-bili-aurora-eid': identity.auroraEid!,
      'x-bili-device-bin': base64Encode(
        Device(
          appId: 5,
          build: _build,
          buvid: resolvedBuvid,
          mobiApp: _mobiApp,
          platform: _device,
          channel: _biliChannel,
          brand: _device,
          model: _device,
          osver: '15',
          fpLocal: identity.derived.fpLocal,
          fpRemote: identity.derived.fpRemote,
          versionName: _versionName,
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
      'x-bili-fawkes-req-bin': fawkes,
      'x-bili-metadata-bin': base64Encode(
        Metadata(
          accessKey: accessKey,
          mobiApp: _mobiApp,
          device: _device,
          build: _build,
          channel: _biliChannel,
          buvid: resolvedBuvid,
          platform: _device,
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
  }) {
    final normalizedBuvid = _normalizeBuvid(accessKey: accessKey, buvid: buvid);
    for (final type in AccountType.values) {
      final snapshot = Accounts.snapshot(type);
      if (_matchesSnapshot(
        snapshot,
        accessKey: accessKey,
        buvid: normalizedBuvid,
      )) {
        return _resolvedIdentityFromSnapshot(snapshot);
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
    return (profile: profile, derived: derived, auroraEid: null);
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
    OwnerScopedIdentitySnapshot snapshot,
  ) {
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: snapshot.owner,
      storedProfile: snapshot.profile,
    );
    return (
      profile: snapshot.profile,
      derived: derived,
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
  String? auroraEid,
});
