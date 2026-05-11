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
    this.auroraEid,
  });

  factory RequestIdentityAdapter.fromAccount({
    required Account account,
    required String userAgent,
  }) {
    final snapshot = OwnerScopedIdentitySnapshot.fromAccount(account);
    final storedDeviceProfile = account is LoginAccount ? account.deviceProfile : null;
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: snapshot.owner,
      storedProfile: snapshot.profile,
    );
    return RequestIdentityAdapter._build(
      ownerKey: snapshot.owner.key,
      buvid: snapshot.profile.buvid,
      userAgent: userAgent,
      isLogin: snapshot.isLogin,
      mid: snapshot.mid,
      derived: derived,
      storedDeviceProfile: storedDeviceProfile,
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
      userAgent: userAgent,
      isLogin: false,
      mid: 0,
      derived: derived,
      storedDeviceProfile: null,
    );
  }

  factory RequestIdentityAdapter._build({
    required String ownerKey,
    required String buvid,
    required String userAgent,
    required bool isLogin,
    required int mid,
    required IdentityDerivedProfile derived,
    required AppDeviceProfile? storedDeviceProfile,
  }) {
    final profile = AppDeviceProfiles.resolve(
      userAgent: userAgent,
      ownerKey: ownerKey,
      deviceProfile: storedDeviceProfile,
    );
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
      auroraEid: isLogin && mid > 0 ? IdUtils.genAuroraEid(mid) : null,
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

  Map<String, String> appHeaders({
    required String appKey,
    required String userAgent,
    String? contentType,
  }) => {
    'buvid': buvid,
    'env': 'prod',
    'app-key': appKey,
    'user-agent': userAgent,
    'x-bili-trace-id': traceId,
    'x-bili-aurora-zone': auroraZone,
    if (auroraEid != null) 'x-bili-aurora-eid': auroraEid!,
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
