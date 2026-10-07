import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:PiliPlus/utils/accounts/identity_core.dart';
import 'package:PiliPlus/utils/accounts/identity_persistence.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:hive_ce/hive.dart';

sealed class Account {
  Map<String, dynamic>? toJson() => null;

  Future<void>? onChange() => null;

  Set<AccountType> get type => const {};

  bool get activated => false;

  set activated(bool value) => throw UnimplementedError();

  String? get accessKey => throw UnimplementedError();

  /// 唯一 BUVID 解析入口。
  /// 登录态仅取账号自身值；游客态仅取 guest key；不允许隐式 fallback。
  String get buvid => throw UnimplementedError();

  DefaultCookieJar get cookieJar => throw UnimplementedError();

  String get csrf => throw UnimplementedError();

  Future<void> delete() => throw UnimplementedError();

  Map<String, String> get headers => throw UnimplementedError();

  Map<String, String> get grpcHeaders => throw UnimplementedError();

  bool get isLogin => throw UnimplementedError();

  int get mid => throw UnimplementedError();

  String? get refresh => throw UnimplementedError();

  /// 该账号绑定的平台档位（`mobi_app`）。
  ///
  /// 登录时确定（`LoginPage.setAccount`），之后该账号的所有请求都用它 ——
  /// 参数里的 `mobi_app`/`build`/`statistics`、UA 与身份头全部同源。
  /// 未登录 / 无账号时用国内基线。
  String get boundMobiApp => AppDeviceProfiles.android.mobiApp;

  /// 该账号绑定的设备档案（品牌/型号/系统版本）。同样是登录时确定。
  AppDeviceProfile? get boundDeviceProfile => null;

  /// 该账号的请求档案 = 绑定平台 + 绑定设备。
  ///
  /// 访客按 `ownerKey` 从设备池里稳定取一台；登录号用绑定值。
  AppRequestProfile get appRequestProfile => AppDeviceProfiles.resolve(
    ownerKey: 'guest',
    deviceProfile: boundDeviceProfile,
    base: AppDeviceProfiles.forMobiApp(boundMobiApp),
  );

  const Account();
}

@HiveType(typeId: 9)
class LoginAccount extends Account {
  @override
  final bool isLogin = true;
  @override
  @HiveField(0)
  final DefaultCookieJar cookieJar;
  @override
  @HiveField(1)
  final String? accessKey;
  @override
  @HiveField(2)
  final String? refresh;
  @override
  @HiveField(3)
  final Set<AccountType> type;
  @override
  @HiveField(4)
  final String buvid;
  @HiveField(5)
  final AppDeviceProfile? deviceProfile;

  /// 登录时使用的平台档位（`mobi_app`）：`android`（国内）/ `android_i`（海外）。
  ///
  /// 与 [deviceProfile] 一起在登录成功时绑定；老记录没有这个字段，
  /// 反序列化时回落国内基线。
  @HiveField(6)
  final String mobiApp;

  @override
  String get boundMobiApp => mobiApp;

  @override
  AppDeviceProfile? get boundDeviceProfile => deviceProfile;

  @override
  AppRequestProfile get appRequestProfile => AppDeviceProfiles.resolve(
    ownerKey: 'account:$mid',
    deviceProfile: deviceProfile,
    base: AppDeviceProfiles.forMobiApp(mobiApp),
  );

  /// Whether this account's BUVID was auto-generated because the stored Hive
  /// record lacked field 4 (old accounts created before per-account BUVID).
  /// When true, [Accounts.refresh] will persist this account back so the
  /// generated BUVID is durably saved.
  final bool _needsBuvidPersist;
  bool get needsBuvidPersist => _needsBuvidPersist || deviceProfile == null;

  @override
  bool activated = false;

  @override
  late final int mid = int.parse(_midStr);

  @override
  late final Map<String, String> headers = {
    ...Constants.baseHeaders,
    'x-bili-mid': _midStr,
    'x-bili-aurora-eid': IdUtils.genAuroraEid(mid),
  };

  @override
  Map<String, String> get grpcHeaders =>
      GrpcHeaders.newHeaders(accessKey, buvid, appRequestProfile, mid);

  @override
  late final String csrf =
      cookieJar.domainCookies['bilibili.com']!['/']!['bili_jct']!.cookie.value;

  bool _hasDelete = false;

  @override
  Future<void> delete() {
    _hasDelete = true;
    return Future.wait([cookieJar.deleteAll(), _box.delete(_midStr)]);
  }

  @override
  Future<void>? onChange() {
    if (_hasDelete) return null;
    return _box.put(_midStr, _persistedAccount);
  }

  @override
  Map<String, dynamic>? toJson() => {
    'cookies': cookieJar.toJson(),
    'accessKey': accessKey,
    'refresh': refresh,
    'type': type.map((i) => i.index).toList(),
    'buvid': buvid,
    if (deviceProfile != null) 'deviceProfile': deviceProfile!.toJson(),
    'mobiApp': mobiApp,
  };

  final String _midStr;

  late final Box<LoginAccount> _box = Accounts.account;

  factory LoginAccount(
    DefaultCookieJar cookieJar,
    String? accessKey,
    String? refresh, [
    Set<AccountType>? type,
    String? buvid,
    AppDeviceProfile? deviceProfile,
    String? mobiApp,
  ]) {
    return LoginAccount._resolve(
      cookieJar,
      accessKey,
      refresh,
      type: type,
      buvid: buvid,
      deviceProfile: deviceProfile,
      mobiApp: mobiApp,
      persistResolvedDeviceProfile: true,
    );
  }

  factory LoginAccount.restored(
    DefaultCookieJar cookieJar,
    String? accessKey,
    String? refresh, [
    Set<AccountType>? type,
    String? buvid,
    AppDeviceProfile? deviceProfile,
    String? mobiApp,
  ]) {
    return LoginAccount._resolve(
      cookieJar,
      accessKey,
      refresh,
      type: type,
      buvid: buvid,
      deviceProfile: deviceProfile,
      mobiApp: mobiApp,
      persistResolvedDeviceProfile: false,
    );
  }

  factory LoginAccount._resolve(
    DefaultCookieJar cookieJar,
    String? accessKey,
    String? refresh, {
    Set<AccountType>? type,
    String? buvid,
    required AppDeviceProfile? deviceProfile,
    required String? mobiApp,
    required bool persistResolvedDeviceProfile,
  }) {
    final resolved = _resolveLoginAccountIdentity(cookieJar, buvid);
    final resolvedDeviceProfile =
        deviceProfile ??
        (persistResolvedDeviceProfile
            ? AppDeviceProfiles.defaultDeviceProfileForOwner(
                resolved.resolution.profile.owner.key,
              )
            : null);
    return LoginAccount._(
      cookieJar,
      accessKey,
      refresh,
      type ?? {},
      resolved.midStr,
      resolved.resolution.profile.buvid,
      resolvedDeviceProfile,
      mobiApp ?? AppDeviceProfiles.android.mobiApp,
      resolved.resolution.source == IdentityPersistenceSource.generated ||
          resolved.resolution.source == IdentityPersistenceSource.legacy,
    );
  }

  LoginAccount._(
    this.cookieJar,
    this.accessKey,
    this.refresh,
    this.type,
    this._midStr,
    this.buvid,
    this.deviceProfile,
    this.mobiApp,
    this._needsBuvidPersist,
  ) {
    cookieJar.setBuvid3();
  }

  factory LoginAccount.fromJson(Map json) => LoginAccount.restored(
    BiliCookieJar.fromJson(json['cookies']),
    json['accessKey'],
    json['refresh'],
    (json['type'] as Iterable?)?.map((i) => AccountType.values[i]).toSet(),
    json['buvid'],
    switch (json['deviceProfile']) {
      final Map deviceProfile => AppDeviceProfile.fromJson(deviceProfile),
      _ => null,
    },
    json['mobiApp'] as String?,
  );

  LoginAccount get _persistedAccount => deviceProfile == null
      ? LoginAccount._(
          cookieJar,
          accessKey,
          refresh,
          {...type},
          _midStr,
          buvid,
          AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
          mobiApp,
          false,
        )
      : this;

  @override
  int get hashCode => mid.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LoginAccount && mid == other.mid);
}

class AnonymousAccount extends Account {
  @override
  final bool isLogin = false;
  @override
  final DefaultCookieJar cookieJar = DefaultCookieJar()..setBuvid3();
  @override
  final String? accessKey = null;
  @override
  String get buvid => Pref.guestBuvid;
  @override
  final String? refresh = null;
  @override
  final Set<AccountType> type = {};
  @override
  final int mid = 0;
  @override
  final String csrf = '';
  @override
  final Map<String, String> headers = Constants.baseHeaders;

  @override
  Map<String, String> get grpcHeaders => GrpcHeaders.newHeaders(null, buvid);

  @override
  bool activated = false;

  @override
  Future<void> delete() {
    activated = false;
    return Future.wait([
      cookieJar.deleteAll(),
      Pref.deleteGuestBuvid(),
    ]).whenComplete(cookieJar.setBuvid3);
  }

  static final _instance = AnonymousAccount._();

  AnonymousAccount._();

  factory AnonymousAccount() => _instance;

  @override
  int get hashCode => cookieJar.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnonymousAccount && cookieJar == other.cookieJar);
}

({
  String midStr,
  IdentityPersistenceResolution resolution,
})
_resolveLoginAccountIdentity(
  DefaultCookieJar cookieJar,
  String? storedBuvid,
) {
  final midStr = cookieJar
      .domainCookies['bilibili.com']!['/']!['DedeUserID']!
      .cookie
      .value;
  return (
    midStr: midStr,
    resolution: OwnerScopedIdentityPersistence.resolve(
      owner: IdentityOwnerKey.account(int.parse(midStr)),
      storedBuvid: storedBuvid,
    ),
  );
}

extension BiliCookie on Cookie {
  void setBiliDomain([String domain = '.bilibili.com']) {
    this.domain = domain;
    httpOnly = false;
    path = '/';
  }
}

extension BiliCookieJar on DefaultCookieJar {
  Map<String, String> toJson() {
    final cookies = domainCookies['bilibili.com']?['/'] ?? const {};
    return {for (final i in cookies.values) i.cookie.name: i.cookie.value};
  }

  /// 凭证指纹的输入串。
  ///
  /// 只用于 `AccountHealthIdentity` 的摘要比较（cookie 轮换即视为凭证变化），
  /// **不得**用于日志或持久化。按 cookie 名排序，保证同内容不同插入顺序得到
  /// 相同结果。
  String get digestSource {
    final entries = toJson().entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => '${e.key}=${e.value}').join('\u0000');
  }

  List<Cookie> toList() =>
      domainCookies['bilibili.com']?['/']?.entries
          .map((i) => i.value.cookie)
          .toList() ??
      [];

  void setBuvid3() {
    (domainCookies['bilibili.com'] ??= {
      '/': {},
    })['/']!['buvid3'] ??= SerializableCookie(
      Cookie('buvid3', IdUtils.genBuvid3())..setBiliDomain(),
    );
  }

  static DefaultCookieJar fromJson(Map json) =>
      DefaultCookieJar(ignoreExpires: true)
        ..domainCookies['bilibili.com'] = {
          '/': {
            for (final i in json.entries)
              i.key: SerializableCookie(
                Cookie(i.key, i.value)..setBiliDomain(),
              ),
          },
        };

  static DefaultCookieJar fromList(List cookies) =>
      DefaultCookieJar(ignoreExpires: true)
        ..domainCookies['bilibili.com'] = {
          '/': {
            for (final i in cookies)
              i['name']!: SerializableCookie(
                Cookie(i['name']!, i['value']!)..setBiliDomain(),
              ),
          },
        };
}

final class NoAccount extends Account {
  const NoAccount();
}
