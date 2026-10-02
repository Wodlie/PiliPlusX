import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/fawkes.pb.dart';
import 'package:PiliPlus/grpc/bilibili/metadata/locale.pb.dart';
import 'package:PiliPlus/utils/accounts/app_device_profile.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// 对照官方国内客户端（`tv.danmaku.bili` 9.13.0）核过的逐字段保真测试。
///
/// 依据：`reverse-output/device-fields/REPORT.md`（§1–§7）与
/// `reverse-output/device-fields/evidence/official/`。
///
/// 这些用例都是**纯函数级**的（不碰 `Pref`/`Hive`/网络），
/// 用来把"取值语义"钉住，防止以后被无意改回去。
void main() {
  // 必须用**校验通过**的 BUVID：`deriveProfile` 会 validate storedProfile，
  // 不合法就重新生成，那样断言就拿不到传入值了。
  final buvid = IdentityCoreGenerators.deriveBuvidFromSeed('fidelity-seed');
  const userAgent = 'UA/test';

  group('设备档案派生字段', () {
    test('device_name / device_platform 用厂商+型号裸拼（官方无分隔符）', () {
      // 官方 `PassportCommParams.getDeviceName()`：
      //   androidx.camera.core.impl.i.a(Build.MANUFACTURER, Build.MODEL) -> str + str2
      // 官方 `getDevicePlatFrom()`：
      //   C.i.a("Android", VERSION.RELEASE, MANUFACTURER, MODEL) -> 四串裸拼
      final profile = AppDeviceProfile(
        brand: 'xiaomi',
        model: 'mi 14',
        osver: '15',
      );

      expect(profile.brand, 'Xiaomi'); // 别名归一
      expect(profile.model, 'MI 14');
      expect(profile.deviceName, 'XiaomiMI 14');
      expect(profile.devicePlatform, 'Android15XiaomiMI 14');
      // 不含真机信息：这里用的是伪装档案的 brand/model。
      expect(profile.deviceName.contains('Build'), isFalse);
    });

    test('国内档案带 Fawkes 档位串 android64', () {
      expect(AppDeviceProfiles.android.fawkesAppKey, 'android64');
      expect(AppDeviceProfiles.android.mobiApp, 'android');
    });
  });

  group('REST 头', () {
    final identity = RequestIdentityAdapter.fromBuvid(
      buvid: buvid,
      userAgent: userAgent,
    );

    test('保留 H5 逆向来的公共头（所有请求都发）', () {
      final headers = identity.appHeaders(userAgent: userAgent);

      // `env` / `app-key` 来自官方 H5/WebView 桥接路径，本项目所有请求都保留。
      expect(headers['env'], 'prod');
      expect(headers['app-key'], AppDeviceProfiles.android.appKey);
      expect(
        headers['x-bili-aurora-zone'],
        Constants.baseHeaders['x-bili-aurora-zone'],
      );
      expect(headers['user-agent'], userAgent);
    });

    test('bili-rest-engine + bili-http-engine 与官方 moss/rest 栈一致', () {
      final headers = identity.appHeaders(userAgent: userAgent);

      // 官方 moss/rest 栈**同时**发这两个头
      // （`Fn1/a.java:78` + `Bb1/d.java:58-62`）；
      // `cronet` 是官方支持的引擎名之一（包内存在 `moss_grpc_cronet` 等配置键）。
      expect(headers['bili-rest-engine'], 'moss');
      expect(headers['bili-http-engine'], 'cronet');
    });

    test('x-bili-mid 无条件发送，访客为空串', () {
      final headers = identity.appHeaders(userAgent: userAgent);

      // 官方全局 aurora 拦截器 `p087dm1/a.java:50-57`：`jMid > 0` 才填值，
      // 否则保持默认空串 —— 但**总是设置这个头**。
      expect(headers.containsKey('x-bili-mid'), isTrue);
      expect(headers['x-bili-mid'], isEmpty);
    });

    test('fp/session 字段仍按 owner 派生且 fp_remote 与 fp_local 同源', () {
      final fields = identity.appIdentityHeaders;

      expect(fields['fp_local'], identity.fpLocal);
      expect(fields['fp_remote'], identity.fpLocal);
      expect(fields['session_id'], identity.sessionId);
      expect(
        IdentityCoreGenerators.validateFp(fields['fp_local']!).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateSessionId(fields['session_id']!).isValid,
        isTrue,
      );
    });

    test('登录体三值遵循官方语义', () {
      final fields = identity.loginPayloadFields;

      // local_id = BUVID；bili_local_id / device_id = fp_local（本项目不做设备级存储）。
      expect(fields['local_id'], identity.buvid);
      expect(fields['bili_local_id'], identity.fpLocal);
      expect(fields['device_id'], identity.fpLocal);
      expect(fields['device_name'], identity.deviceName);
      expect(fields['device_platform'], identity.devicePlatform);
    });
  });

  group('x-bili-aurora-eid', () {
    test('保留 Base64 padding（官方两套实现都带 =）', () {
      // 官方 gRPC `kntr/base/net/comm/m.java:45` Kotlin `Base64.Default`、
      // REST `p087dm1/a.java:43` → `Wl1.a.a()` → android `Base64(..., 10)`
      // = `URL_SAFE|NO_WRAP` —— 两者都带 padding；
      // 真机抓包 `UlEFQFcBAFgFWk9YWFcDQg==`（24 字符，带 ==）。
      const mid = 3546656926599324;
      final eid = IdUtils.genAuroraEid(mid);

      expect(eid.endsWith('=='), isTrue);
      expect(eid.length % 4, 0);
      // 与抓包值逐字节一致（算法 = mid 十进制串逐字节 XOR "ad1va46a7lza"）。
      expect(eid, 'UlEFQFcBAFgFWk9YWFcDQg==');
    });

    test('两条路径字母表不同，但取值集合上不可观测', () {
      // REST 用 URL-safe（`Wl1.a.a()`），gRPC 用标准字母表（`m.c()`）；
      // 但载荷是「十进制数字 ASCII XOR 密钥」，6-bit 组永远落不到 62/63，
      // 因此 `+`/`/` 与 `-`/`_` 在真实 mid 上都不会出现（40 万样本实测 0 次）。
      for (var i = 0; i < 500; i++) {
        final mid = 1000000000000000 + i * 7919;
        final standard = IdUtils.genAuroraEid(mid);
        final urlSafe = IdUtils.genAuroraEid(mid, urlSafe: true);

        expect(urlSafe.length, standard.length);
        expect(
          standard.replaceAll('+', '-').replaceAll('/', '_'),
          urlSafe,
          reason: '两者应当是同一份字节的两种字母表编码',
        );
        for (final ch in ['+', '/', '-', '_']) {
          expect(
            standard.contains(ch) || urlSafe.contains(ch),
            isFalse,
            reason: 'mid=$mid 出现了字母表特殊字符（与实测不符，需复核算法）',
          );
        }
      }
    });

    test('未登录返回空串', () {
      expect(IdUtils.genAuroraEid(0), '');
    });
  });

  group('gRPC 固定头', () {
    test('x-bili-fawkes-req-bin 的 appkey 是 Fawkes 档位串而非 mobi_app', () {
      final raw = GrpcHeaders.fawkes('abcd1234');
      // gRPC 的 `-bin` metadata 不带 base64 padding。
      expect(raw.contains('='), isFalse);
      final fawkes = FawkesReq.fromBuffer(
        base64Decode(base64.normalize(raw)),
      );

      expect(fawkes.appkey, 'android64');
      expect(fawkes.appkey, isNot(AppDeviceProfiles.android.mobiApp));
      expect(fawkes.env, 'prod');
      expect(fawkes.sessionId, 'abcd1234');
    });

    test('x-bili-locale-bin 是固定头且带 utcOffset', () {
      final raw = GrpcHeaders.localeBin();
      // 与其它 `-bin` 一致：官方 moss 库用 gRPC 的 omit-padding base64。
      expect(raw.contains('='), isFalse);
      final locale = Locale.fromBuffer(
        base64Decode(base64.normalize(raw)),
      );

      expect(locale.cLocale.language, 'zh');
      expect(locale.cLocale.script, 'Hans');
      expect(locale.cLocale.region, 'CN');
      expect(locale.sLocale.language, 'zh');
      expect(locale.timezone, 'Asia/Shanghai');
      // 抓包解码出的第 5 字段。
      expect(locale.utcOffset, '+08:00');
      // 不随设备变动：两次调用完全一致。
      expect(GrpcHeaders.localeBin(), GrpcHeaders.localeBin());
    });
  });

  group('会话与追踪标识', () {
    test('session_id 按 owner 分桶且进程内稳定', () {
      final a1 = IdentityCoreGenerators.generateSessionId(scope: 'account:1');
      final a2 = IdentityCoreGenerators.generateSessionId(scope: 'account:1');
      final b1 = IdentityCoreGenerators.generateSessionId(scope: 'account:2');

      expect(a1, a2);
      expect(a1, isNot(b1));
    });

    test('trace_id 是纯小写 hex 且末 4 字节是大端秒', () {
      final now = DateTime.utc(2026, 5, 6, 12, 0, 0);
      final traceId = IdentityCoreGenerators.generateTraceId(now: now);
      final body = traceId.substring(0, 32);
      final seconds = now.millisecondsSinceEpoch ~/ 1000;

      expect(RegExp(r'^[0-9a-f]{32}:[0-9a-f]{16}:0:0$').hasMatch(traceId), isTrue);
      expect(body.substring(24, 32), seconds.toRadixString(16).padLeft(8, '0'));
      expect(traceId, '$body:${body.substring(16, 32)}:0:0');
      expect(IdentityCoreGenerators.validateTraceId(traceId).isValid, isTrue);
    });
  });
}
