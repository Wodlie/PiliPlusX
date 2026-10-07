import 'dart:convert';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:crypto/crypto.dart';

/// Cookie 可用性（普通 cookie 会话，不等于 gRPC 认证）。
enum CookieHealth { anonymous, invalid, valid, unknown }

/// `access_key`（登录返回的 `access_token`）可用性。
enum TokenHealth { missing, invalid, valid, unknown }

/// 账号类型：正式账号 / 游客。
enum AccountKind { anonymous, formal, tourist, unknown }

/// 账号凭证指纹。
///
/// 只用 [Account] 相等判断是不安全的：`LoginAccount` 的 `==` 只比较 mid，
/// 同 mid 重新登录换 key、换设备或换 cookie 都会被当成同一个账号，从而复用
/// 过期的校验结果。这里把「决定请求身份的字段」全部纳入指纹：
/// mid / accessKey / buvid / mobiApp / 绑定设备 / cookie 凭证摘要。
final class AccountHealthIdentity {
  const AccountHealthIdentity._({
    required this.mid,
    required this.accessKey,
    required this.buvid,
    required this.mobiApp,
    required this.deviceDigest,
    required this.cookieDigest,
    required this.isLogin,
  });

  factory AccountHealthIdentity.capture(Account account) {
    final profile = account.appRequestProfile;
    final device = profile.deviceProfile;
    return AccountHealthIdentity._(
      mid: account.isLogin ? account.mid : 0,
      accessKey: account.isLogin ? account.accessKey : null,
      buvid: account.buvid,
      mobiApp: account.isLogin ? profile.mobiApp : '',
      deviceDigest: _digest(
        [
          device.brand,
          device.model,
          device.osver,
        ].join('\u0000'),
      ),
      cookieDigest: _digest(account.cookieJar.digestSource),
      isLogin: account.isLogin,
    );
  }

  final int mid;
  final String? accessKey;
  final String buvid;
  final String mobiApp;
  final String deviceDigest;
  final String cookieDigest;
  final bool isLogin;

  /// 同一账号若重新登录/换 key/换设备/换 cookie，指纹不再匹配。
  bool matches(Account account) =>
      this == AccountHealthIdentity.capture(account);

  /// 绝不在日志/异常里暴露 accessKey 或 cookie 原文。
  @override
  String toString() =>
      'AccountHealthIdentity(mid: $mid, login: $isLogin, key: ${accessKey == null ? 'none' : 'present'})';

  /// 展示用的账号名（`mid` 是数字，`buvid` 不参与展示）：调试与提示只用这个。
  String get label => mid > 0 ? '$mid' : 'guest';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountHealthIdentity &&
          mid == other.mid &&
          accessKey == other.accessKey &&
          buvid == other.buvid &&
          mobiApp == other.mobiApp &&
          deviceDigest == other.deviceDigest &&
          cookieDigest == other.cookieDigest &&
          isLogin == other.isLogin;

  @override
  int get hashCode => Object.hash(
    mid,
    accessKey,
    buvid,
    mobiApp,
    deviceDigest,
    cookieDigest,
    isLogin,
  );
}

String _digest(String source) => sha256.convert(utf8.encode(source)).toString();

/// 一次生命周期校验的结果。
///
/// 三个维度分开保存：cookie 有效不能把失效 token 洗成有效，token 失效也不
/// 代表 cookie 失效（反之亦然）。只在内存里存在，不写入 Hive。
final class AccountHealth {
  const AccountHealth({
    required this.identity,
    required this.cookie,
    required this.token,
    required this.kind,
    this.cookieInfo,
    this.checkedAt,
    this.checking = false,
  });

  factory AccountHealth.initial(Account account) {
    final identity = AccountHealthIdentity.capture(account);
    return AccountHealth(
      identity: identity,
      cookie: identity.isLogin ? CookieHealth.unknown : CookieHealth.anonymous,
      token: identity.accessKey?.isNotEmpty == true
          ? TokenHealth.unknown
          : TokenHealth.missing,
      kind: identity.isLogin ? AccountKind.unknown : AccountKind.anonymous,
    );
  }

  final AccountHealthIdentity identity;
  final CookieHealth cookie;
  final TokenHealth token;
  final AccountKind kind;

  /// cookie nav 的原始结果，供既有资料展示流程复用（不再重复请求）。
  final UserInfoData? cookieInfo;

  /// 上一次**完成**的校验时间；`null` 表示这个凭证还没有完成过校验。
  final DateTime? checkedAt;

  /// 是否有校验正在进行（重检窗口）。
  ///
  /// 与 `checkedAt` 分开：即使上一轮已经完成过（`checkedAt` 非空），只要本轮
  /// 复检还没结束，[canUseReplyGrpc] 就必须是 false —— 否则复检期间会继续
  /// 沿用旧授权。
  final bool checking;

  /// 根评论走 gRPC 的唯一条件：正式账号 + token 明确有效 + 校验已完成。
  bool get canUseReplyGrpc =>
      !checking && token == TokenHealth.valid && kind == AccountKind.formal;

  /// 校验尚未完成（启动/切换后首帧，或复检进行中）——此时保守走 REST。
  bool get isChecking => checking || checkedAt == null;

  LoadingState<UserInfoData>? get cookieResult {
    final info = cookieInfo;
    return info == null ? null : Success(info);
  }

  AccountHealth copyWith({
    CookieHealth? cookie,
    TokenHealth? token,
    AccountKind? kind,
    UserInfoData? cookieInfo,
    DateTime? checkedAt,
    bool? checking,
  }) => AccountHealth(
    identity: identity,
    cookie: cookie ?? this.cookie,
    token: token ?? this.token,
    kind: kind ?? this.kind,
    cookieInfo: cookieInfo ?? this.cookieInfo,
    checkedAt: checkedAt ?? this.checkedAt,
    checking: checking ?? this.checking,
  );
}
