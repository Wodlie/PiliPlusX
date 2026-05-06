import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_owner.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_snapshot.dart';
import 'package:PiliPlus/utils/id_utils.dart';

final class RequestIdentityAdapter {
  RequestIdentityAdapter._({
    required this.buvid,
    required this.localId,
    required this.biliLocalId,
    required this.deviceId,
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
    final derived = IdentityCoreGenerators.deriveProfile(
      owner: snapshot.owner,
      storedProfile: snapshot.profile,
    );
    return RequestIdentityAdapter._build(
      buvid: snapshot.profile.buvid,
      userAgent: userAgent,
      isLogin: snapshot.isLogin,
      mid: snapshot.mid,
      derived: derived,
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
      buvid: buvid,
      userAgent: userAgent,
      isLogin: false,
      mid: 0,
      derived: derived,
    );
  }

  factory RequestIdentityAdapter._build({
    required String buvid,
    required String userAgent,
    required bool isLogin,
    required int mid,
    required IdentityDerivedProfile derived,
  }) {
    final deviceName = _deviceNameFromUserAgent(userAgent);
    return RequestIdentityAdapter._(
      buvid: buvid,
      localId: derived.localId,
      biliLocalId: derived.biliLocalId,
      deviceId: derived.deviceId,
      deviceName: deviceName,
      devicePlatform: _devicePlatformFromUserAgent(
        userAgent: userAgent,
        deviceName: deviceName,
      ),
      traceId: derived.traceId,
      auroraZone: Constants.baseHeaders['x-bili-aurora-zone'] ?? '',
      isLogin: isLogin,
      auroraEid: isLogin && mid > 0 ? IdUtils.genAuroraEid(mid) : null,
    );
  }

  final String buvid;
  final String localId;
  final String biliLocalId;
  final String deviceId;
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

  static String _deviceNameFromUserAgent(String userAgent) {
    final model = RegExp(r'model/([^\s]+)').firstMatch(userAgent)?.group(1);
    if (model != null && model.trim().isNotEmpty) {
      return model.trim();
    }
    final mobiApp = RegExp(r'mobi_app/([^\s]+)').firstMatch(userAgent)?.group(1);
    if (mobiApp != null && mobiApp.trim().isNotEmpty) {
      return mobiApp.trim();
    }
    return Constants.appName;
  }

  static String _devicePlatformFromUserAgent({
    required String userAgent,
    required String deviceName,
  }) {
    final os = RegExp(r'os/([^\s]+)').firstMatch(userAgent)?.group(1)?.trim();
    final osVer =
        RegExp(r'osVer/([^\s]+)').firstMatch(userAgent)?.group(1)?.trim();
    final normalizedOs = (os == null || os.isEmpty)
        ? 'Android'
        : '${os[0].toUpperCase()}${os.substring(1)}';
    final versionPart = (osVer == null || osVer.isEmpty) ? '' : osVer;
    return '$normalizedOs$versionPart$deviceName';
  }
}
