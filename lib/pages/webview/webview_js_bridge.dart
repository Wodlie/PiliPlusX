import 'dart:convert';
import 'dart:io' show Platform;

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart' show BiliCookieJar;
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

/// JSB 消息：method / data / 主 callbackId / 全部 *CallbackId 回调注册表。
///
/// 老 callNative 协议支持多回调（如 `callback` + `onLoad` + `onLogin`），
/// 每个函数在发送时被注册进 `BiliJsBridge.callbacks`，回调 ID 写入
/// `data.<回调名>CallbackId`（V2 协议主回调在消息顶层）。
typedef JsbMessage = ({
  String method,
  Map data,
  String? callbackId,
  Map<String, String> callbackIds,
});

/// 一次 JSB 回调：callbackId -> payload。
typedef JsCallback = ({String callbackId, Object? payload});

/// biliInject JS Bridge 协议实现。
///
/// 对齐 Bilibili 官方 H5 容器协议（JsBridgeProxyV2）：
/// - H5 → Native：`window.biliInject.postMessage(jsonString)`，
///   json 形如 `{"method": "namespace.func", "data": {...}}`；
/// - Native → H5：`window.biliInject.biliCallbackReceived(callbackId, payload)`。
///
/// 协议要点（与官方页面 JS 逆向对齐）：
/// - V1 与 V2 共用一套 method 命名空间；V2 走独立的
///   `window.biliInjectV2`，因此注册独立的 JS handler 以便区分响应格式
///   （`global.getAllSupport` 在 V1 期望 `data` 为数组、V2 期望 `data.methods`）。
/// - polyfill 故意不实现 `biliCallbackReceived`：页面 JSB 初始化时会检测
///   该函数缺失并安装自己的分发器（查 `BiliJsBridge.callbacks` 数组），
///   回调才能与页面注册的 callbackId 正确配对。
/// - `net.request*` 网络类方法不实现（返回失败），页面会据此立即降级到
///   浏览器 fetch + Cookie 通道，避免 native 通道挂起。
///
/// 安全：仅 `*.bilibili.com` 域页面允许调用（对应官方 JsbControllerManager 白名单）。
abstract final class WebviewJsBridge {
  /// 注册到 WebView 的 JavaScript handler 名称（V1 协议）。
  static const String handlerName = 'biliInject';

  /// V2 协议的独立 handler 名称。
  static const String handlerNameV2 = 'biliInjectV2';

  /// AT_DOCUMENT_START 注入的 polyfill：把 `window.biliInject` /
  /// `window.biliInjectV2` / `window.biliExtBridge` 桥接到
  /// `window.flutter_inappwebview.callHandler`。
  static UserScript get polyfillUserScript => UserScript(
    source: _polyfillSource,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: false,
  );

  /// 解析 H5 传来的消息，返回 method / data / callbackId。
  static JsbMessage? parseMessage(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final method = decoded['method'];
    if (method is! String || method.isEmpty) return null;
    final data = decoded['data'];
    final dataMap = data is Map
        ? Map<Object?, Object?>.from(data)
        : <Object?, Object?>{};
    // V1 协议 callbackId 在 data 内（Android 为数字自增），
    // V2 协议在消息顶层；均需兼容数字与字符串。
    final rawCallbackId = dataMap['callbackId'] ?? decoded['callbackId'];
    String? callbackId;
    if (rawCallbackId is String) {
      callbackId = rawCallbackId;
    } else if (rawCallbackId is num) {
      callbackId = rawCallbackId.toString();
    }
    // 其余回调（onLoad / onLogin / 自定义命名回调）统一按 *CallbackId 提取。
    final callbackIds = <String, String>{};
    dataMap.forEach((key, value) {
      if (key is! String || !key.endsWith('CallbackId')) return;
      if (value is String) {
        callbackIds[key] = value;
      } else if (value is num) {
        callbackIds[key] = value.toString();
      }
    });
    return (
      method: method,
      data: dataMap,
      callbackId: callbackId,
      callbackIds: callbackIds,
    );
  }

  /// JSB 白名单：仅 bilibili.com 及子域（对应官方 JsbControllerManager）。
  static bool isAllowedHost(String? host) {
    if (host == null || host.isEmpty) return false;
    final h = host.toLowerCase();
    return h == 'bilibili.com' || h.endsWith('.bilibili.com');
  }

  /// WebView 创建后调用：注册 biliInject（V1）与 biliInjectV2 两个 handler。
  static void attach(InAppWebViewController controller) {
    controller
      ..addJavaScriptHandler(
        handlerName: handlerName,
        callback: (args) => _handle(controller, args, isV2: false),
      )
      ..addJavaScriptHandler(
        handlerName: handlerNameV2,
        callback: (args) => _handle(controller, args, isV2: true),
      );
  }

  /// Native → H5 回调。payload 以对象形式传给页面（官方分发器直接透传，
  /// 不要求 JSON 字符串），因此这里只做一层 jsonEncode。
  static Future<void> callbackToJs(
    InAppWebViewController controller,
    String callbackId,
    Object? payload, {
    bool isV2 = false,
  }) {
    final bridge = isV2 ? handlerNameV2 : handlerName;
    return controller.evaluateJavascript(
      source:
          'window.$bridge && window.$bridge.biliCallbackReceived(${jsonEncode(callbackId)}, ${jsonEncode(payload)});',
    );
  }

  /// 向页面声明支持的方法列表（`global.getAllSupport` 响应）。
  ///
  /// 刻意不含 `net.request*`：native fetch 未实现，声明不支持可让页面
  /// 立即降级到浏览器 fetch + Cookie 通道，而不是等待 native 响应挂起。
  static const List<String> supportedMethods = [
    'global.getAllSupport',
    'global.getContainerInfo',
    'global.closeBrowser',
    'global.registerChannel',
    'global.unregisterChannel',
    'auth.getUserInfo',
    'auth.login',
    'auth.refreshUserInfo',
    'auth.exchangeTicket',
    'ui.hideNavigation',
    'ui.showNavigation',
    'ability.openScheme',
    'ability.currentThemeType',
    'app.openSchema',
    'app.getUserInfo',
    'app.validateLogin',
    'login.checkLoginStatus',
    'login.openLoginPage',
    'device.getNetworkType',
    'storage.get',
    'storage.set',
    'storage.remove',
    'container.close',
  ];

  static Future<Object?> _handle(
    InAppWebViewController controller,
    List<Object?> args, {
    required bool isV2,
  }) async {
    final raw = args.isNotEmpty && args.first is String
        ? args.first as String
        : null;
    final message = parseMessage(raw);
    if (message == null) return null;

    final WebUri? currentUrl = await controller.getUrl();
    if (!isAllowedHost(currentUrl?.host)) {
      if (message.callbackId != null) {
        await callbackToJs(
          controller,
          message.callbackId!,
          {
            'ok': false,
            'error_code': -403,
            'error_msg': 'jsb not allowed on this page',
          },
          isV2: isV2,
        );
      }
      return null;
    }

    final result = await _dispatch(message, isV2: isV2);
    for (final r in result) {
      await callbackToJs(
        controller,
        r.callbackId,
        r.payload,
        isV2: isV2,
      );
    }
    return null;
  }

  /// 单回调响应：包装为 [_dispatch] 返回的回调列表。
  static List<JsCallback> _reply(JsbMessage message, Object? payload) {
    final cb = message.callbackId;
    return cb == null ? const [] : [(callbackId: cb, payload: payload)];
  }

  static Future<List<JsCallback>> _dispatch(
    JsbMessage message, {
    required bool isV2,
  }) async {
    final data = message.data;
    switch (message.method) {
      case 'container.close':
        return _reply(message, _containerClose());
      case 'app.openSchema':
        return _reply(message, await _appOpenSchema(data));
      case 'app.getUserInfo':
        return _reply(message, _appGetUserInfo());
      case 'app.validateLogin':
      case 'login.checkLoginStatus':
        return _reply(message, _appValidateLogin());
      case 'login.openLoginPage':
        return _reply(message, _loginOpenLoginPage());
      case 'device.getNetworkType':
        return _reply(message, _deviceGetNetworkType());
      case 'storage.get':
        return _reply(message, _storageGet(data));
      case 'storage.set':
        return _reply(message, _storageSet(data));
      case 'storage.remove':
        return _reply(message, _storageRemove(data));
      // ── 以下为 account-h5 等官方容器页面实际使用的协议方法 ──
      case 'global.getAllSupport':
        return _reply(message, _globalGetAllSupport(isV2: isV2));
      case 'auth.getUserInfo':
        return _reply(message, _authGetUserInfo());
      case 'auth.login':
        Get.toNamed('/loginPage');
        return _reply(message, _ok());
      case 'auth.refreshUserInfo':
        // 页面仅用于同步刷新用户信息，客户端无增量数据，直接返回成功。
        return _reply(message, {
          'code': 0,
          'message': 'success',
          'data': const {},
        });
      case 'auth.exchangeTicket':
        // 免登录换票流程，本客户端直接视为成功。
        return _reply(message, {
          'code': 0,
          'message': 'success',
          'data': const {},
        });
      case 'global.getContainerInfo':
        return _reply(message, _globalGetContainerInfo());
      case 'global.closeBrowser':
        return _reply(message, _globalCloseBrowser());
      case 'global.registerChannel':
      case 'global.unregisterChannel':
      case 'global.import':
        // 命名空间导入 / 频道订阅：本客户端无对应能力，忽略并返回成功。
        return _reply(message, _ok());
      case 'ui.hideNavigation':
      case 'ui.showNavigation':
        // 页面导航栏由 Flutter 侧控制，无需动作。
        return _reply(message, {
          'code': 0,
          'message': 'success',
          'data': const {},
        });
      case 'ability.openScheme':
        return _reply(message, await _abilityOpenScheme(data));
      case 'ability.currentThemeType':
        return _reply(message, _abilityCurrentThemeType());
      // net.* 走 native 网络代理（老 callNative 协议：callback("ok") +
      // onLoad(数据) 双回调），页面不会降级到浏览器 fetch。
      case 'net.request':
      case 'net.requestV2':
      case 'net.requestWithSign':
      case 'net.requestWithSignV2':
      case 'net.requestWithoutParams':
        return _netRequest(message);
      case 'net.uploadImage':
      case 'net.uploadImageV2':
        return _reply(message, 'error: upload not supported');
      case 'net.getCsrf':
        return _reply(message, _netGetCsrf());
      default:
        return _reply(message, {
          'ok': false,
          'error_code': -32601,
          'error_msg': 'unsupported method: ${message.method}',
        });
    }
  }

  static Map<String, Object?> _ok([Map<String, Object?> data = const {}]) => {
    'code': 0,
    'message': 'success',
    'data': data,
  };

  // ── container ──────────────────────────────────────────────

  static Map<String, Object?> _containerClose() {
    Get.back();
    return {'ok': true};
  }

  // ── app（老接口，biliExtBridge 兼容）────────────────────────

  static Future<Map<String, Object?>> _appOpenSchema(Map data) async {
    final url = data['url'];
    if (url is! String || url.isEmpty) {
      return {'ok': false, 'error_code': -400, 'error_msg': 'invalid url'};
    }
    final handled = await PiliScheme.routePushFromUrl(url);
    return {'ok': handled, 'handled': handled};
  }

  static Map<String, Object?> _appGetUserInfo() {
    final info = Pref.userInfoCache;
    return {
      'isLogin': info?.isLogin ?? false,
      'uid': info?.mid ?? 0,
      'name': info?.uname ?? '',
      'face': info?.face ?? '',
    };
  }

  static Map<String, Object?> _appValidateLogin() {
    final info = Pref.userInfoCache;
    return {
      'isLogin': Accounts.main.isLogin || (info?.isLogin ?? false),
      'uid': info?.mid ?? 0,
    };
  }

  // ── auth / login ───────────────────────────────────────────

  static Map<String, Object?> _authGetUserInfo() {
    final info = Pref.userInfoCache;
    final isLogin = Accounts.main.isLogin || (info?.isLogin ?? false);
    // 官方 auth.getUserInfo 响应为平铺字段：页面（UserAuth store）直接
    // 读取顶层 state/mid/face/userName（state: "0" 表示未登录）。
    return {
      'code': 0,
      'state': isLogin ? 1 : 0,
      'mid': info?.mid ?? 0,
      'face': info?.face ?? '',
      'userName': info?.uname ?? '',
    };
  }

  static Map<String, Object?> _loginOpenLoginPage() {
    Get.toNamed('/loginPage');
    return _ok();
  }

  // ── global ─────────────────────────────────────────────────

  static Object? _globalGetAllSupport({required bool isV2}) {
    // V1 的 isSupport 期望 data 直接是方法数组；
    // 老协议（UserAuth.login）甚至直接用响应.indexOf() 检查，
    // 因此 V1 直接返回数组本身。
    // V2 的 getAllSupport 期望 {code, data: {methods: [...]}}。
    return isV2 ? _ok({'methods': supportedMethods}) : supportedMethods;
  }

  static Map<String, Object?> _globalGetContainerInfo() {
    return _ok({
      'appId': 1,
      'platform': Platform.isAndroid
          ? 'android'
          : Platform.isIOS
          ? 'ios'
          : 'web',
    });
  }

  static Map<String, Object?> _globalCloseBrowser() {
    Get.back();
    return _ok();
  }

  // ── ability ────────────────────────────────────────────────

  static Future<Map<String, Object?>> _abilityOpenScheme(Map data) async {
    final url = data['url'];
    if (url is! String || url.isEmpty) {
      return {'code': -400, 'message': 'invalid url', 'data': null};
    }
    final handled = await PiliScheme.routePushFromUrl(url);
    return _ok({'handled': handled});
  }

  static Map<String, Object?> _abilityCurrentThemeType() {
    // 官方页面按 type == 2 判定暗色模式。
    return _ok({'type': ThemeUtils.isDarkMode ? 2 : 1});
  }

  // ── device ─────────────────────────────────────────────────

  static Map<String, Object?> _deviceGetNetworkType() {
    // 与 gRPC 头保持一致（项目统一按 WIFI 上报）
    return {'networkType': 'wifi'};
  }

  // ── net（native 网络代理，老 callNative 协议）─────────────

  /// 代理页面网络请求：老协议要求 `callback("ok")`（状态）+ `onLoad(数据)`
  /// 双回调；数据格式 `{response, httpStatus, headers}` 供页面构造 Response。
  /// 仅允许代理 bilibili 域请求（安全白名单）。
  static Future<List<JsCallback>> _netRequest(JsbMessage message) async {
    final data = message.data;
    final cb = message.callbackId;
    final onLoadCb = message.callbackIds['onLoadCallbackId'];
    final url = data['url'];
    if (url is! String || url.isEmpty) {
      return _reply(message, 'error: invalid url');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !isAllowedHost(uri.host)) {
      return _reply(message, 'error: url not allowed');
    }
    try {
      final method = (data['method'] as String?) ?? 'GET';
      final headers = data['header'];
      final params = data['params'];
      final body = data['data'];
      final timeoutSec = data['timeout'];
      final options = Options(
        headers: headers is Map ? Map<String, dynamic>.from(headers) : null,
        responseType: ResponseType.plain,
        receiveTimeout: timeoutSec is num && timeoutSec > 0
            ? Duration(milliseconds: (timeoutSec * 1000).round())
            : null,
        connectTimeout: timeoutSec is num && timeoutSec > 0
            ? Duration(milliseconds: (timeoutSec * 1000).round())
            : null,
      );
      final res = method.toUpperCase() == 'POST'
          ? await Request.dio.post(
              url,
              data: body is String && body.isNotEmpty ? body : null,
              queryParameters: params is Map
                  ? Map<String, dynamic>.from(params)
                  : null,
              options: options,
            )
          : await Request.dio.get(
              url,
              queryParameters: params is Map
                  ? Map<String, dynamic>.from(params)
                  : null,
              options: options,
            );
      final headerMap = <String, String>{};
      res.headers.forEach((k, v) => headerMap[k] = v.join(','));
      final payload = <String, Object?>{
        'response': res.data,
        'httpStatus': res.statusCode,
        'headers': headerMap,
      };
      return [
        if (cb != null) (callbackId: cb, payload: 'ok'),
        if (onLoadCb != null) (callbackId: onLoadCb, payload: payload),
      ];
    } catch (e) {
      return _reply(message, 'error: $e');
    }
  }

  static Map<String, Object?> _netGetCsrf() {
    try {
      final biliJct = Accounts.main.cookieJar.toList().firstWhere(
        (cookie) => cookie.name == 'bili_jct',
      );
      return _ok({'csrf': biliJct.value});
    } catch (_) {
      return {'code': -101, 'message': 'not login', 'data': null};
    }
  }

  // ── storage（会话级隔离 KV，不触碰 GStorage）───────────────

  static final Map<String, Object?> _kv = <String, Object?>{};

  static Map<String, Object?> _storageGet(Map data) {
    final key = data['key'];
    if (key is! String || key.isEmpty) {
      return {'ok': false, 'error_code': -400, 'error_msg': 'invalid key'};
    }
    return {'ok': true, 'value': _kv[key]};
  }

  static Map<String, Object?> _storageSet(Map data) {
    final key = data['key'];
    if (key is! String || key.isEmpty) {
      return {'ok': false, 'error_code': -400, 'error_msg': 'invalid key'};
    }
    _kv[key] = data['value'];
    return {'ok': true};
  }

  static Map<String, Object?> _storageRemove(Map data) {
    final key = data['key'];
    if (key is! String || key.isEmpty) {
      return {'ok': false, 'error_code': -400, 'error_msg': 'invalid key'};
    }
    _kv.remove(key);
    return {'ok': true};
  }

  // ── polyfill ───────────────────────────────────────────────

  static const String _polyfillSource = r'''
(function() {
  if (window.biliInject) return;

  function post(handler, json) {
    window.flutter_inappwebview.callHandler(
      handler,
      typeof json === 'string' ? json : JSON.stringify(json)
    );
  }

  // V1：只提供 postMessage。故意不定义 biliCallbackReceived ——
  // 页面 JSB 初始化时检测到缺失会用自身的分发器接管
  // （查 window.BiliJsBridge.callbacks，与页面注册的 callbackId 配对）。
  window.biliInject = {
    postMessage: function(json) {
      post('biliInject', json);
    }
  };

  // V2：独立 handler，原生据此区分协议版本（响应格式不同）。
  window.biliInjectV2 = {
    postMessage: function(json) {
      post('biliInjectV2', json);
    }
  };

  // 回调注册：写入 BiliJsBridge.callbacks（与页面协议一致），
  // 由页面接管后的 biliCallbackReceived 分发。页面脚本执行前
  // BiliJsBridge 尚不存在时按页面骨架兜底创建，页面脚本会补齐其余字段。
  function registerCallback(callback) {
    if (typeof callback !== 'function') return null;
    var B = window.BiliJsBridge || (window.BiliJsBridge = {
      callbacks: [],
      selfCallbackId: 1
    });
    if (!B.callbacks) B.callbacks = [];
    if (typeof B.selfCallbackId !== 'number') B.selfCallbackId = 1;
    var id = B.selfCallbackId++;
    B.callbacks.push({
      method: '',
      callback: callback,
      callbackId: id,
      callbackName: 'callback'
    });
    return id;
  }

  // biliExtBridge 扩展接口
  window.biliExtBridge = window.biliExtBridge || {};
  window.biliExtBridge.openSchema = function(url, callback) {
    var payload = {url: url};
    var id = registerCallback(callback);
    if (id) payload.callbackId = id;
    post('biliInject', {method: 'app.openSchema', data: payload});
  };
  window.biliExtBridge.getUserInfo = function(callback) {
    var payload = {};
    var id = registerCallback(callback);
    if (id) payload.callbackId = id;
    post('biliInject', {method: 'app.getUserInfo', data: payload});
  };
  window.biliExtBridge.validateLogin = function(callback) {
    var payload = {};
    var id = registerCallback(callback);
    if (id) payload.callbackId = id;
    post('biliInject', {method: 'app.validateLogin', data: payload});
  };
})();
''';
}
