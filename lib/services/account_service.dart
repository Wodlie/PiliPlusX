import 'dart:async';

import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';

/// 生命周期校验的三个探针。
///
/// 抽成接口的唯一目的是让单测能注入「内存 adapter 语义」的假实现，从而在**不
/// 发真实请求**的前提下验证代际（generation）行为；生产实现仍然走普通
/// `Request` / retry / HK 管线。
abstract interface class AccountHealthProbe {
  Future<({UserInfoData? info, int? code})> cookieNav(
    LoginAccount account,
    AccountHealthIdentity identity,
  );

  Future<Map<String, dynamic>?> tokenNav(
    LoginAccount account,
    AccountHealthIdentity identity,
    String accessKey,
  );

  Future<Map<String, dynamic>?> spaceMyInfo(
    LoginAccount account,
    AccountHealthIdentity identity,
  );
}

final class _HttpAccountHealthProbe implements AccountHealthProbe {
  const _HttpAccountHealthProbe();

  @override
  Future<({UserInfoData? info, int? code})> cookieNav(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async {
    try {
      final res = await UserHttp.userInfo(
        account: account,
        expectedIdentity: identity,
        updateGlobalState: false,
      );
      return (info: res.info, code: res.code);
    } catch (_) {
      return (info: null, code: null);
    }
  }

  @override
  Future<Map<String, dynamic>?> tokenNav(
    LoginAccount account,
    AccountHealthIdentity identity,
    String accessKey,
  ) async {
    try {
      return await UserHttp.tokenOnlyUserInfo(
        account: account,
        expectedIdentity: identity,
        accessKey: accessKey,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> spaceMyInfo(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async {
    try {
      return await UserHttp.spaceMyInfo(
        account: account,
        expectedIdentity: identity,
      );
    } catch (_) {
      return null;
    }
  }
}

class AccountService extends GetxService {
  final RxString face = ''.obs;
  final RxBool isLogin = false.obs;

  /// 只有 `Request.setCookie()` 就绪后才允许真的发校验请求。
  ///
  /// 未注册 GetX 服务或未启用校验时，账号发布只发布「未知」状态，不触发任何
  /// 网络调用（存储/身份单测因此保持无网）。
  bool _validationEnabled = false;

  AccountHealthProbe _probe = const _HttpAccountHealthProbe();

  /// 单测注入点：只替换探针，不改校验时序与代际语义。
  @visibleForTesting
  void debugSetProbe(AccountHealthProbe probe) => _probe = probe;

  final _health = <AccountHealthIdentity, AccountHealth>{};

  /// 每个凭证的**当前接受代际**：只有新出现 / 被替换的凭证才分配新代际，
  /// 同一凭证重复发布不改代际（否则每次发布都会把正在跑的校验判成过期，
  /// TTL 复用永远不成立）。
  ///
  /// 这同时解决 ABA：A→B→A 时 A 的行与代际一起被清掉，重新出现即为新凭证，
  /// 旧任务带着旧代际号无法写回，新任务一定重开。
  final _identityGeneration = <AccountHealthIdentity, int>{};

  /// 全局发布代数：只用于给新出现的凭证分配互不相同的代际号。
  int _cohort = 0;

  /// 在飞的校验任务（含它所属的代际，用于复用判定）。
  final _inFlight = <AccountHealthIdentity, _HealthRun>{};

  /// 每个凭证的「鉴权被明确拒绝」序号：`markTokenInvalid` 递增。
  ///
  /// 用途只有一个：让**发起更早**的 token 探针结论无法覆盖**更晚**到达的
  /// 明确拒绝（gRPC -101）。运行开始时的序号与写回时不一致，即表示本探针
  /// 发出之后服务端已经明确拒绝过 —— 此时只保护 token 维度，其余维度照常
  /// 收尾；后续新的生命周期校验仍可重新验证（不永久锁 invalid）。
  final _tokenRejectRevision = <AccountHealthIdentity, int>{};

  /// 已投影到 `face`/`isLogin`/金币的主账号身份（完整指纹，不是 mid）。
  AccountHealthIdentity? _projectedMain;

  /// 账号校验结果的只读视图（不进 Hive，不导出）。
  Map<AccountHealthIdentity, AccountHealth> get healthSnapshot =>
      Map.unmodifiable(_health);

  void enableValidation() => _validationEnabled = true;

  /// 账号发布（启动恢复 / 切换 / 重新登录 / 导入）。
  ///
  /// [recheck] 为 true（启动恢复）时即使有旧结果也重新校验。
  void onAccountsPublished(List<Account> selected, {bool recheck = false}) {
    _cohort++;
    final wanted = <AccountHealthIdentity, LoginAccount>{};
    for (final account in selected) {
      if (account is LoginAccount) {
        wanted[AccountHealthIdentity.capture(account)] = account;
      }
    }
    // 凭证变化（换 key/设备/cookie）或不再被任何角色选中的旧结果立即失效。
    _health.removeWhere((identity, _) => !wanted.containsKey(identity));
    _identityGeneration.removeWhere(
      (identity, _) => !wanted.containsKey(identity),
    );
    _tokenRejectRevision.removeWhere(
      (identity, _) => !wanted.containsKey(identity),
    );
    for (final entry in wanted.entries) {
      // 同一凭证重复发布（登录/快速切号会连续发布 7 个角色、每次 set 都发布）
      // **不改代际**：仍被选中且凭证未变的在飞任务必须继续有效，否则每次无关
      // 角色的发布都会把它判成过期，校验永远跑不完、TTL 复用也永不成立。
      _identityGeneration.putIfAbsent(entry.key, () => ++_cohort);
      if (!_validationEnabled) {
        _health.putIfAbsent(
          entry.key,
          () => AccountHealth.initial(entry.value),
        );
        continue;
      }
      // checking 只在真的要跑校验时发布（validate 内部判断）。
      unawaited(validate(entry.value, force: recheck));
    }
    // 即使不联网也要把「当前主账号是谁」投影出去：切换账号后
    // face/isLogin/金币不能继续停留在上一个账号的缓存值。
    _projectMain();
  }

  /// 已发布状态（纯读）。评论页只调这个，永远不触发网络。
  ///
  /// 表里没有记录时返回与 `AccountHealth.initial` 等价的保守状态，并且
  /// **不建立**任何表项——评论路径绝不新建校验。
  AccountHealth healthFor(Account account) {
    final identity = AccountHealthIdentity.capture(account);
    return _health[identity] ?? AccountHealth.initial(account);
  }

  /// 只读取**当前代际**的在飞任务；没有（或已过期）就返回 null
  /// （调用方不要因此新建校验）。
  Future<AccountHealth>? pendingFor(Account account) {
    final identity = AccountHealthIdentity.capture(account);
    final run = _inFlight[identity];
    if (run == null || run.generation != _identityGeneration[identity]) {
      return null;
    }
    return run.future;
  }

  /// 校验单个账号。同一凭证（同代际）并发调用复用同一 future。
  Future<AccountHealth> validate(Account account, {bool force = false}) {
    if (account is! LoginAccount) {
      return Future.value(AccountHealth.initial(account));
    }
    final identity = AccountHealthIdentity.capture(account);
    // 直接调用（未经过 `onAccountsPublished` 的入口，例如单测或页面主动校验）
    // 也必须先落一个代际：否则 `_isLive` 永远匹配不上，任务会在第一步之后
    // 静默终止、结果永远停在 checking。
    final generation = _identityGeneration.putIfAbsent(
      identity,
      () => ++_cohort,
    );
    final existing = _health[identity];
    if (!force && existing != null && !_needsRecheck(existing)) {
      return Future.value(existing);
    }
    final running = _inFlight[identity];
    // 只有同一代际的在飞任务可以复用；过期代际必须重开（ABA 下旧任务永远
    // 等不到写回，复用会让该凭证停在 unknown）。
    if (running != null && running.generation == generation) {
      return running.future;
    }

    // 真的开始一轮校验：先把「正在校验」发布出去，任何读取者都不会把旧的
    // valid / formal / checkedAt 当成仍然有效。
    _markChecking(identity, account);
    late final Future<AccountHealth> task;
    task = _runValidation(account, identity, generation).whenComplete(() {
      if (identical(_inFlight[identity]?.future, task)) {
        _inFlight.remove(identity);
      }
    });
    _inFlight[identity] = _HealthRun(generation: generation, future: task);
    return task;
  }

  static bool _needsRecheck(AccountHealth health) {
    // 校验没跑完（被后来的一轮顶掉等）绝不能因为时间戳还新就被跳过，
    // 否则该凭证会永远停在 checking。
    if (health.checking) return true;
    final checkedAt = health.checkedAt;
    if (checkedAt == null) return true;
    return DateTime.now().difference(checkedAt) >
        Duration(hours: Pref.accountHealthRecheckIntervalHours);
  }

  /// 发布「校验未完成」：保留既有资料用于展示，但 token 不再有效。
  ///
  /// [AccountHealth.copyWith] 无法把字段清成 null，所以这里直接重建对象 ——
  /// 只靠 `copyWith(token: unknown)` 会把 `checking` 留在旧值上，复检期间
  /// 依旧可能被判成可用。
  void _markChecking(AccountHealthIdentity identity, LoginAccount account) {
    final previous = _health[identity];
    final previousInfo = previous?.cookieInfo;
    _health[identity] = AccountHealth(
      identity: identity,
      cookie: previousInfo == null
          ? AccountHealth.initial(account).cookie
          : previous!.cookie,
      token: TokenHealth.unknown,
      kind: AccountKind.unknown,
      cookieInfo: previousInfo,
      // 已完成过的校验时间保留：`checkedAt == null` 专门表示「这个凭证从没
      // 完成过校验」，重检窗口用 checking 表达。
      checkedAt: previous?.checkedAt,
      checking: true,
    );
  }

  Future<AccountHealth> _runValidation(
    LoginAccount account,
    AccountHealthIdentity identity,
    int generation,
  ) async {
    // 本 run 开始时的「明确拒绝」序号：写回 token 结论前要再比一次。
    final tokenRejectRevision = _tokenRejectRevision[identity] ?? 0;
    // 每次写入都基于**最新**快照，而不是开局捕获的旧对象：`_markChecking`
    // 已经把 token/kind 清成 unknown，若在它之前捕获并在完成后整对象写回，
    // 会把刚拿到的 cookie 结果一起抹掉。
    AccountHealth latest() =>
        _health[identity] ?? AccountHealth.initial(account);

    /// 中间检查点：只更新结论，`checking` 保持 true、`checkedAt` 保持不动 ——
    /// 「校验完成」只能由 [finish] 宣告。
    void checkpoint({
      CookieHealth? cookie,
      TokenHealth? token,
      AccountKind? kind,
      UserInfoData? cookieInfo,
    }) {
      final now = latest();
      _publishHealth(
        identity,
        AccountHealth(
          identity: identity,
          cookie: cookie ?? now.cookie,
          token: token ?? now.token,
          kind: kind ?? now.kind,
          cookieInfo: cookieInfo ?? now.cookieInfo,
          checkedAt: now.checkedAt,
          checking: true,
        ),
      );
    }

    /// 本轮校验完整结束：只有这里清掉 checking、写 checkedAt。
    void finish({AccountKind? kind}) {
      final now = latest();
      _publishHealth(
        identity,
        AccountHealth(
          identity: identity,
          cookie: now.cookie,
          token: now.token,
          kind: kind ?? now.kind,
          cookieInfo: now.cookieInfo,
          checkedAt: DateTime.now(),
          checking: false,
        ),
      );
    }

    // 1) cookie 会话（普通 nav，账号 jar 注入 cookie）。
    final cookieNav = await _probe.cookieNav(account, identity);
    if (!_isLive(identity, account, generation)) {
      return healthFor(account);
    }
    final cookieHealth = _cookieHealthOf((
      info: cookieNav.info,
      code: cookieNav.code,
      expectedMid: identity.mid,
    ));
    // cookie 结论 + 原始资料一次写入；token/kind 仍是「校验中」的保守值。
    checkpoint(
      cookie: cookieHealth,
      kind: cookieHealth == CookieHealth.valid
          ? latest().kind
          : AccountKind.unknown,
      cookieInfo: cookieNav.info,
    );

    // 2) token-only nav?access_key=（必须隔离 cookie）。
    // 这一步结束时游客属性还没查，所以仍然是中间态。
    final key = identity.accessKey;
    if (key == null || key.isEmpty) {
      checkpoint(token: TokenHealth.missing);
    } else {
      final keyRaw = await _probe.tokenNav(account, identity, key);
      if (!_isLive(identity, account, generation)) {
        return healthFor(account);
      }
      if ((_tokenRejectRevision[identity] ?? 0) != tokenRejectRevision) {
        // 本探针**发出之后**服务端已经明确拒绝过（gRPC -101 → markTokenInvalid）：
        // 它的结论更旧，不得把 invalid 覆盖回 valid。只保护 token 维度，
        // 其余维度继续收尾（cookie / 游客 / checkedAt / checking），
        // 既不永久锁死 invalid（后续新 run 会重新验证），也不会永远停在 checking。
      } else {
        checkpoint(token: _tokenHealthOf(keyRaw, identity));
      }
    }

    // 3) 游客属性：同账号 cookie 查 space/myinfo。
    // 与 token 无关：cookie-only 账号也要能判明它是不是游客。
    if (cookieHealth != CookieHealth.valid) {
      finish(kind: AccountKind.unknown);
      return healthFor(account);
    }
    final myInfoRaw = await _probe.spaceMyInfo(account, identity);
    if (!_isLive(identity, account, generation)) {
      return healthFor(account);
    }
    finish(kind: _kindOf(myInfoRaw, identity));
    return healthFor(account);
  }

  static CookieHealth _cookieHealthOf(
    ({UserInfoData? info, int? code, int expectedMid}) res,
  ) {
    final info = res.info;
    // 明确未认证业务码才算失效。
    if (info == null) {
      return res.code == -101 ? CookieHealth.invalid : CookieHealth.unknown;
    }
    final mid = info.mid ?? 0;
    // 只有「明确已登录 + mid 与发起校验的账号一致」才算有效。
    // 缺 isLogin（畸形/截断响应）即使 mid 正确也只是未知 —— 不能据此放行 gRPC。
    if (info.isLogin == true && mid == res.expectedMid) {
      return CookieHealth.valid;
    }
    // 「明确未登录」且没有任何自相矛盾的身份字段 → 失效。
    if (info.isLogin == false && mid <= 0) {
      return CookieHealth.invalid;
    }
    // mid 属于别人（SESSDATA 是 B 的、DedeUserID 是 A 的）同样只能是未知，
    // 绝不拿别人的资料覆盖展示。
    return CookieHealth.unknown;
  }

  static TokenHealth _tokenHealthOf(
    Map<String, dynamic>? raw,
    AccountHealthIdentity identity,
  ) {
    if (raw == null) return TokenHealth.unknown;
    final code = raw['code'];
    if (code is int && code != 0) {
      // 只有明确的未认证业务码才算失效；风控/其它业务码保守视为未知。
      return code == -101 ? TokenHealth.invalid : TokenHealth.unknown;
    }
    final data = raw['data'];
    if (data is! Map) return TokenHealth.unknown;
    final isLogin = data['isLogin'];
    final mid = data['mid'];
    if (isLogin == true && mid is int && mid == identity.mid) {
      return TokenHealth.valid;
    }
    if (isLogin == false) return TokenHealth.invalid;
    return TokenHealth.unknown;
  }

  static AccountKind _kindOf(
    Map<String, dynamic>? raw,
    AccountHealthIdentity identity,
  ) {
    if (raw == null) return AccountKind.unknown;
    if (raw['code'] != 0) return AccountKind.unknown;
    final data = raw['data'];
    if (data is! Map) return AccountKind.unknown;
    final mid = data['mid'];
    if (mid is! int || mid != identity.mid) return AccountKind.unknown;
    // 只认已实测的字段形态：`is_tourist` 为整数 0（正式）/ 1（游客）。
    final tourist = data['is_tourist'];
    return switch (tourist) {
      0 => AccountKind.formal,
      1 => AccountKind.tourist,
      _ => AccountKind.unknown,
    };
  }

  /// 校验任务是否仍属「当前代际 + 当前凭证」。
  ///
  /// 不要求「是主账号」：一次发布会同时校验全部角色（main / video /
  /// heartbeat / reply / blacklist / report），非主角色同样必须能跑完，
  /// 否则它们会永远停在 checking。表项以**完整指纹**为键，代际 + 指纹
  /// 已足以保证结果不会写进别人的行。
  bool _isLive(
    AccountHealthIdentity identity,
    LoginAccount account,
    int generation,
  ) =>
      _identityGeneration[identity] == generation &&
      _health.containsKey(identity) &&
      identity.matches(account);

  void _publishHealth(AccountHealthIdentity identity, AccountHealth health) {
    if (!_health.containsKey(identity)) return;
    _health[identity] = health;
    if (_isCurrentMain(identity)) {
      _projectMain();
    }
  }

  bool _isCurrentMain(AccountHealthIdentity identity) {
    final main = Accounts.main;
    return main is LoginAccount && identity.matches(main);
  }

  /// 把当前主账号的展示状态（头像 / 登录态 / 金币）投影出去。
  ///
  /// 每次投影都按**完整指纹**比较：同 mid 换 key、换 cookie、换设备都算换了
  /// 账号，必须重新投影，否则会保留上一个账号的头像与登录态。主账号变成匿名
  /// （登出 / 删除账号）时同样要清理，不能把上一个账号的登录态与余额留在界面上。
  void _projectMain() {
    final main = Accounts.main;
    if (main is! LoginAccount) {
      final hadAccount = _projectedMain != null;
      _projectedMain = null;
      isLogin.value = false;
      if (hadAccount) {
        face.value = '';
        GlobalData().coins = null;
      }
      return;
    }
    final identity = AccountHealthIdentity.capture(main);
    final health = _health[identity];
    final accountChanged = _projectedMain != identity;
    _projectedMain = identity;

    final cookie = health?.cookie ?? CookieHealth.unknown;
    // 只有 cookie **明确有效**时才采用资料展示：失效/未知的响应体即便带着
    // face/uname（服务端在未登录时也会回一份占位资料），也不能显示成已登录。
    final cookieInfo = cookie == CookieHealth.valid ? health?.cookieInfo : null;
    final faceUrl = cookieInfo?.face;
    // 明确失效 = 该账号的凭证已经不能用了：清掉头像/余额。
    // 网络异常（unknown/checking）保留现值，别把用户「抖」成未登录。
    final confirmedInvalid = cookie == CookieHealth.invalid;
    face.value = faceUrl != null && faceUrl.isNotEmpty
        ? faceUrl
        : (accountChanged || confirmedInvalid ? '' : face.value);

    // 登录态：有效→true；明确失效→false；未知/校验中只有在**换了账号**时才
    // 取保守值（不能沿用上一个账号的登录态），同一账号则保留现值避免闪烁。
    final login = switch (cookie) {
      CookieHealth.valid => true,
      CookieHealth.invalid => false,
      _ => accountChanged ? false : isLogin.value,
    };
    if (isLogin.value == login) {
      // 账号身份变了但登录态恰好相同（valid A → valid B）时 Rx 不会通知，
      // AccountMixin（「我的」页等）就收不到信号、继续显示上一个账号的资料。
      if (accountChanged) isLogin.refresh();
    } else {
      isLogin.value = login;
    }

    // 金币随账号走：换了账号、或本账号已明确失效时清空；只有该账号自己拿到过
    // 有效 nav 才写入，旧账号/次要角色的过时结果不得改动它。
    if (accountChanged || confirmedInvalid) {
      GlobalData().coins = null;
    }
    final money = cookieInfo?.money;
    if (cookie == CookieHealth.valid && money != null) {
      GlobalData().coins = money;
    }
  }

  /// gRPC 明确返回鉴权失败（如 `code == -101`）时把该凭证标为失效。
  ///
  /// 同时递增该凭证的「明确拒绝」序号：已经开始、但结论更旧的 token 探针
  /// 不得把它覆盖回 valid（见 [_tokenRejectRevision]）。
  void markTokenInvalid(AccountHealthIdentity identity) {
    _tokenRejectRevision.update(
      identity,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    final current = _health[identity];
    if (current == null) return;
    _health[identity] = current.copyWith(token: TokenHealth.invalid);
    if (_isCurrentMain(identity)) {
      _projectMain();
    }
  }

  /// 测试专用：直接发布一份健康结果，避免为了造状态而发真实请求。
  @visibleForTesting
  void seedForTest(
    AccountHealthIdentity identity, {
    required CookieHealth cookie,
    required TokenHealth token,
    required AccountKind kind,
    UserInfoData? cookieInfo,
  }) {
    _health[identity] = AccountHealth(
      identity: identity,
      cookie: cookie,
      token: token,
      kind: kind,
      cookieInfo: cookieInfo,
      checkedAt: DateTime.now(),
      checking: false,
    );
    if (_isCurrentMain(identity)) {
      _projectMain();
    }
  }
}

/// 一次在飞的校验任务及其所属代际。
///
/// 代际随任务一起保存：复用判定必须比较「任务代际 == 当前代际」，
/// 而不是只比较「表里有没有记录」。
final class _HealthRun {
  const _HealthRun({required this.generation, required this.future});

  final int generation;
  final Future<AccountHealth> future;
}

mixin AccountMixin on GetLifeCycleBase {
  StreamSubscription<bool>? _listener;

  AccountService get accountService => Get.find<AccountService>();

  void onChangeAccount(bool isLogin);

  @override
  void onInit() {
    super.onInit();
    _listener = accountService.isLogin.listen(onChangeAccount);
  }

  @override
  void onClose() {
    _listener?.cancel();
    _listener = null;
    super.onClose();
  }
}
