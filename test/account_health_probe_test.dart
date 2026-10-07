import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 账号健康校验的生命周期回归（纯内存，无网络）。
///
/// 覆盖评审确认的真实故障：
/// - 重检/首次校验期间旧的 `valid / checkedAt` 仍对外可见；
/// - 畸形 cookie nav（缺 isLogin、mid 不符）被误判成「明确失效」或误判成有效；
/// - ABA（A→B→A）期间旧代际任务把过期结论写进新一轮；
/// - **重复/无关角色发布**（登录时会连续 set 7 个角色）作废仍被选中的在飞任务；
/// - 直接 `validate`（未经账号发布）因代际缺失而在第一步后静默终止；
/// - 非主角色（video/heartbeat/…）永远跑不完校验；
/// - 切换/登出后 `face` / `isLogin` / 金币仍停留在上一个账号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_health_probe_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    await GStorage.setting.put(
      SettingBoxKey.accountHealthRecheckIntervalHours,
      6,
    );
  });

  tearDown(() {
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
    GlobalData().coins = null;
    Get.reset();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  LoginAccount account({
    int mid = 7201,
    String? accessKey = 'ACCESS_KEY_7201',
  }) => LoginAccount(
    BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf_$mid',
      'SESSDATA': 'sess_$mid',
    }),
    accessKey,
    'REFRESH_$mid',
    null,
    IdentityCoreGenerators.deriveBuvidFromSeed('probe2-$mid'),
    AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
    'android',
  )..activated = true;

  void seed(Account value) =>
      Accounts.accountMode[AccountType.main.index] = value;

  AccountService service(_FakeProbe probe) =>
      AccountService()..debugSetProbe(probe);

  /// 一次成功校验所需的三个探针答复（cookie 有效 + token 有效 + 正式账号）。
  _FakeProbe healthyProbe() {
    final probe = _FakeProbe()..answerFromAccount = true;
    probe.navMoney = 12.5;
    probe.myInfoTourist = 0;
    return probe;
  }

  test('重检期间不再对外暴露 valid：checking 立刻发布，且不重复发请求', () async {
    final acc = account();
    seed(acc);
    final probe = healthyProbe();
    final svc = service(probe);
    final identity = AccountHealthIdentity.capture(acc);

    svc.seedForTest(
      identity,
      cookie: CookieHealth.valid,
      token: TokenHealth.valid,
      kind: AccountKind.formal,
    );
    expect(svc.healthFor(acc).canUseReplyGrpc, isTrue);

    final gate = Completer<void>();
    probe.gate = gate;
    final pending = svc.validate(acc, force: true);

    final during = svc.healthFor(acc);
    expect(during.token, TokenHealth.unknown);
    expect(during.kind, AccountKind.unknown);
    expect(during.checking, isTrue);
    expect(during.isChecking, isTrue);
    expect(during.canUseReplyGrpc, isFalse);
    expect(probe.cookieNavCalls, 1, reason: '并发调用只应发出一个在飞任务');

    gate.complete();
    final result = await pending;
    expect(result.cookie, CookieHealth.valid);
    expect(result.token, TokenHealth.valid);
    expect(result.kind, AccountKind.formal);
    expect(result.checking, isFalse);
    expect(result.checkedAt, isNotNull, reason: '只有完整跑完才写 checkedAt');
    expect(
      (probe.cookieNavCalls, probe.tokenNavCalls, probe.myInfoCalls),
      (1, 1, 1),
      reason: '一次完整校验 = nav + token-only nav + space/myinfo 各一次',
    );
    expect(svc.healthFor(acc).canUseReplyGrpc, isTrue);
  });

  test('完成前不写 checkedAt：卡在 cookie nav 时仍是 checking / 无时间戳', () async {
    final acc = account(mid: 7202);
    seed(acc);
    final probe = healthyProbe();
    final svc = service(probe);
    final gate = Completer<void>();
    probe.gate = gate;
    final pending = svc.validate(acc, force: true);

    expect(svc.healthFor(acc).checkedAt, isNull);
    expect(svc.healthFor(acc).checking, isTrue);
    expect(svc.healthFor(acc).kind, AccountKind.unknown);

    gate.complete();
    await pending;
    expect(svc.healthFor(acc).checkedAt, isNotNull);
    expect(svc.healthFor(acc).checking, isFalse);
  });

  test('token 步骤结束时仍是中间态（游客属性未查完不算校验完成）', () async {
    final acc = account(mid: 7221);
    seed(acc);
    final probe = healthyProbe();
    final svc = service(probe);
    final tokenGate = Completer<void>();
    probe.tokenEntered = Completer<void>();
    probe.tokenGate = tokenGate;

    final pending = svc.validate(acc, force: true);
    await probe.tokenEntered!.future;

    // token 已有结论，但 myinfo 还没查：不得宣告校验完成。
    final during = svc.healthFor(acc);
    expect(probe.tokenNavCalls, 1);
    expect(probe.myInfoCalls, 0);
    expect(during.checking, isTrue);
    expect(during.checkedAt, isNull);
    expect(during.canUseReplyGrpc, isFalse, reason: 'kind 还是 unknown');

    tokenGate.complete();
    final done = await pending;
    expect(done.checking, isFalse);
    expect(done.checkedAt, isNotNull);
    expect(
      (probe.cookieNavCalls, probe.tokenNavCalls, probe.myInfoCalls),
      (
        1,
        1,
        1,
      ),
    );
  });

  test('直接 validate（未经账号发布）：run generation 初始化，能完整跑完', () async {
    final acc = account(mid: 7203);
    final probe = healthyProbe();
    // 刻意不 seed / 不 onAccountsPublished：模拟页面或单测直接调用。
    final svc = service(probe);

    final health = await svc.validate(acc, force: true);

    expect(health.cookie, CookieHealth.valid);
    expect(health.token, TokenHealth.valid);
    expect(
      health.kind,
      AccountKind.formal,
      reason: '代际缺失会让任务在第一步之后就静默终止（永远停在 unknown）',
    );
    expect(health.checking, isFalse);
    expect(health.checkedAt, isNotNull);
    expect(
      (probe.cookieNavCalls, probe.tokenNavCalls, probe.myInfoCalls),
      (
        1,
        1,
        1,
      ),
    );
  });

  test('TTL 内重复发布：不重发请求、不回退 checking、checkedAt 不动', () async {
    final acc = account(mid: 7204);
    seed(acc);
    final probe = healthyProbe();
    final svc = service(probe);
    svc.enableValidation();
    svc.onAccountsPublished([acc], recheck: true);
    await svc.pendingFor(acc);
    final counts = (
      probe.cookieNavCalls,
      probe.tokenNavCalls,
      probe.myInfoCalls,
    );
    final checkedAt = svc.healthFor(acc).checkedAt;
    expect(svc.healthFor(acc).canUseReplyGrpc, isTrue);

    svc.onAccountsPublished([acc]);

    expect(svc.healthFor(acc).checking, isFalse);
    expect(svc.healthFor(acc).canUseReplyGrpc, isTrue);
    expect(svc.healthFor(acc).checkedAt, checkedAt);
    expect((
      probe.cookieNavCalls,
      probe.tokenNavCalls,
      probe.myInfoCalls,
    ), counts);
  });

  test('非主角色账号同样跑完校验（一次发布会校验全部角色）', () async {
    final main = account(mid: 7205);
    final video = account(mid: 7206);
    final probe = healthyProbe();
    final svc = service(probe);
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.video.index] = video;
    svc.enableValidation();

    svc.onAccountsPublished([main, video], recheck: true);
    await svc.pendingFor(main);
    await svc.pendingFor(video);

    expect(svc.healthFor(main).canUseReplyGrpc, isTrue);
    expect(
      svc.healthFor(video).canUseReplyGrpc,
      isTrue,
      reason: '非主角色不能被「必须是 main」的判定卡死',
    );
    expect(probe.cookieNavCalls, 2);
  });

  test('在飞期间重复/无关角色发布：同一凭证的任务不被作废', () async {
    final a = account(mid: 7207);
    final video = account(mid: 7208);
    final probe = _FakeProbe()
      ..answerFromAccount = true
      ..myInfoTourist = 0;
    final svc = service(probe);
    Accounts.accountMode[AccountType.main.index] = a;
    svc.enableValidation();

    final gate = Completer<void>();
    probe.gate = gate;
    svc.onAccountsPublished([a], recheck: true);
    final first = svc.pendingFor(a)!;
    expect(probe.cookieNavCalls, 1);

    // 登录/快速切号会连续发布多个角色（每次 Accounts.set 都会发布一次）。
    for (var i = 0; i < 7; i++) {
      svc.onAccountsPublished([a, video]);
    }

    expect(
      identical(svc.pendingFor(a), first),
      isTrue,
      reason: 'A 仍被选中且凭证未变：在飞任务必须继续有效',
    );
    expect(
      probe.cookieNavCalls,
      2,
      reason: '只允许新出现的 video 触发一次校验，A 不得被重开',
    );

    gate.complete();
    await first;
    expect(svc.healthFor(a).canUseReplyGrpc, isTrue);
    expect(svc.healthFor(a).checking, isFalse);
  });

  group('cookie nav 判定', () {
    test('缺 isLogin（mid 正确）→ unknown：不判失效、也不认成有效', () async {
      final acc = account(mid: 7209);
      seed(acc);
      final probe = healthyProbe()..navRaw = {'mid': acc.mid};
      final svc = service(probe);

      final health = await svc.validate(acc, force: true);
      expect(health.cookie, CookieHealth.unknown);
      expect(health.canUseReplyGrpc, isFalse);
      expect(Accounts.main.mid, acc.mid, reason: '未知绝不能注销账号');
    });

    test('mid 与发起校验的账号不一致 → unknown', () async {
      final acc = account(mid: 7210);
      seed(acc);
      final probe = healthyProbe()..navMidOverride = 999999;
      final svc = service(probe);

      final health = await svc.validate(acc, force: true);
      expect(health.cookie, CookieHealth.unknown);
      expect(health.canUseReplyGrpc, isFalse);
    });

    test('明确 isLogin=false 且无 mid → invalid（这才是明确失效）', () async {
      final acc = account(mid: 7211);
      seed(acc);
      final probe = _FakeProbe()..navIsLogin = false;
      final svc = service(probe);

      final health = await svc.validate(acc, force: true);
      expect(health.cookie, CookieHealth.invalid);
      expect(health.canUseReplyGrpc, isFalse);
      expect(Accounts.main.mid, acc.mid, reason: '失效也不删除账号');
    });

    test('-101 → invalid', () async {
      final acc = account(mid: 7212);
      seed(acc);
      final probe = _FakeProbe()..navCode = -101;
      final svc = service(probe);

      final health = await svc.validate(acc, force: true);
      expect(health.cookie, CookieHealth.invalid);
      expect(health.canUseReplyGrpc, isFalse);
    });

    test('UserInfoData.fromJson 保留 isLogin 缺失态（不再默认成 false）', () {
      expect(UserInfoData.fromJson({'mid': 1}).isLogin, isNull);
      expect(
        UserInfoData.fromJson({'isLogin': false, 'mid': 1}).isLogin,
        isFalse,
      );
      expect(
        UserInfoData.fromJson({'isLogin': true, 'mid': 1}).isLogin,
        isTrue,
      );
    });
  });

  test('同一账号复检遇到网络异常：三维 unknown、不回退 gRPC，但展示资料保留', () async {
    final acc = account(mid: 7231);
    seed(acc);
    final probe = healthyProbe();
    final svc = service(probe);
    svc.enableValidation();
    svc.onAccountsPublished([acc], recheck: true);
    await svc.pendingFor(acc);
    await Future<void>.delayed(Duration.zero);
    expect(svc.healthFor(acc).canUseReplyGrpc, isTrue);
    expect(svc.isLogin.value, isTrue);
    expect(svc.face.value, 'https://example.invalid/7231.png');
    expect(GlobalData().coins, 12.5);

    // 复检时断网：结论全部 unknown，但绝不注销账号 / 清空展示。
    probe.offline = true;
    await svc.validate(acc, force: true);
    await Future<void>.delayed(Duration.zero);

    final health = svc.healthFor(acc);
    expect(health.cookie, CookieHealth.unknown);
    expect(health.token, TokenHealth.unknown);
    expect(health.kind, AccountKind.unknown);
    expect(health.checking, isFalse, reason: '本轮必须正常收尾');
    expect(health.canUseReplyGrpc, isFalse, reason: 'unknown 不回退 gRPC');
    expect(svc.isLogin.value, isTrue, reason: '网络异常不得把用户踢成未登录');
    expect(svc.face.value, 'https://example.invalid/7231.png');
    expect(GlobalData().coins, 12.5, reason: 'unknown 保留余额');
    expect(Accounts.main.mid, acc.mid, reason: '不得注销账号');
  });

  test('token 探针在飞时收到明确拒绝：更晚的 invalid 胜出，且不得重开 gRPC', () async {
    final acc = account(mid: 7232);
    seed(acc);
    final probe = healthyProbe();
    final svc = service(probe);
    final identity = AccountHealthIdentity.capture(acc);
    svc.enableValidation();

    // 第一轮卡在 tokenNav（此时它会返回 valid）。
    probe.tokenEntered = Completer<void>();
    final tokenGate = Completer<void>();
    probe.tokenGate = tokenGate;
    svc.onAccountsPublished([acc], recheck: true);
    final run = svc.pendingFor(acc)!;
    await probe.tokenEntered!.future;

    // 在飞期间服务端明确拒绝（gRPC -101 → markTokenInvalid）。
    svc.markTokenInvalid(identity);
    expect(svc.healthFor(acc).token, TokenHealth.invalid);

    tokenGate.complete();
    await run;
    await Future<void>.delayed(Duration.zero);

    final health = svc.healthFor(acc);
    expect(
      health.token,
      TokenHealth.invalid,
      reason: '发起更早的 token 结论不得覆盖更晚的明确拒绝',
    );
    expect(health.canUseReplyGrpc, isFalse, reason: '不得因旧的 valid 重开 gRPC');
    expect(
      health.checking,
      isFalse,
      reason: '本轮照常收尾（不能永远停在 checking）',
    );
    expect(health.checkedAt, isNotNull);
    expect(health.kind, AccountKind.formal, reason: '其余维度照常完成');
    expect(health.cookie, CookieHealth.valid);

    // 后续**新的**生命周期校验可以重新验证（不永久锁 invalid）。
    await svc.validate(acc, force: true);
    expect(svc.healthFor(acc).token, TokenHealth.valid);
    expect(svc.healthFor(acc).canUseReplyGrpc, isTrue);
  });

  test('主账号切换后立刻投影：不保留上一个账号的头像 / 登录态 / 金币', () async {
    final first = account(mid: 7213);
    final probe = healthyProbe();
    final svc = service(probe);
    seed(first);
    svc.enableValidation();
    svc.onAccountsPublished([first], recheck: true);
    await svc.pendingFor(first);
    await Future<void>.delayed(Duration.zero);
    expect(svc.isLogin.value, isTrue);
    expect(svc.face.value, 'https://example.invalid/7213.png');
    expect(GlobalData().coins, 12.5);

    // 第二个账号的校验卡住不返回：切换瞬间的投影是「还没校验完」，
    // 必须立刻清掉上一个账号的展示，而不是等它跑完后再看结果。
    final second = account(mid: 7214);
    final gate = Completer<void>();
    probe.gate = gate;
    probe.gateMid = second.mid;
    probe.navEntered = Completer<void>();
    seed(second);
    svc.onAccountsPublished([first, second]);
    await probe.navEntered!.future;

    expect(svc.healthFor(second).checking, isTrue);
    expect(svc.isLogin.value, isFalse, reason: '不得沿用上一个账号的登录态');
    expect(svc.face.value, '', reason: '不得沿用上一个账号的头像');
    expect(GlobalData().coins, isNull, reason: '不得沿用上一个账号的余额');

    // 放行后必须真的切换到第二个账号的资料（不是宽泛的 isBool 断言）。
    probe.gate = null;
    gate.complete();
    await svc.pendingFor(second);
    await Future<void>.delayed(Duration.zero);
    expect(svc.isLogin.value, isTrue);
    expect(svc.face.value, 'https://example.invalid/7214.png');
    expect(GlobalData().coins, 12.5);
  });

  test('主账号登出（匿名）：登录态 / 头像 / 金币一并清理', () async {
    final acc = account(mid: 7215);
    final probe = healthyProbe();
    final svc = service(probe);
    seed(acc);
    svc.enableValidation();
    svc.onAccountsPublished([acc], recheck: true);
    await svc.pendingFor(acc);
    await Future<void>.delayed(Duration.zero);
    expect(svc.isLogin.value, isTrue);
    expect(GlobalData().coins, 12.5);

    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    svc.onAccountsPublished(const []);

    expect(svc.isLogin.value, isFalse);
    expect(svc.face.value, '');
    expect(GlobalData().coins, isNull);
  });

  test('同 mid 换 key 即换凭证：旧结果失效、新凭证重新校验', () async {
    final old = account(mid: 7216, accessKey: 'OLD_KEY');
    final fresh = account(mid: 7216, accessKey: 'NEW_KEY');
    final probe = healthyProbe();
    final svc = service(probe);
    seed(old);
    svc.enableValidation();
    svc.onAccountsPublished([old], recheck: true);
    await svc.pendingFor(old);
    expect(svc.healthFor(old).canUseReplyGrpc, isTrue);

    seed(fresh);
    svc.onAccountsPublished([fresh], recheck: true);
    await svc.pendingFor(fresh);
    await Future<void>.delayed(Duration.zero);
    expect(svc.healthFor(fresh).canUseReplyGrpc, isTrue);
    expect(
      svc.healthFor(old).checkedAt,
      isNull,
      reason: '旧凭证的行已被清理，不得残留结果',
    );
  });

  test('ABA：A→B→A 期间旧任务作废，新代际重开一轮并收敛', () async {
    final a = account(mid: 7217);
    final b = account(mid: 7218);
    final probe = _FakeProbe()
      ..answerFromAccount = true
      ..myInfoTourist = 0;
    final svc = service(probe);
    seed(a);
    svc.enableValidation();

    final gate1 = Completer<void>();
    probe.gate = gate1;
    svc.onAccountsPublished([a], recheck: true);
    final oldTask = svc.pendingFor(a)!;
    expect(probe.cookieNavCalls, 1);

    // A → B：A 的行与代际被清理；B 自己跑完。
    probe.gate = null;
    seed(b);
    svc.onAccountsPublished([b], recheck: true);
    await svc.pendingFor(b);

    // 第二轮 A：必须重开任务，而不是复用过期代际的任务。
    final gate2 = Completer<void>();
    probe.gate = gate2;
    seed(a);
    svc.onAccountsPublished([a], recheck: true);
    expect(
      probe.cookieNavCalls,
      3,
      reason: 'A 的第二轮必须真的重新发起（1=A、2=B、3=A 第二轮）',
    );

    // 放行旧任务：它属于旧代际，不得写回。
    probe.gate = null;
    gate1.complete();
    await oldTask;
    expect(svc.healthFor(a).canUseReplyGrpc, isFalse);
    expect(svc.healthFor(a).checking, isTrue);

    gate2.complete();
    await svc.pendingFor(a);
    await Future<void>.delayed(Duration.zero);
    final health = svc.healthFor(a);
    expect(
      health.canUseReplyGrpc,
      isTrue,
      reason: 'ABA 之后新一轮必须真的跑完并写回，不能永远停在 unknown',
    );
    expect(health.checking, isFalse);
    expect(health.identity, AccountHealthIdentity.capture(a));
  });

  test('凭证离开选中集合：旧任务完成时绝不发布结果', () async {
    final a = account(mid: 7219);
    final probe = healthyProbe();
    final svc = service(probe);
    seed(a);
    svc.enableValidation();
    final gate = Completer<void>();
    probe.gate = gate;
    svc.onAccountsPublished([a], recheck: true);
    final task = svc.pendingFor(a)!;

    final b = account(mid: 7220);
    seed(b);
    svc.onAccountsPublished([b]);

    gate.complete();
    await task;
    expect(svc.healthFor(a).checkedAt, isNull, reason: '过时结论不得写回');
  });
}

/// 可完全离线操控的探针；只记录调用次数，不发任何请求。
class _FakeProbe implements AccountHealthProbe {
  int cookieNavCalls = 0;
  int tokenNavCalls = 0;
  int myInfoCalls = 0;
  Completer<void>? gate;

  /// 门控只对指定 mid 生效（null = 全部），用于「只卡住新切换进来的账号」。
  int? gateMid;

  /// 进入 cookie nav 的信号（同样受 [gateMid] 约束）。
  Completer<void>? navEntered;

  /// 进入 token 步骤的信号 + 该步骤的门控（用于观察中间态）。
  Completer<void>? tokenEntered;
  Completer<void>? tokenGate;

  /// 三个探针都按传入账号作答（用于多账号/多角色用例）。
  bool answerFromAccount = false;

  /// 模拟断网：cookie/ token / myinfo 全部返回「未知」。
  bool offline = false;

  int? navCode;
  bool? navIsLogin;
  int? navMidOverride;
  double? navMoney;
  Map<String, dynamic>? navRaw;

  bool? tokenIsLogin;
  int? tokenMid;

  int? myInfoMid;
  int? myInfoTourist;

  bool _gateApplies(LoginAccount account) =>
      gateMid == null || gateMid == account.mid;

  @override
  Future<({UserInfoData? info, int? code})> cookieNav(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async {
    cookieNavCalls++;
    if (_gateApplies(account)) {
      final entered = navEntered;
      if (entered != null && !entered.isCompleted) entered.complete();
      if (gate != null) await gate!.future;
    }
    // 断网：cookie 会话也是「未知」，不是「明确失效」。
    if (offline) return (info: null, code: null);
    final code = navCode;
    if (code != null && code != 0) {
      return (info: null, code: code);
    }
    // `navRaw` 直接喂给模型：用于构造「字段缺失」的畸形响应。
    if (navRaw case final raw?) {
      return (info: UserInfoData.fromJson(raw), code: 0);
    }
    final mid = navMidOverride ?? (answerFromAccount ? account.mid : null);
    final isLogin = answerFromAccount ? true : navIsLogin;
    return (
      info: UserInfoData.fromJson({
        'isLogin': isLogin,
        'mid': mid,
        'uname': 'tester',
        'face': 'https://example.invalid/${account.mid}.png',
        'money': navMoney,
      }),
      code: 0,
    );
  }

  @override
  Future<Map<String, dynamic>?> tokenNav(
    LoginAccount account,
    AccountHealthIdentity identity,
    String accessKey,
  ) async {
    tokenNavCalls++;
    final entered = tokenEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    if (tokenGate != null) await tokenGate!.future;
    if (offline) return null;
    return {
      'code': 0,
      'data': {
        'isLogin': answerFromAccount ? true : tokenIsLogin,
        'mid': answerFromAccount ? account.mid : tokenMid,
      },
    };
  }

  @override
  Future<Map<String, dynamic>?> spaceMyInfo(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async {
    myInfoCalls++;
    if (offline) return null;
    return {
      'code': 0,
      'data': {
        'mid': answerFromAccount ? account.mid : myInfoMid,
        'is_tourist': myInfoTourist,
      },
    };
  }
}
