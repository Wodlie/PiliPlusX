import 'package:PiliPlus/http/api_hosts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

/// Custom host URL rewriting interceptor for the Dio HTTP client.
///
/// Replaces official BiliBili API hosts with user-configured custom hosts
/// (configured via settings → custom API hosts).
///
/// Registered before [HkApiRetryInterceptor] in the interceptor chain,
/// so URL rewriting happens before HK retry logic.
///
/// ── Investigation Findings ──
///
/// 1. Cookie Injection:
///    Cookie handling uses manual interceptor injection (AccountManager),
///    NOT Dio CookieManager. The account cookie jar is keyed by the
///    OFFICIAL bilibili domains, so AccountManager maps custom API hosts
///    back to their official host first (officializeUri in account_mgr.dart)
///    before loading/injecting cookies. Cookies are therefore still sent
///    to custom API hosts — authentication does not break.
///
/// 2. Interceptor chain order (init.dart:236-255):
///    - RetryInterceptor (line 238-240) — request retries
///    - CustomHostInterceptor (HERE) — URL rewriting (inserted before HK)
///    - HkApiRetryInterceptor (line 244) — HK proxy fallback on -404/-10403
///    - LogInterceptor (line 247-254, debug only) — request/response logging
///
/// 3. Non-Dio HTTP requests:
///    A search for HttpClient/http.get/http.post usage across lib/ found
///    no direct HTTP calls to BiliBili endpoints outside Dio. The only
///    HttpClient references are within Dio's IOHttpClientAdapter setup
///    (init.dart:157-166) and Flutter's own override (main.dart:379-380).
///    gRPC calls use a separate gRPC client (not Dio) and are out of scope.
///
/// 4. HK proxy interaction:
///    When Pref.apiHKUrl is non-empty AND the request method is GET,
///    this interceptor skips rewriting so the HkApiRetryInterceptor
///    can attempt the official host first and fall back to the HK proxy
///    only on -404/-10403 errors.
class CustomHostInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // 1. Check master toggle
    if (!Pref.enableCustomApiHost) {
      return handler.next(options);
    }

    // 2. Priority check: if HK proxy is configured, skip GET requests
    //    so the HK retry interceptor handles them on failure.
    if (Pref.apiHKUrl.isNotEmpty && options.method.toUpperCase() == 'GET') {
      return handler.next(options);
    }

    // 3. Build host mapping: officialHost -> customHost
    final Map<String, String> hostMap = {};
    for (final entry in apiHostEntries) {
      final customHost =
          GStorage.setting.get(entry.settingKey, defaultValue: '') as String;
      // Skip malformed stored values defensively (they would otherwise
      // break Uri.parse below / the Dio URL construction).
      if (customHost.isNotEmpty && isValidCustomHost(customHost)) {
        hostMap[entry.defaultHost] = customHost;
      }
    }

    if (hostMap.isEmpty) {
      return handler.next(options);
    }

    // 4. Handle full URLs (options.path starts with http)
    if (options.path.startsWith('http')) {
      final uri = Uri.parse(options.path);
      final origin = '${uri.scheme}://${uri.host}';

      if (hostMap.containsKey(origin)) {
        final customUri = Uri.parse(hostMap[origin]!);
        // Replace the origin while keeping the custom host's own path
        // prefix (mirror / reverse-proxy setups, e.g.
        // https://mirror.example.com/bili) — Uri.replace alone would
        // drop the prefix. The request's path/query/fragment are kept.
        final prefix = customUri.path.endsWith('/')
            ? customUri.path.substring(0, customUri.path.length - 1)
            : customUri.path;
        var rewritten = customUri
            .replace(path: '$prefix${uri.path}')
            .toString();
        if (uri.hasQuery) {
          rewritten += (rewritten.contains('?') ? '&' : '?') + uri.query;
        }
        if (uri.hasFragment) {
          rewritten += '#${uri.fragment}';
        }
        options.path = rewritten;
      }
    } else {
      // 5. Handle relative paths: check options.baseUrl
      if (hostMap.containsKey(options.baseUrl)) {
        options.baseUrl = hostMap[options.baseUrl]!;
      }
    }

    handler.next(options);
  }
}
