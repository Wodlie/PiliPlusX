import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 「我的」页面的账号状态回归：
/// - cookie 明确失效（`-101` / 显式 `isLogin=false`）时必须显示未登录，
///   既不误报登录，也不删除存储账号；
/// - 非空但自相矛盾的资料（有 face/uname、`isLogin=false`）不得被当成已登录
///   （旧实现只看 `cookieResult` 非空就把 `isLogin` 置真）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _PendingTracker tracker;
  late _MineAdapter adapter;
  late HttpClientAdapter originalAdapter;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_mine_state_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    Request();
    // 追踪器挂在最前面：它能看到整条请求链路的开始与结束（adapter 只覆盖
    // 发起到响应返回的瞬间，Dio 的拦截器队列在后面还会继续跑）。
    tracker = _PendingTracker();
    Request.dio.interceptors.add(tracker);
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    Request.dio.interceptors.removeWhere(
      (entry) => entry.runtimeType.toString().contains('LogInterceptor'),
    );
    originalAdapter = Request.dio.httpClientAdapter;
    adapter = _MineAdapter(tracker);
    Request.dio.httpClientAdapter = adapter;
  });

  setUp(() async {
    adapter.reset();
    // onInit 会读 userInfoCache：清空它，保证用例只走我们显式调用的路径。
    await GStorage.userInfo.clear();
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
  });

  tearDown(() async {
    // 先把 fire-and-forget 的请求等干净，再释放控制器/关闭 Hive。
    await adapter.settle();
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
    GlobalData().coins = null;
    Get.reset();
    // reset 期间监听器可能又触发请求：收尾再等一次。
    await adapter.settle();
  });

  tearDownAll(() async {
    await adapter.settle();
    Request.dio.httpClientAdapter = originalAdapter;
    await GStorage.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  LoginAccount account({int mid = 7401}) => LoginAccount(
    BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf_$mid',
      'SESSDATA': 'sess_$mid',
    }),
    'ACCESS_KEY_$mid',
    'REFRESH_$mid',
    null,
    IdentityCoreGenerators.deriveBuvidFromSeed('mine-$mid'),
    AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
    'android',
  )..activated = true;

  /// 真实 MineController + 未注册的假探针：页面只消费已发布状态。
  Future<({MineController mine, AccountService service})> boot(
    LoginAccount acc,
    _MineProbe probe,
  ) async {
    Accounts.accountMode[AccountType.main.index] = acc;
    final service = AccountService()
      ..debugSetProbe(probe)
      ..enableValidation();
    Get.put<AccountService>(service);
    service.onAccountsPublished([acc], recheck: true);
    await service.pendingFor(acc);
    await Future<void>.delayed(Duration.zero);
    final mine = Get.put<MineController>(MineController());
    await mine.queryUserInfo();
    return (mine: mine, service: service);
  }

  test('cookie 明确失效（-101）：显示登出、不删账号、不误报登录', () async {
    final acc = account();
    final probe = _MineProbe()..navCode = -101;

    final result = await boot(acc, probe);

    expect(result.service.healthFor(acc).cookie, CookieHealth.invalid);
    expect(result.service.isLogin.value, isFalse);
    expect(result.mine.userInfo.value.mid, isNull);
    expect(result.mine.userInfo.value.isLogin, isNot(true));
    expect(
      Accounts.main.mid,
      acc.mid,
      reason: 'cookie 失效只改展示态，绝不删除存储账号',
    );
    await adapter.settle();
    expect(
      adapter.paths,
      isNot(contains('/x/web-interface/nav/stat')),
      reason: '明确失效时不发统计请求（必然 401，没有意义）',
    );
  });

  test('nav 非空但 isLogin=false：不得显示成已登录，也不采用其资料', () async {
    final acc = account(mid: 7402);
    final probe = _MineProbe()
      ..navInfo = {'isLogin': false, 'uname': 'ghost', 'face': 'x'};

    final result = await boot(acc, probe);

    expect(result.service.healthFor(acc).cookie, CookieHealth.invalid);
    expect(result.service.isLogin.value, isFalse);
    expect(
      result.mine.userInfo.value.uname,
      isNull,
      reason: '失效响应里的占用资料不得被采用',
    );
    expect(result.service.face.value, isEmpty);
    expect(Accounts.main.mid, acc.mid);
    await adapter.settle();
    expect(adapter.paths, isNot(contains('/x/web-interface/nav/stat')));
  });

  test('cookie 有效：资料被采用且显示登录', () async {
    final acc = account(mid: 7403);
    final probe = _MineProbe()
      ..navInfo = {
        'isLogin': true,
        'mid': 7403,
        'uname': 'real',
        'face': 'https://example.invalid/7403.png',
        'money': 3,
      }
      ..myInfoTourist = 0;

    final result = await boot(acc, probe);

    expect(result.service.healthFor(acc).cookie, CookieHealth.valid);
    expect(result.service.isLogin.value, isTrue);
    expect(result.mine.userInfo.value.uname, 'real');
    expect(result.service.face.value, 'https://example.invalid/7403.png');
    await adapter.settle();
    expect(
      adapter.paths,
      contains('/x/web-interface/nav/stat'),
      reason: '有效账号的正常流程包含统计请求',
    );
  });

  test('缓存里两个账号都 valid：切换后必须通知并换成新账号资料', () async {
    // 两个账号都已有「有效」缓存结果：登录态前后都是 true，Rx 值不变，
    // 若投影时不显式 refresh，AccountMixin/「我的」页就收不到信号、
    // 会一直显示上一个账号的资料。
    final a = account(mid: 7404);
    final b = account(mid: 7405);
    final service = AccountService();
    Get.put<AccountService>(service);
    // 两个角色都指向这两个账号：任何一次 `_publish` 的选中集合都含 a+b，
    // 否则先赋 main 会把还没赋角色的 b 从健康表里清掉。
    Accounts.accountMode[AccountType.main.index] = a;
    Accounts.accountMode[AccountType.video.index] = b;
    service
      ..seedForTest(
        AccountHealthIdentity.capture(a),
        cookie: CookieHealth.valid,
        token: TokenHealth.valid,
        kind: AccountKind.formal,
        cookieInfo: UserInfoData.fromJson({
          'isLogin': true,
          'mid': 7404,
          'uname': 'alpha',
          'face': 'https://example.invalid/alpha.png',
          'money': 1,
        }),
      )
      ..seedForTest(
        AccountHealthIdentity.capture(b),
        cookie: CookieHealth.valid,
        token: TokenHealth.valid,
        kind: AccountKind.formal,
        cookieInfo: UserInfoData.fromJson({
          'isLogin': true,
          'mid': 7405,
          'uname': 'beta',
          'face': 'https://example.invalid/beta.png',
          'money': 2,
        }),
      );

    service.onAccountsPublished([a, b]);
    var notifications = 0;
    final sub = service.isLogin.listen((_) => notifications++);
    addTearDown(sub.cancel);
    final mine = Get.put<MineController>(MineController());
    await mine.queryUserInfo();
    expect(mine.userInfo.value.uname, 'alpha');
    expect(service.face.value, 'https://example.invalid/alpha.png');

    // 切到 B：登录态仍是 true，但身份变了，必须仍然发出通知。
    Accounts.accountMode[AccountType.main.index] = b;
    service.onAccountsPublished([a, b]);
    expect(
      notifications,
      greaterThan(0),
      reason: 'valid A → valid B 时 isLogin 值不变，必须显式 refresh 通知',
    );

    // 通知驱动 AccountMixin → MineController.onRefresh → queryUserInfo。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // 等所有 fire-and-forget 的 stats/fav 请求落地，再关 Hive 才安全。
    await adapter.settle();
    expect(
      mine.userInfo.value.uname,
      'beta',
      reason: '不得继续显示上一个账号的资料',
    );
    expect(service.face.value, 'https://example.invalid/beta.png');
    expect(GlobalData().coins, 2, reason: '余额随账号切换');
  });
}

/// 只记录请求路径，全部返回空成功；绝不访问网络。
///
/// [settle] 委托给拦截器级追踪器：`MineController` 的部分请求是
/// fire-and-forget（fav / stats），必须等**整条链路**结束再关 Hive。
class _MineAdapter implements HttpClientAdapter {
  _MineAdapter(this._tracker);

  final _PendingTracker _tracker;
  final paths = <String>[];

  void reset() => paths.clear();

  /// 等到没有在飞请求（拦截器级计数，覆盖 Dio 的队列而不只是 adapter）。
  Future<void> settle() => _tracker.settle();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    return ResponseBody.fromString(
      jsonEncode({'code': 0, 'data': {}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 用拦截器追踪「整条请求链路」的完成情况。
///
/// adapter 的 `fetch` 只覆盖发起到响应返回的瞬间：cookie 保存、重试、
/// 错误处理等拦截器工作还在后面。直接关 Hive 就会看到未完成的请求。
/// 每个请求用 `extra` 标记，保证 `onError`（可能由更早的拦截器 reject 触发、
/// 而 `onRequest` 没跑过）不会把计数减成负数。
class _PendingTracker extends Interceptor {
  static const _flag = 'test.pendingTracked';

  int _pending = 0;
  int get pending => _pending;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_flag] = true;
    _pending++;
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _complete(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _complete(err.requestOptions);
    handler.next(err);
  }

  void _complete(RequestOptions options) {
    if (options.extra[_flag] == true) {
      options.extra[_flag] = false;
      _pending--;
    }
  }

  /// 等到没有在飞请求：至少让出若干轮再判定，避免「刚好为 0」的假稳定，
  /// 也给刚被触发、尚未进入拦截器的请求留出启动时间。
  Future<void> settle() async {
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(Duration.zero);
      if (i >= 10 && _pending == 0) return;
    }
  }
}

/// 可完全离线操控的探针。
class _MineProbe implements AccountHealthProbe {
  int? navCode;
  Map<String, dynamic>? navInfo;
  int? myInfoTourist = 0;

  @override
  Future<({UserInfoData? info, int? code})> cookieNav(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async {
    final code = navCode;
    if (code != null && code != 0) return (info: null, code: code);
    final info = navInfo;
    return (
      info: info == null ? null : UserInfoData.fromJson(info),
      code: info == null ? -101 : 0,
    );
  }

  @override
  Future<Map<String, dynamic>?> tokenNav(
    LoginAccount account,
    AccountHealthIdentity identity,
    String accessKey,
  ) async => {
    'code': 0,
    'data': {'isLogin': true, 'mid': account.mid},
  };

  @override
  Future<Map<String, dynamic>?> spaceMyInfo(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async => {
    'code': 0,
    'data': {'mid': account.mid, 'is_tourist': myInfoTourist},
  };
}
