import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

/// B2 账号 cookie 持久化格式的回归。
///
/// 持久化形状从「name → value 标量」改成「name → 属性 map」，同时保留旧格式
/// 读取兼容（[BiliCookieJar.fromJson]）。这些用例钉住三件事：
/// 1. 旧数据仍读得进，值与关键语义不丢；
/// 2. 新格式写入 → 读回幂等，domain/path/httpOnly/secure/expires 不丢；
/// 3. SESSDATA / bili_jct / DedeUserID 这类会话凭据迁移后 httpOnly 为 true。
///
/// 纯函数级：不打开 Hive box，不发请求。
void main() {
  /// 会话凭据：迁移路径（[BiliCookie.setBiliDomain]）必须给它们补 HttpOnly。
  const sessionCookieNames = ['SESSDATA', 'bili_jct', 'DedeUserID'];

  /// 旧格式：改名之前 Hive 里已存在的历史数据形状。
  const legacyStored = <String, dynamic>{
    'SESSDATA': 'sess_legacy',
    'bili_jct': 'csrf_legacy',
    'DedeUserID': '10086',
    'buvid3': 'buvid-legacy',
  };

  /// 新格式：改版之后 [BiliCookieJar.toJson] 写出的形状。
  Map<String, dynamic> newFormatStored() => <String, dynamic>{
    'SESSDATA': <String, dynamic>{
      'name': 'SESSDATA',
      'value': 'sess_new',
      'domain': '.bilibili.com',
      'path': '/',
      'httpOnly': true,
      'secure': true,
      'expires': DateTime.utc(2027, 1, 2, 3, 4, 5),
    },
    'buvid3': <String, dynamic>{
      'name': 'buvid3',
      'value': 'buvid-new',
      'domain': '.bilibili.com',
      'path': '/',
      'httpOnly': false,
      'secure': true,
      'expires': null,
    },
    'apiCookie': <String, dynamic>{
      'name': 'apiCookie',
      'value': 'api-new',
      'domain': '.bilibili.com',
      'path': '/x/v2/',
      'httpOnly': false,
      'secure': false,
      'expires': null,
    },
  };

  Map<String, SerializableCookie> storedCookies(
    DefaultCookieJar jar,
    String domain,
    String path,
  ) => jar.domainCookies[domain]![path]!;

  group('旧格式（标量）读取兼容', () {
    test('读入不抛异常，name/value 原样保留', () {
      final jar = BiliCookieJar.fromJson(legacyStored);
      final cookies = storedCookies(jar, 'bilibili.com', '/');

      expect(cookies.keys, containsAll(legacyStored.keys));
      for (final entry in legacyStored.entries) {
        final cookie = cookies[entry.key]!.cookie;
        expect(cookie.name, entry.key);
        expect(
          cookie.value,
          entry.value,
          reason: '${entry.key} 的值在旧格式迁移中丢失',
        );
      }
    });

    test('补齐 domain / path 默认值，仍落在 bilibili.com 的根路径下', () {
      final jar = BiliCookieJar.fromJson(legacyStored);

      expect(jar.toList(), hasLength(legacyStored.length));
      for (final cookie in jar.toList()) {
        expect(cookie.domain, '.bilibili.com');
        expect(cookie.path, '/');
      }
    });

    test('会话凭据补上 HttpOnly 语义', () {
      final jar = BiliCookieJar.fromJson(legacyStored);
      final cookies = storedCookies(jar, 'bilibili.com', '/');

      for (final name in sessionCookieNames) {
        expect(
          cookies[name]!.cookie.httpOnly,
          isTrue,
          reason: '$name 在迁移后必须是 HttpOnly',
        );
      }
      // 非会话 cookie 的 httpOnly 由 Cookie 构造器默认值决定（本 SDK 为 true），
      // 旧格式里没有这个字段可读，所以这里不钉它；新格式显式写 false 的保留由
      // 下面的 round-trip 用例覆盖。
    });

    test('旧格式重新写出即为新格式（属性 map）', () {
      final written = BiliCookieJar.fromJson(legacyStored).toJson();

      expect(written.keys, containsAll(legacyStored.keys));
      final sessdata = written['SESSDATA'];
      expect(sessdata, isA<Map<String, dynamic>>());
      expect((sessdata as Map)['value'], 'sess_legacy');
      expect(sessdata['httpOnly'], isTrue);
      expect(sessdata['domain'], '.bilibili.com');
      expect(sessdata['path'], '/');
    });
  });

  group('新格式 round-trip', () {
    test('toJson → fromJson → toJson 等价', () {
      final written = BiliCookieJar.fromJson(newFormatStored()).toJson();
      final restored = BiliCookieJar.fromJson(written);

      expect(
        restored.toJson(),
        equals(written),
        reason: '写出的持久化 map 必须是 toJson/fromJson 的不动点',
      );
    });

    test('domain / path / httpOnly / secure / expires 逐项不丢', () {
      final source = BiliCookieJar.fromJson(newFormatStored());
      final restored = BiliCookieJar.fromJson(source.toJson());

      void expectSame(String domain, String path) {
        final before = storedCookies(source, domain, path);
        final after = storedCookies(restored, domain, path);
        expect(
          after.keys,
          equals(before.keys),
          reason: '$domain$path 的 cookie 集合变化',
        );
        for (final entry in before.entries) {
          final a = entry.value.cookie;
          final b = after[entry.key]!.cookie;
          expect(b.name, a.name);
          expect(b.value, a.value);
          expect(b.domain, a.domain);
          expect(b.path, a.path);
          expect(b.httpOnly, a.httpOnly);
          expect(b.secure, a.secure);
          expect(b.expires, a.expires);
        }
      }

      expectSame('bilibili.com', '/');
      expectSame('bilibili.com', '/x/v2/');
    });

    test('路径与过期时间在新格式里真实生效，不被归一化掉', () {
      final jar = BiliCookieJar.fromJson(newFormatStored());
      final rootCookies = storedCookies(jar, 'bilibili.com', '/');

      expect(rootCookies, isNot(contains('apiCookie')));
      expect(storedCookies(jar, 'bilibili.com', '/x/v2/').keys, ['apiCookie']);
      expect(
        rootCookies['SESSDATA']!.cookie.expires,
        DateTime.utc(2027, 1, 2, 3, 4, 5),
      );
      expect(rootCookies['SESSDATA']!.cookie.secure, isTrue);
      expect(rootCookies['SESSDATA']!.cookie.httpOnly, isTrue);
      expect(
        rootCookies['buvid3']!.cookie.httpOnly,
        isFalse,
        reason: '新格式显式写入 httpOnly:false 时必须原样保留',
      );
    });
  });

  test('新旧格式混在同一个持久化 map 里也能读入（升级中途）', () {
    final jar = BiliCookieJar.fromJson(<String, dynamic>{
      'DedeUserID': <String, dynamic>{
        'name': 'DedeUserID',
        'value': '10086',
        'domain': '.bilibili.com',
        'path': '/',
        'httpOnly': true,
        'secure': true,
        'expires': null,
      },
      'bili_jct': 'csrf_legacy',
    });
    final cookies = storedCookies(jar, 'bilibili.com', '/');

    expect(cookies['DedeUserID']!.cookie.value, '10086');
    expect(cookies['DedeUserID']!.cookie.httpOnly, isTrue);
    expect(cookies['DedeUserID']!.cookie.secure, isTrue);
    expect(cookies['bili_jct']!.cookie.value, 'csrf_legacy');
    expect(cookies['bili_jct']!.cookie.httpOnly, isTrue);
  });
}
