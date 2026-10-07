import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/api_hosts.dart';
import 'package:PiliPlus/http/auth_probe_log_interceptor.dart';
import 'package:PiliPlus/http/hk_api_retry_interceptor.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/http/sensitive_log.dart';
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

/// 假 key / token / cookie 值：任何一条出现在日志里都算泄漏。
/// 提到顶层是为了让 adapter 也能构造「带凭证的响应体」。
const fakeKey =
    '{{Redact:fd25505d4669a7bcaac6378327687ab134297baee9f8e2687fffe4fa024c7f0f}}';
const fakeAccessToken =
    '{{Redact:88180c8cd6ef78d2f97d4965b4c258ba2417ddd7b0981d9851379b1d104a1e67}}';
const fakeRefreshToken =
    '{{Redact:aed27df8889cd8912df513df4cbc8dee720ed66627d4c03fade6d95861115a18}}';
const fakeSessData =
    'SESSDATA_{{Redact:caf917b09e1db94f3dfb573f2b544c6cb443957c3f23be39c7b741ec9af75f6b}}';

/// P1 回归：账号凭证绝不能进日志或错误提示。
///
/// 断言对象是**生产链里真实安装的那个** `AuthProbeLogInterceptor`（不是替代
/// 品）：测试只接管它的 `logPrint` 出口，静音/脱敏逻辑本身不被绕过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _LogAdapter adapter;
  late HttpClientAdapter originalAdapter;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_sensitive_log_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    // 关键顺序：所有 setting 必须在 `Request()` **之前**写好 ——
    // `RetryInterceptor(dio, Pref.retryCount, Pref.retryDelay)` 在构造时就把
    // 次数/延迟读走了，之后再写 setting 不生效（会用默认 2 次重试）。
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.retryDelay, 1);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    await GStorage.setting.put(SettingBoxKey.customApiBaseUrl, '');
    await GStorage.setting.put(SettingBoxKey.apiHKUrl, '');
    // 先建 Request()：dio 单例与整条拦截器链（含生产日志拦截器）在这一步
    // 才创建，测试随后从链上取真实实例。
    Request();
    // 与生产一致地挂上账号拦截器（普通请求的 cookie 注入路径）。
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    originalAdapter = Request.dio.httpClientAdapter;
    adapter = _LogAdapter();
    Request.dio.httpClientAdapter = adapter;
  });

  setUp(() async {
    adapter.reset();
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    await GStorage.setting.put(SettingBoxKey.customApiBaseUrl, '');
    await GStorage.setting.put(SettingBoxKey.apiHKUrl, '');
  });

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

  LoginAccount account({int mid = 9101, String key = fakeKey}) => LoginAccount(
    BiliCookieJar.fromJson({
      'DedeUserID': '$mid',
      'bili_jct': 'csrf_$mid',
      'SESSDATA': fakeSessData,
    }),
    key,
    fakeRefreshToken,
    null,
    IdentityCoreGenerators.deriveBuvidFromSeed('log-$mid'),
    AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
    'android',
  )..activated = true;

  /// 生产链里真实安装的日志拦截器。
  AuthProbeLogInterceptor installedLogger() =>
      Request.dio.interceptors.whereType<AuthProbeLogInterceptor>().single;

  /// 捕获该拦截器的输出，并在结束时还原（dio 是进程级单例，不能留污染）。
  List<String> captureLogs() {
    final logger = installedLogger();
    final original = logger.logPrint;
    final lines = <String>[];
    logger.logPrint = (object) => lines.add('$object');
    addTearDown(() => logger.logPrint = original);
    return lines;
  }

  test('生产日志开关与旧 logger 完全一致：不打印请求体 / 响应体', () {
    final logger = installedLogger();
    expect(logger.request, isFalse);
    expect(logger.requestHeader, isFalse);
    expect(logger.responseHeader, isFalse);
    expect(
      logger.requestBody,
      isFalse,
      reason: '打开 requestBody 会把登录请求体（含密码）打出来',
    );
    expect(
      logger.responseBody,
      isFalse,
      reason: '打开 responseBody 会打印 token_info.access_token / cookie_info',
    );
  });

  test('token-only 校验：整条静音，连 URL 都不出现', () async {
    final acc = account();
    Accounts.accountMode[AccountType.main.index] = acc;
    final identity = AccountHealthIdentity.capture(acc);
    final lines = captureLogs();

    await UserHttp.tokenOnlyUserInfo(
      account: acc,
      expectedIdentity: identity,
      accessKey: fakeKey,
    );

    expect(adapter.requests, hasLength(1));
    expect(
      adapter.requests.single.uri.queryParameters['access_key'],
      fakeKey,
      reason: '前提：key 真的在 URL query 里（否则这个回归没有意义）',
    );
    expect(
      lines,
      isEmpty,
      reason: '校验请求必须零输出：请求 URL、响应体、异常都不打印',
    );
  });

  test('token-only 校验失败：同样零输出', () async {
    final acc = account(mid: 9102);
    Accounts.accountMode[AccountType.main.index] = acc;
    final identity = AccountHealthIdentity.capture(acc);
    final lines = captureLogs();

    adapter.failAll = true;
    await UserHttp.tokenOnlyUserInfo(
      account: acc,
      expectedIdentity: identity,
      accessKey: fakeKey,
    );

    expect(lines, isEmpty);
  });

  test('普通请求仍保留原有可诊断信息（含 URL），且不打印 cookie 值', () async {
    final acc = account(mid: 9103);
    Accounts.accountMode[AccountType.main.index] = acc;
    final lines = captureLogs();

    await Request().get(Api.userInfo);

    final joined = lines.join('\n');
    expect(lines, isNotEmpty, reason: '普通请求的日志不能被削弱');
    expect(joined, contains('*** Request ***'));
    expect(joined, contains(Api.userInfo));
    expect(joined, isNot(contains(fakeSessData)));
    expect(joined, isNot(contains('headers:')));
  });

  test('真实登录响应结构：普通日志不会打印 access_token / refresh_token / cookie 值', () async {
    // 正在线上登录/nav 响应的真实形状（嵌套 token_info + cookies 列表）。
    adapter.rawResponse = {
      'code': 0,
      'message': '0',
      'data': {
        'isLogin': true,
        'mid': 9104,
        'uname': 'tester',
        'token_info': {
          'access_token': fakeAccessToken,
          'refresh_token': fakeRefreshToken,
          'expires_in': 2592000,
        },
        'cookie_info': {
          'cookies': [
            {'name': 'SESSDATA', 'value': fakeSessData},
            {'name': 'bili_jct', 'value': 'csrf_9104'},
          ],
        },
      },
    };
    final lines = captureLogs();

    await Request().get(Api.userInfo);

    final joined = lines.join('\n');
    expect(lines, isNotEmpty);
    expect(joined, isNot(contains(fakeAccessToken)));
    expect(joined, isNot(contains(fakeRefreshToken)));
    expect(joined, isNot(contains(fakeSessData)));
    expect(joined, isNot(contains('csrf_9104')));
  });

  test('港澳台失败提示：校验请求只给中性提示，普通请求保持原样', () {
    final probeOptions = RequestOptions(
      path: Api.userInfo,
      queryParameters: {'access_key': fakeKey},
      baseUrl: 'https://api.bilibili.com',
      extra: {AccountManager.authProbeExtra: true},
    );
    final probeToast = HkApiRetryInterceptor.hkFailureToast(probeOptions, {
      'code': -10403,
      'data': {
        'access_key': fakeKey,
        'token_info': {'access_token': fakeAccessToken},
      },
    });
    expect(probeToast, isNot(contains(fakeKey)));
    expect(probeToast, isNot(contains(fakeAccessToken)));
    expect(probeToast, isNot(contains('api.bilibili.com')));
    expect(probeToast, contains('已省略详情'));

    final ordinaryOptions = RequestOptions(
      path: Api.replyMain,
      baseUrl: 'https://api.bilibili.com',
    );
    final ordinaryToast = HkApiRetryInterceptor.hkFailureToast(
      ordinaryOptions,
      {'code': -10403},
    );
    expect(
      ordinaryToast,
      contains('url:https://api.bilibili.com/x/v2/reply/main'),
    );
    expect(ordinaryToast, contains('-10403'));
  });

  test('港澳台重试对校验请求照常执行（真实管线产生的提示不含凭证）', () async {
    final acc = account(mid: 9105);
    Accounts.accountMode[AccountType.main.index] = acc;
    final identity = AccountHealthIdentity.capture(acc);

    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, true);
    await GStorage.setting.put(
      SettingBoxKey.customApiBaseUrl,
      'https://mirror.example.com',
    );
    await GStorage.setting.put(
      SettingBoxKey.apiHKUrl,
      'https://hk.example.com',
    );

    adapter.failHkRetry = true;
    // 捕获**真实管线**里那个 toast，而不是把 helper 重算一遍。
    final toasts = <String>[];
    final originalSink = HkApiRetryInterceptor.debugToastSink;
    HkApiRetryInterceptor.debugToastSink = toasts.add;
    addTearDown(() => HkApiRetryInterceptor.debugToastSink = originalSink);
    final lines = captureLogs();

    await UserHttp.tokenOnlyUserInfo(
      account: acc,
      expectedIdentity: identity,
      accessKey: fakeKey,
    );

    expect(
      adapter.hkRetryUris,
      hasLength(1),
      reason: '-10403 必须真的触发港澳台重试（重试本身不被跳过）',
    );
    expect(lines, isEmpty, reason: '校验请求的重试过程同样零输出');
    expect(toasts, hasLength(1), reason: '失败提示确实被发出');
    final toast = toasts.single;
    expect(toast, contains('已省略详情'));
    expect(toast, isNot(contains(fakeKey)));
    expect(toast, isNot(contains(fakeSessData)));
    expect(toast, isNot(contains(fakeAccessToken)));
    expect(adapter.hkRetryBody, isNotNull);
  });

  test('普通重试仍然工作，且校验请求即使重试也零日志', () async {
    // 本文件按生产顺序在 `Request()` 前写 retryCount=0（HK 用例要求恰好一次
    // 请求）。这里显式挂一个「开启重试」的同类拦截器，验证重试路径本身没坏，
    // 且校验请求在重试过程中依旧零输出。
    final retry = RetryInterceptor(Request.dio, 2, 1);
    Request.dio.interceptors.add(retry);
    addTearDown(() => Request.dio.interceptors.remove(retry));

    adapter.failAll = true;
    final ordinaryLines = captureLogs();
    await Request().get(Api.userInfo);
    expect(
      adapter.requests.length,
      greaterThanOrEqualTo(2),
      reason: '普通请求的重试必须仍然生效（否则本用例失去意义）',
    );
    expect(ordinaryLines, isNotEmpty, reason: '普通请求的错误日志保留');

    // 校验请求：同样的重试路径，但一行日志都不能有。
    adapter.reset();
    adapter.failAll = true;
    final acc = account(mid: 9106);
    Accounts.accountMode[AccountType.main.index] = acc;
    final probeLines = captureLogs();
    await UserHttp.tokenOnlyUserInfo(
      account: acc,
      expectedIdentity: AccountHealthIdentity.capture(acc),
      accessKey: fakeKey,
    );
    expect(
      adapter.requests.length,
      greaterThanOrEqualTo(2),
      reason: '校验请求同样被重试（重试管线未被跳过）',
    );
    expect(probeLines, isEmpty, reason: '重试过程中的校验请求同样零输出');
  });

  group('SensitiveLog 兜底脱敏', () {
    test('递归擦除嵌套 Map / List 里的凭证', () {
      final masked = SensitiveLog.maskDeep({
        'code': 0,
        'data': {
          'access_key': fakeKey,
          'token_info': {
            'access_token': fakeAccessToken,
            'refresh_token': fakeRefreshToken,
          },
          'cookie_info': {
            'cookies': [
              {'name': 'SESSDATA', 'value': fakeSessData},
            ],
          },
        },
      });
      final text = jsonEncode(masked);
      expect(text, isNot(contains(fakeKey)));
      expect(text, isNot(contains(fakeAccessToken)));
      expect(text, isNot(contains(fakeRefreshToken)));
      expect(text, contains('***'), reason: '擦除而不是整段丢弃，保留可诊断性');
      expect(text, contains('"code":0'), reason: '非敏感内容原样保留');
    });

    test('JSON 字符串形态也会被解析后擦除', () {
      final masked = SensitiveLog.maskDeep(
        '{"data":{"token_info":{"access_token":"$fakeAccessToken"}},"mid":7}',
      );
      expect(masked.toString(), isNot(contains(fakeAccessToken)));
      expect(masked.toString(), contains('"mid":7'));
    });

    test('JSON 引号键与 URL query 两种行形态都能擦', () {
      final maskedJson = SensitiveLog.maskLine(
        'body: {"access_key":"$fakeKey","mid":1}',
      );
      expect(maskedJson, isNot(contains(fakeKey)));
      expect(maskedJson, contains('mid'));
      expect(maskedJson, contains('***'));

      final maskedUrl = SensitiveLog.maskLine(
        'uri: https://api.bilibili.com/x/web-interface/nav?access_key=$fakeKey&mid=1',
      );
      expect(maskedUrl, isNot(contains(fakeKey)));
      expect(maskedUrl, contains('mid=1'));

      final maskedCookie = SensitiveLog.maskLine(
        'headers: cookie: SESSDATA=$fakeSessData; bili_jct=csrf_1',
      );
      expect(maskedCookie, isNot(contains(fakeSessData)));
      expect(maskedCookie, isNot(contains('csrf_1')));
    });
  });

  test('自定义主机合法性判定保持原样（没有 HD 覆盖）', () {
    expect(isValidCustomHost('https://mirror.example.com'), isTrue);
    expect(isValidCustomHost('not a url'), isFalse);
  });
}

/// 只记录请求、按开关作答；绝不访问网络。
class _LogAdapter implements HttpClientAdapter {
  final requests = <_LogRequest>[];
  bool failAll = false;
  bool failHkRetry = false;
  final hkRetryUris = <String>[];
  final hkRetryOptions = <RequestOptions>[];
  Object? hkRetryBody;
  Map<String, dynamic>? rawResponse;

  void reset() {
    requests.clear();
    failAll = false;
    failHkRetry = false;
    hkRetryUris.clear();
    hkRetryOptions.clear();
    hkRetryBody = null;
    rawResponse = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      _LogRequest(
        uri: options.uri,
        authProbe: AccountManager.isAuthProbe(options),
        tokenOnly: options.extra[AccountManager.tokenOnlyExtra] == true,
      ),
    );
    if (failAll) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    if (options.uri.host == 'hk.example.com') {
      hkRetryUris.add(options.uri.toString());
      hkRetryOptions.add(options);
      if (failHkRetry) {
        hkRetryBody = {
          'code': 0,
          'data': {
            'access_key': options.uri.queryParameters['access_key'],
            'token_info': {'access_token': 'HK_$fakeAccessToken'},
          },
        };
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        );
      }
      return _json({
        'code': 0,
        'data': {'isLogin': true, 'mid': 9105},
      });
    }
    // 港澳台主机可用时返回 -10403，触发真实的重试分支；响应体故意带凭证。
    return _json(
      rawResponse ??
          {
            'code': -10403,
            'message': 'risk control',
            'data': {'access_key': fakeKey},
          },
    );
  }

  ResponseBody _json(Map<String, dynamic> body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

class _LogRequest {
  const _LogRequest({
    required this.uri,
    required this.authProbe,
    required this.tokenOnly,
  });

  final Uri uri;
  final bool authProbe;
  final bool tokenOnly;
}
