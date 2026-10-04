import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 直播收藏分区（`getLiveFavTag` / `setLiveFavTag`）的账号一致性。
///
/// 这两个接口是**主账号**的收藏操作，凭证与客户端字段（build / mobi_app /
/// 设备 / statistics / app-key 头 / 签名 key）必须全部来自主账号。此前的实现
/// 把 `Accounts.main.accessKey` 和推荐账号的档案拼在一个请求里，多账号绑定了
/// 不同平台或设备时会生成两套身份混合的请求 —— 这里用假 adapter 捕获最终
/// 发出的请求来钉住修复。
///
/// 用主账号实例直接注册（`Accounts.accountMode`）而不是 `Accounts.set`：
/// 后者会触发联网拉取用户信息与 UI 提示，与请求形状无关。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _CapturingAdapter adapter;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_live_fav_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    // 不用 `Request.setCookie()`：它还会调 LoginUtils.setWebCookie()，那需要
    // flutter_inappwebview 平台实现（单测环境没有）。这里只做与用例相关的两件事：
    // 实例化单例 Dio（`dio` 是 static late），注册账号拦截器
    // （含「按 mobi_app 配套签名 key」的逻辑），再把出网 adapter 换成只记录不发送的假实现。
    Request();
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    adapter = _CapturingAdapter();
    Request.dio.httpClientAdapter = adapter;
  });

  tearDown(() {
    adapter.captured.clear();
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 主账号：国内基线 + 专属设备。
  LoginAccount mainAccount() => _account(
    mid: 7001,
    device: AppDeviceProfile(brand: 'Xiaomi', model: '23046RP50C', osver: '15'),
    mobiApp: AppDeviceProfiles.android.mobiApp,
  );

  /// 推荐账号：海外版 + 另一台设备（制造「两套身份」的场景）。
  LoginAccount recommendAccount() => _account(
    mid: 7002,
    device: AppDeviceProfile(brand: 'OnePlus', model: 'PJZ110', osver: '16'),
    mobiApp: AppDeviceProfiles.androidIntl.mobiApp,
  );

  void seed({required LoginAccount main, required LoginAccount recommend}) {
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.recommend.index] = recommend;
  }

  test('参数构造只读传入账号的档案', () {
    final main = mainAccount();
    final params = LiveHttp.liveFavTagQueryParameters(main);
    final profile = main.appRequestProfile;

    expect(params['access_key'], 'ACCESS_KEY_7001');
    expect(params['mobi_app'], profile.mobiApp);
    expect(params['build'], profile.build);
    expect(params['channel'], profile.channel);
    expect(params['version'], profile.versionName);
    expect(params['device'], profile.requestDevice);
    expect(params['platform'], profile.platform);
    expect(params['statistics'], profile.statistics);
    expect(params['device_name'], isNull, reason: '该接口不发送 device_name');

    // 不碰推荐账号：即便推荐账号是海外版，主账号参数仍是国内基线。
    final intl = LiveHttp.liveFavTagQueryParameters(recommendAccount());
    expect(intl['mobi_app'], AppDeviceProfiles.androidIntl.mobiApp);
    expect(intl['build'], AppDeviceProfiles.androidIntl.build);
  });

  test('getLiveFavTag 用主账号的凭证+档案，不掺推荐账号', () async {
    final main = mainAccount();
    seed(main: main, recommend: recommendAccount());

    await LiveHttp.getLiveFavTag();

    final params = adapter.captured.single.queryParameters;
    final profile = main.appRequestProfile;
    expect(params['access_key'], 'ACCESS_KEY_7001');
    expect(params['mobi_app'], AppDeviceProfiles.android.mobiApp);
    expect(params['build'], AppDeviceProfiles.android.build);
    expect(params['statistics'], AppDeviceProfiles.android.statistics);
    expect(params['device'], AppDeviceProfiles.android.requestDevice);
    // 签名必须与参数里的 mobi_app 同源：换档案就得换 appkey/appsec。
    expect(params['appkey'], AppDeviceProfiles.android.appKey);
    expect(params['sign'], isNotNull);
    expect(profile.mobiApp, params['mobi_app']);
  });

  test('setLiveFavTag 同样只用主账号，并保留收藏 id', () async {
    final main = mainAccount();
    seed(main: main, recommend: recommendAccount());

    await LiveHttp.setLiveFavTag(ids: '1,2,3');

    final request = adapter.captured.single;
    final profile = main.appRequestProfile;
    // 表单参数此刻还是 Map（dio 在更下游才做 urlencode），query 为空。
    final body = request.data! as Map;
    expect(request.method, 'POST');
    expect(request.path, Api.setLiveFavTag);
    expect(request.queryParameters, isEmpty);
    expect(body['tags'], '1,2,3');
    expect(body['access_key'], 'ACCESS_KEY_7001');
    expect(body['mobi_app'], profile.mobiApp);
    expect(body['build'], profile.build);
    expect(body['appkey'], profile.appKey);
    expect(body['sign'], isNotNull);
  });

  test('主账号是海外绑定时，两个接口都跟着走海外档', () async {
    final intlMain = recommendAccount();
    seed(main: intlMain, recommend: mainAccount());

    await LiveHttp.getLiveFavTag();

    final captured = adapter.captured.single;
    final params = captured.queryParameters;
    expect(params['access_key'], 'ACCESS_KEY_7002');
    expect(params['mobi_app'], AppDeviceProfiles.androidIntl.mobiApp);
    expect(params['build'], AppDeviceProfiles.androidIntl.build);
    expect(params['statistics'], AppDeviceProfiles.androidIntl.statistics);
    expect(params['appkey'], AppDeviceProfiles.androidIntl.appKey);
    // UA 由账号档案派生，海外档不会拿到国内 UA。
    expect(
      captured.headers['user-agent'],
      AppDeviceProfiles.androidIntl.userAgent,
    );
    expect(
      captured.headers['user-agent'],
      isNot(AppDeviceProfiles.android.userAgent),
    );
  });

  test('liveFeedback 用推荐账号档案，且保留原有的 device 字段', () async {
    final recommend = recommendAccount();
    seed(main: mainAccount(), recommend: recommend);

    await LiveHttp.liveFeedback(1234, 5678, 'avid');

    final params = adapter.captured.single.queryParameters;
    final profile = recommend.appRequestProfile;
    expect(params['access_key'], 'ACCESS_KEY_7002');
    expect(params['mobi_app'], profile.mobiApp);
    expect(params['build'], profile.build);
    expect(params['statistics'], profile.statistics);
    // 迁移到共享 helper 时曾经漏掉这个字段（它只在 profile 上，拦截器也不会补）。
    expect(params['device'], profile.requestDevice);
    expect(params['appkey'], profile.appKey);
  });

  test('spaceShop 的客户端字段、签名与 UA 全部来自主账号档案', () async {
    // 商城域名不在 app 域名下，account_mgr 不会替它重签，签名必须自己配套；
    // 主账号绑定海外档时尤其容易暴露「参数 android_i、签名国内 key」的错位。
    final intlMain = recommendAccount();
    seed(main: intlMain, recommend: mainAccount());

    await MemberHttp.spaceShop(mid: 9001);

    final request = adapter.captured.single;
    final profile = intlMain.appRequestProfile;
    final params = request.queryParameters;
    expect(request.path, contains(Api.spaceShop));
    expect(params['access_key'], 'ACCESS_KEY_7002');
    expect(params['mobi_app'], profile.mobiApp);
    expect(params['build'], profile.build);
    expect(params['platform'], profile.platform);
    expect(params['device'], profile.requestDevice);
    expect(params['statistics'], profile.statistics);
    // 签名 key 与 mobi_app 同源。
    expect(params['appkey'], profile.appKey);
    expect(params['sign'], isNotNull);
    // 商城自己的协议版本保持不变。
    expect(params['mVersion'], 309);
    expect(params['mallVersion'], 8430300);
    // UA / app-key 头取自同一份档案。
    expect(request.headers['user-agent'], profile.userAgent);
    expect(request.headers['app-key'], profile.appKey);
    // 业务参数仍在 body 里。
    final body = request.data! as Map;
    expect(body['upMid'], '9001');
    expect(body['pageSize'], 8);
  });
}

LoginAccount _account({
  required int mid,
  required AppDeviceProfile device,
  required String mobiApp,
}) =>
    LoginAccount(
        _cookieJar(mid),
        'ACCESS_KEY_$mid',
        'REFRESH_$mid',
        null,
        null,
        device,
        mobiApp,
      )
      // 标记已激活：避免请求路径顺带触发 buvid 激活（那是另一个请求）。
      ..activated = true;

DefaultCookieJar _cookieJar(int mid) {
  final cookieJar = DefaultCookieJar(ignoreExpires: true);
  final cookies = <Cookie>[
    Cookie('DedeUserID', '$mid')..setBiliDomain(),
    Cookie('bili_jct', 'csrf_$mid')..setBiliDomain(),
  ];
  cookieJar.domainCookies['bilibili.com'] = {
    '/': {
      for (final cookie in cookies) cookie.name: SerializableCookie(cookie),
    },
  };
  return cookieJar;
}

/// 只记录不发送的 adapter：拿到账号拦截器处理后的最终请求。
class _CapturingAdapter implements HttpClientAdapter {
  final List<
    ({
      String method,
      String path,
      Map<String, dynamic> queryParameters,
      Map<String, dynamic> headers,
      Object? data,
    })
  >
  captured = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add((
      method: options.method,
      path: options.path,
      queryParameters: Map<String, dynamic>.from(options.queryParameters),
      headers: Map<String, dynamic>.from(options.headers),
      data: options.data,
    ));
    return ResponseBody.fromString(
      '{"code":0,"message":"0","data":{"tags":[]}}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
