import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/common/dial_prefix.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/login/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, SizedBox;
import 'package:pointycastle/export.dart';

/// 短信验证码登录的**提交快照**契约。
///
/// 回归背景：`loginBySmsCode` 在 `getWebKey()` 之前冻结了 identity/profile，
/// 却仍然在 await 之后读取 `captchaKey` / 手机号 / 验证码 / 区号。用户在等待
/// 期间重新发码（或改动表单）会让这次登录把「新验证码」和「旧 profile」拼在
/// 一起 —— 发码身份与登录身份被拆开，落库的平台也随之错位。
///
/// 这里把控制器真正跑起来：`getWebKey` 的响应被挂起，测试在挂起期间改写所有
/// 表单状态，然后断言最终发出的登录请求仍使用提交那一刻的值。
class _CapturingAdapter implements HttpClientAdapter {
  final List<({String path, Map<String, dynamic> data})> captured = [];
  final Map<String, String> _responses = {};

  /// 按路径注册响应体。
  void respond(String path, Map<String, dynamic> body) {
    _responses[path] = jsonEncode(body);
  }

  /// 让某条路径的下一个响应挂起，返回放行用的回调。
  Future<void> Function()? Function(String path)? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    captured.add((
      path: path,
      data: options.data is Map
          ? Map<String, dynamic>.from(options.data as Map)
          : <String, dynamic>{},
    ));

    final gateFor = gate;
    if (gateFor != null) {
      final wait = gateFor(path);
      if (wait != null) await wait();
    }

    final body = _responses[path] ?? '{"code":0,"message":"0","data":{}}';
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 不落库、不弹账号选择的子类：只记录最终提交给 `setAccount` 的参数。
class _RecordingLoginController extends LoginPageController {
  Map? submittedTokenInfo;
  List? submittedCookies;
  RequestIdentityAdapter? submittedIdentity;
  AppRequestProfile? submittedProfile;

  /// 用例不构建界面，因此没有 TabController 可关。
  @override
  void onClose() {
    telTextController.dispose();
    usernameTextController.dispose();
    passwordTextController.dispose();
    smsCodeTextController.dispose();
    cookieTextController.dispose();
  }

  @override
  Future<void> setAccount(
    Map tokenInfo,
    List cookieInfo, {
    required RequestIdentityAdapter identity,
    required AppRequestProfile profile,
  }) async {
    submittedTokenInfo = tokenInfo;
    submittedCookies = cookieInfo;
    submittedIdentity = identity;
    submittedProfile = profile;
  }
}

/// 生成一对 RSA 密钥，返回 [encrypt] 包的 `RSAKeyParser` 能解析的 PKCS#1 公钥串。
String _generatePublicKey() {
  // 这里只需要一把结构合法的公钥（私钥不用），用固定种子保证用例可复现。
  final random = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List<int>.generate(32, (i) => i + 1))));
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
        random,
      ),
    );
  final pair = generator.generateKeyPair();
  return _encodePkcs1PublicKey(pair.publicKey as RSAPublicKey);
}

/// `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`
String _encodePkcs1PublicKey(RSAPublicKey key) {
  final modulus = _derInteger(key.modulus!);
  final exponent = _derInteger(key.exponent!);
  final body = <int>[...modulus, ...exponent];
  final der = <int>[0x30, ..._derLength(body.length), ...body];
  // 先整体 base64，再按 64 字符折行；按字节分块会让 padding 落在行中间。
  final encoded = base64.encode(der);
  final buffer = StringBuffer('-----BEGIN RSA PUBLIC KEY-----\n');
  for (var i = 0; i < encoded.length; i += 64) {
    final end = (i + 64 < encoded.length) ? i + 64 : encoded.length;
    buffer.writeln(encoded.substring(i, end));
  }
  buffer.write('-----END RSA PUBLIC KEY-----');
  return buffer.toString();
}

List<int> _derInteger(BigInt value) {
  var bytes = value.toRadixString(16);
  if (bytes.length.isOdd) bytes = '0$bytes';
  final raw = <int>[
    for (var i = 0; i < bytes.length; i += 2)
      int.parse(bytes.substring(i, i + 2), radix: 16),
  ];
  // 最高位为 1 时要补一个 0x00，避免被解释成负数。
  final content = (raw.isNotEmpty && raw.first >= 0x80) ? [0, ...raw] : raw;
  return [0x02, ..._derLength(content.length), ...content];
}

List<int> _derLength(int length) {
  if (length < 0x80) return [length];
  final bytes = <int>[];
  var remaining = length;
  while (remaining > 0) {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _CapturingAdapter adapter;
  late String publicKey;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_login_snapshot_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    Request();
    adapter = _CapturingAdapter();
    Request.dio.httpClientAdapter = adapter;
    publicKey = _generatePublicKey();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() {
    adapter.captured.clear();
    adapter.gate = null;
    adapter.respond(Api.getWebKey, {
      'code': 0,
      'message': '0',
      'data': {'key': publicKey, 'hash': 'hash'},
    });
    adapter.respond(Api.logInByAppSms, {
      'code': 0,
      'message': '0',
      'data': {
        'token_info': {
          'access_token': 'ACCESS_KEY_SNAPSHOT',
          'refresh_token': 'REFRESH_SNAPSHOT',
        },
        'cookie_info': {
          'cookies': [
            {'name': 'DedeUserID', 'value': '9501'},
            {'name': 'bili_jct', 'value': 'csrf_9501'},
          ],
        },
      },
    });
    for (final type in AccountType.values) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
  });

  testWidgets('等待公钥期间重新发码，登录仍用提交那一刻的验证码与平台', (tester) async {
    // 登录成功路径会弹 toast：先挂上 FlutterSmartDialog 的 builder，
    // 让 `DialogProxy.contextToast` 有值（纯逻辑用例不渲染其它界面）。
    await tester.pumpWidget(
      MaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const SizedBox.shrink(),
      ),
    );

    await tester.runAsync(() async {
      final controller = _RecordingLoginController();
      addTearDown(controller.onClose);

      // 这是一次「WhatsApp 发码成功」之后的提交：验证码属于海外版流程。
      controller.telTextController.text = '13800000000';
      controller.smsCodeTextController.text = '111111';
      controller.captchaKey = 'CAPTCHA_OLD';
      controller.selectedCountryCodeId = Login.dialPrefix[1]; // 香港 852
      controller.smsSendTimestamp = DateTime.now().millisecondsSinceEpoch;

      final webKeyGate = Completer<void>();
      adapter.gate = (path) =>
          path == Api.getWebKey ? () => webKeyGate.future : null;

      final login = controller.loginBySmsCode();
      // 请求要穿过拦截器链才会到达 adapter，这里轮询等待公钥请求就位。
      for (var i = 0; i < 200 && adapter.captured.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        adapter.captured.map((e) => e.path),
        contains(Api.getWebKey),
        reason: '登录流程应当先取公钥',
      );

      // 挂起期间：换了手机号、区号、验证码，并重新发了一次码。
      controller.telTextController.text = '13900000000';
      controller.smsCodeTextController.text = '222222';
      controller.captchaKey = 'CAPTCHA_NEW';
      controller.selectedCountryCodeId = Login.dialPrefix[0]; // 大陆 86

      webKeyGate.complete();
      try {
        await login;
      } catch (e) {
        // 用例只关心提交内容；登录末尾的 `Get.back()` 在无 GetMaterialApp
        // 的宿主里会抛错，与本次验证无关。
        expect(e.toString(), contains('contextless navigation'));
      }

      final loginBody = adapter.captured
          .firstWhere((e) => e.path == Api.logInByAppSms)
          .data;
      expect(loginBody['captcha_key'], 'CAPTCHA_OLD');
      expect(loginBody['code'], '111111');
      expect(loginBody['tel'], '13800000000');
      expect(loginBody['cid'], 852);
      // 请求参数与落库档案同源：都是发码那一刻锁定的那一套。
      expect(controller.submittedProfile, isNotNull);
      expect(loginBody['statistics'], controller.submittedProfile!.statistics);
    });
  });
}
