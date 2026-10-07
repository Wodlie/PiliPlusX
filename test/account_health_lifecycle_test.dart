import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 账号健康校验：cookie / access token / 游客三种状态各自独立，
/// 且校验请求真的隔离了 cookie（否则「cookie 有效 + token 失效」会被洗成有效）。
///
/// 全部用内存 adapter，不发任何真实请求。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _ProbeAdapter adapter;
  late HttpClientAdapter originalAdapter;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_account_health_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    Request();
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    Request.dio.interceptors.removeWhere((entry) => entry is LogInterceptor);
    // 保留原 adapter：`Request.dio` 是全局单例，跑整个 test/ 目录时若不还原，
    // 后续测试文件会被这个内存 adapter 拦下。
    originalAdapter = Request.dio.httpClientAdapter;
    adapter = _ProbeAdapter();
    Request.dio.httpClientAdapter = adapter;
  });

  setUp(() async {
    adapter.reset();
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
  });

  tearDown(() async {
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
    await GStorage.setting.clear();
    Get.reset();
  });

  tearDownAll(() async {
    Request.dio.httpClientAdapter = originalAdapter;
    await GStorage.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  LoginAccount account({
    int mid = 7001,
    String? accessKey = 'ACCESS_KEY_7001',
  }) => LoginAccount(
    BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf_$mid',
      'SESSDATA': 'sess_$mid',
    }),
    accessKey,
    'REFRESH_$mid',
    null,
    IdentityCoreGenerators.deriveBuvidFromSeed('health-$mid'),
    AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
    'android',
  )..activated = true;

  void seed(LoginAccount value) {
    Accounts.accountMode[AccountType.main.index] = value;
  }

  AccountService service() {
    final existing = Get.isRegistered<AccountService>()
        ? Get.find<AccountService>()
        : Get.put(AccountService());
    existing.enableValidation();
    return existing;
  }

  /// 一次完整校验挂起，直到测试放行 —— 用于验证 cookie 隔离与并发复用。
  Future<AccountHealth> startValidation(AccountService svc, LoginAccount acc) =>
      svc.validate(acc, force: true);

  test('游客账号不校验、不发请求，直接判为 REST', () async {
    final svc = AccountService();
    svc.enableValidation();
    final guest = AnonymousAccount();
    final health = await svc.validate(guest, force: true);

    expect(adapter.requests, isEmpty);
    expect(health.token, TokenHealth.missing);
    expect(health.kind, AccountKind.anonymous);
    expect(health.canUseReplyGrpc, isFalse);
  });

  test('token-only 校验不带 cookie；cookie 有效不能把失效 token 洗成有效', () async {
    final acc = account();
    seed(acc);
    adapter.onNav = (tokenOnly) => tokenOnly
        // 隔离 cookie 时服务端如实回 -101：该 key 未通过认证。
        ? {'code': -101, 'message': '账号未登录', 'data': null}
        : {
            'code': 0,
            'data': {'isLogin': true, 'mid': acc.mid, 'uname': 'tester'},
          };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid, 'is_tourist': 0},
    };

    final svc = service();
    final health = await startValidation(svc, acc);

    final navRequests = adapter.requests
        .where((r) => r.path == '/x/web-interface/nav')
        .toList();
    expect(navRequests.length, 2, reason: '应先 cookie nav，再 token-only nav');
    expect(navRequests.first.tokenOnly, isFalse);
    expect(navRequests.last.tokenOnly, isTrue);
    // 关键：token-only 请求不得携带任何 cookie（大小写都不行）。
    expect(navRequests.last.cookieHeader, isNull);
    expect(navRequests.first.cookieHeader, isNotNull);

    expect(health.cookie, CookieHealth.valid);
    expect(health.token, TokenHealth.invalid);
    expect(health.canUseReplyGrpc, isFalse, reason: '失效 token 必须回退 REST');
  });

  test('有效正式账号：token 有效 + is_tourist=0 → 可走 gRPC', () async {
    final acc = account(mid: 7002, accessKey: 'ACCESS_KEY_7002');
    seed(acc);
    adapter.onNav = (tokenOnly) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': acc.mid, 'uname': 'tester'},
    };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid, 'is_tourist': 0},
    };

    final svc = service();
    final health = await startValidation(svc, acc);

    expect(health.cookie, CookieHealth.valid);
    expect(health.token, TokenHealth.valid);
    expect(health.kind, AccountKind.formal);
    expect(health.canUseReplyGrpc, isTrue);
  });

  test('游客 token（is_tourist=1）即使 token 有效也不走 gRPC', () async {
    final acc = account(mid: 7003, accessKey: 'ACCESS_KEY_7003');
    seed(acc);
    adapter.onNav = (_) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': acc.mid},
    };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid, 'is_tourist': 1},
    };

    final svc = service();
    final health = await startValidation(svc, acc);

    expect(health.token, TokenHealth.valid);
    expect(health.kind, AccountKind.tourist);
    expect(health.canUseReplyGrpc, isFalse);
  });

  test('游客属性字段缺失或 mid 不符 → unknown（保守 REST，不猜正式账号）', () async {
    final acc = account(mid: 7004, accessKey: 'ACCESS_KEY_7004');
    seed(acc);
    adapter.onNav = (_) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': acc.mid},
    };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid}, // 缺 is_tourist
    };

    final svc = service();
    var health = await startValidation(svc, acc);
    expect(health.kind, AccountKind.unknown);
    expect(health.canUseReplyGrpc, isFalse);

    // mid 不符同样只是 unknown（不把别人判成自己）。
    svc.onAccountsPublished([acc], recheck: true);
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': 999999, 'is_tourist': 0},
    };
    health = await svc.validate(acc, force: true);
    expect(health.kind, AccountKind.unknown);
  });

  test('无 access token 的 cookie-only 账号：token=missing，仍可判定游客属性', () async {
    final acc = account(mid: 7005, accessKey: null);
    seed(acc);
    adapter.onNav = (_) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': acc.mid},
    };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid, 'is_tourist': 0},
    };

    final svc = service();
    final health = await startValidation(svc, acc);

    expect(health.cookie, CookieHealth.valid);
    expect(health.token, TokenHealth.missing);
    expect(health.kind, AccountKind.formal);
    expect(health.canUseReplyGrpc, isFalse, reason: '无 token 必须回退 REST');
    // 不含 token 的校验不应发 token-only 请求。
    expect(
      adapter.requests.every(
        (r) => r.path != '/x/web-interface/nav' || !r.tokenOnly,
      ),
      isTrue,
    );
  });

  test('网络异常 → unknown，不标过期、不删账号', () async {
    final acc = account(mid: 7006, accessKey: 'ACCESS_KEY_7006');
    seed(acc);
    adapter.failAll = true;

    final svc = service();
    final health = await startValidation(svc, acc);

    expect(health.cookie, CookieHealth.unknown);
    expect(health.token, TokenHealth.unknown);
    expect(health.canUseReplyGrpc, isFalse);
    expect(Accounts.account, isNotNull);
    expect(Accounts.main.mid, acc.mid, reason: '校验失败不得注销账号');
  });

  test('同一凭证并发校验只发一轮请求（single-flight）', () async {
    final acc = account(mid: 7007, accessKey: 'ACCESS_KEY_7007');
    seed(acc);
    final gate = Completer<void>();
    adapter.onNav = (_) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': acc.mid},
    };
    adapter.gate = gate;
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid, 'is_tourist': 0},
    };

    final svc = service();
    final first = svc.validate(acc, force: true);
    final second = svc.validate(acc, force: true);
    gate.complete();
    await Future.wait([first, second]);

    expect(
      adapter.requests.where((r) => r.tokenOnly).length,
      1,
      reason: 'token-only 请求不应重复',
    );
    expect(
      adapter.requests.where((r) => r.path == '/x/space/myinfo').length,
      1,
    );
  });

  test('校验期间换账号/换 key：旧结果不写入新凭证', () async {
    final old = account(mid: 7008, accessKey: 'OLD_KEY');
    final fresh = account(mid: 7008, accessKey: 'NEW_KEY');
    seed(old);
    adapter.onNav = (_) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': old.mid},
    };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': old.mid, 'is_tourist': 0},
    };

    final svc = service();
    await svc.validate(old, force: true);
    expect(svc.healthFor(old).canUseReplyGrpc, isTrue);

    // 同 mid 换 key：新凭证必须重新校验，绝不继承旧凭证的 valid/formal。
    final gate = Completer<void>();
    adapter.gate = gate;
    seed(fresh);

    final freshHealth = svc.healthFor(fresh);
    expect(freshHealth.identity, AccountHealthIdentity.capture(fresh));
    expect(
      freshHealth.cookie,
      CookieHealth.unknown,
      reason: '不能复用旧凭证的 cookie 结论',
    );
    expect(freshHealth.token, TokenHealth.unknown);
    expect(freshHealth.checking, isTrue);
    expect(freshHealth.canUseReplyGrpc, isFalse);

    gate.complete();
    await svc.pendingFor(fresh);
    expect(svc.healthFor(fresh).canUseReplyGrpc, isTrue);
    expect(
      svc.healthFor(old).checkedAt,
      isNull,
      reason: '旧凭证的行已被清理，结果不得残留',
    );
  });

  test('账号发布触发校验；未启用校验时不发请求', () async {
    final acc = account(mid: 7009, accessKey: 'ACCESS_KEY_7009');
    adapter.onNav = (_) => {
      'code': 0,
      'data': {'isLogin': true, 'mid': acc.mid},
    };
    adapter.onMyInfo = () => {
      'code': 0,
      'data': {'mid': acc.mid, 'is_tourist': 0},
    };

    // 未注册服务/未启用：只发布未知状态。
    final svc = AccountService();
    svc.onAccountsPublished([acc]);
    expect(adapter.requests, isEmpty);
    expect(svc.healthFor(acc).cookie, CookieHealth.unknown);

    // 启用后由生命周期发布触发。
    Get.put<AccountService>(svc);
    svc.enableValidation();
    svc.onAccountsPublished([acc], recheck: true);
    await Future<void>.delayed(Duration.zero);
    await svc.validate(acc);
    expect(adapter.requests, isNotEmpty);
  });
}

/// 只记录请求、按测试给定的规则作答；绝不访问网络。
class _ProbeAdapter implements HttpClientAdapter {
  final requests = <_ProbeRequest>[];
  bool failAll = false;
  Completer<void>? gate;
  Map<String, dynamic> Function(bool tokenOnly)? onNav;
  Map<String, dynamic> Function()? onMyInfo;

  void reset() {
    requests.clear();
    failAll = false;
    gate = null;
    onNav = null;
    onMyInfo = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final isNav = path == '/x/web-interface/nav';
    final isMyInfo = path == '/x/space/myinfo';
    requests.add(
      _ProbeRequest(
        path: path,
        tokenOnly: options.extra[AccountManager.tokenOnlyExtra] == true,
        cookieHeader: options.headers['cookie'] ?? options.headers['Cookie'],
        query: Map<String, dynamic>.from(options.queryParameters),
      ),
    );
    if (failAll) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    if (gate != null) await gate!.future;

    final Map<String, dynamic>? body = isNav
        ? onNav?.call(options.extra[AccountManager.tokenOnlyExtra] == true)
        : isMyInfo
        ? onMyInfo?.call()
        : null;
    return ResponseBody.fromString(
      jsonEncode(body ?? {'code': -404, 'message': 'unexpected'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ProbeRequest {
  const _ProbeRequest({
    required this.path,
    required this.tokenOnly,
    required this.cookieHeader,
    required this.query,
  });

  final String path;
  final bool tokenOnly;
  final String? cookieHeader;
  final Map<String, dynamic> query;
}
