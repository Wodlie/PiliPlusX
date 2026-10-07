import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/common/account_type.dart';
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

/// 校验请求的凭证隔离：
/// - token-only 必须不带任何大小写形式的 cookie；
/// - 校验响应不得把 Set-Cookie 写回账号 jar；
/// - 发起校验的凭证若已被替换，请求必须取消（不能用旧 key 发送）；
/// - 普通请求的 cookie 注入行为完全不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _AuthAdapter adapter;
  late HttpClientAdapter originalAdapter;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_auth_probe_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    Request();
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    Request.dio.interceptors.removeWhere((entry) => entry is LogInterceptor);
    // `Request.dio` 是全局单例：保留并还原原 adapter，避免影响同进程的后续测试。
    originalAdapter = Request.dio.httpClientAdapter;
    adapter = _AuthAdapter();
    Request.dio.httpClientAdapter = adapter;
  });

  setUp(() => adapter.reset());

  tearDown(() {
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
    Get.reset();
  });

  tearDownAll(() async {
    Request.dio.httpClientAdapter = originalAdapter;
    await GStorage.close();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  LoginAccount account({int mid = 9001, String key = 'ACCESS_KEY'}) =>
      LoginAccount(
        BiliCookieJar.fromJson({
          'DedeUserID': '$mid',
          'bili_jct': 'csrf_$mid',
          'SESSDATA': 'sess_$mid',
        }),
        key,
        'REFRESH',
        null,
        IdentityCoreGenerators.deriveBuvidFromSeed('probe-$mid'),
        AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
        'android',
      )..activated = true;

  test('token-only 不带 cookie，且 Set-Cookie 不写回 jar', () async {
    final acc = account();
    Accounts.accountMode[AccountType.main.index] = acc;
    final identity = AccountHealthIdentity.capture(acc);
    adapter.setCookies = ['SESSDATA=ROTATED; Path=/; Domain=.bilibili.com'];

    await UserHttp.tokenOnlyUserInfo(
      account: acc,
      expectedIdentity: identity,
      accessKey: acc.accessKey!,
    );

    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.tokenOnly, isTrue);
    expect(request.cookieHeader, isNull, reason: 'token-only 必须零 cookie');
    expect(request.query['access_key'], 'ACCESS_KEY');
    // 校验不能顺手轮换凭证。
    expect(acc.cookieJar.toJson()['SESSDATA'], 'sess_9001');
  });

  test('cookie 检测仍带账号 cookie，但同样不写回 Set-Cookie', () async {
    final acc = account(mid: 9002);
    Accounts.accountMode[AccountType.main.index] = acc;
    final identity = AccountHealthIdentity.capture(acc);
    adapter.setCookies = ['SESSDATA=ROTATED; Path=/; Domain=.bilibili.com'];

    await UserHttp.spaceMyInfo(account: acc, expectedIdentity: identity);

    expect(adapter.requests.single.tokenOnly, isFalse);
    expect(
      adapter.requests.single.cookieHeader,
      contains('SESSDATA=sess_9002'),
    );
    expect(acc.cookieJar.toJson()['SESSDATA'], 'sess_9002');
  });

  test('发起校验的凭证被替换后，请求被取消（不拿旧 key 发送）', () async {
    final old = account(mid: 9003, key: 'OLD_KEY');
    final identity = AccountHealthIdentity.capture(old);
    // 同 mid 换 key：当前选中账号已经不是发起校验时的那个凭证。
    final fresh = account(mid: 9003, key: 'NEW_KEY');
    Accounts.accountMode[AccountType.main.index] = fresh;

    final data = await UserHttp.tokenOnlyUserInfo(
      account: fresh,
      expectedIdentity: identity,
      accessKey: 'OLD_KEY',
    );

    expect(data, isNull);
    expect(adapter.requests, isEmpty, reason: '代际不符必须在发送前取消');
  });

  test('普通请求未使用校验标记，cookie 注入保持不变', () async {
    final acc = account(mid: 9004);
    Accounts.accountMode[AccountType.main.index] = acc;

    await Request().get('/x/web-interface/nav');

    final request = adapter.requests.single;
    expect(request.authProbe, isFalse);
    expect(request.tokenOnly, isFalse);
    expect(request.cookieHeader, contains('SESSDATA=sess_9004'));
    expect(request.headers['x-bili-mid'], '9004');
  });
}

class _AuthAdapter implements HttpClientAdapter {
  final requests = <_AuthRequest>[];
  List<String>? setCookies;

  void reset() {
    requests.clear();
    setCookies = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      _AuthRequest(
        authProbe: AccountManager.isAuthProbe(options),
        tokenOnly: options.extra[AccountManager.tokenOnlyExtra] == true,
        cookieHeader: options.headers['cookie'] ?? options.headers['Cookie'],
        query: Map<String, dynamic>.from(options.queryParameters),
        headers: Map<String, dynamic>.from(options.headers),
      ),
    );
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'data': {'isLogin': true, 'mid': 9000, 'uname': 'x'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        if (setCookies != null) HttpHeaders.setCookieHeader: setCookies!,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _AuthRequest {
  const _AuthRequest({
    required this.authProbe,
    required this.tokenOnly,
    required this.cookieHeader,
    required this.query,
    required this.headers,
  });

  final bool authProbe;
  final bool tokenOnly;
  final String? cookieHeader;
  final Map<String, dynamic> query;
  final Map<String, dynamic> headers;
}
