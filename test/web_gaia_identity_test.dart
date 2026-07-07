import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/identity_core/identity_generators.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'pili_web_gaia_identity_test_',
    );
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
  });

  tearDown(() async {
    await GStorage.clear();
  });

  tearDownAll(() async {
    await GStorage.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('web identity fields derive from owner-scoped adapter', () {
    final account = _createLoginAccount(
      mid: 3301,
      buvid: IdentityCoreGenerators.generateBuvid(),
    );
    final identity = RequestIdentityAdapter.fromAccount(
      account: account,
      userAgent: 'Mozilla/5.0',
    );

    expect(
      identity.webDeviceQueryFields(spmid: '333.1387'),
      containsPair(
        'x-bili-device-req-json',
        '{"platform":"web","device":"pc","spmid":"333.1387"}',
      ),
    );

    final dmFields = identity.webDmImageQueryFields;
    expect(dmFields, containsPair('dm_img_list', '[]'));
    expect(dmFields['dm_img_str'], isNotEmpty);
    expect(dmFields['dm_cover_img_str'], isNotEmpty);
    expect(dmFields['dm_img_inter'], '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}');
    expect(
      dmFields['dm_img_str'],
      equals(identity.webDmImageQueryFields['dm_img_str']),
    );
    expect(
      dmFields['dm_cover_img_str'],
      equals(identity.webDmImageQueryFields['dm_cover_img_str']),
    );
  });

  test(
    'video and live app requests expose validated owner-scoped fp and session fields',
    () {
      final account = _createLoginAccount(
        mid: 3302,
        buvid: IdentityCoreGenerators.generateBuvid(),
      );

      final identity = RequestIdentityAdapter.fromAccount(
        account: account,
        userAgent: Constants.userAgentApp,
      );

      final videoHeaders = VideoHttp.recommendAppIdentityHeaders(account);
      final liveHeaders = LiveHttp.appIdentityHeaders(account);

      expect(videoHeaders['fp_local'], identity.fpLocal);
      expect(videoHeaders['fp_remote'], identity.fpRemote);
      expect(
        IdentityCoreGenerators.validateSessionId(
          videoHeaders['session_id']!,
        ).isValid,
        isTrue,
      );
      expect(liveHeaders['fp_local'], identity.fpLocal);
      expect(liveHeaders['fp_remote'], identity.fpRemote);
      expect(
        IdentityCoreGenerators.validateSessionId(
          liveHeaders['session_id']!,
        ).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateFp(videoHeaders['fp_local']!).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateFp(videoHeaders['fp_remote']!).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateSessionId(
          videoHeaders['session_id']!,
        ).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateFp(liveHeaders['fp_local']!).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateFp(liveHeaders['fp_remote']!).isValid,
        isTrue,
      );
      expect(
        IdentityCoreGenerators.validateSessionId(
          liveHeaders['session_id']!,
        ).isValid,
        isTrue,
      );
      expect(videoHeaders['session_id'], isNot('11111111'));
      expect(
        videoHeaders['fp_local'],
        isNot(
          '1111111111111111111111111111111111111111111111111111111111111111',
        ),
      );
      expect(liveHeaders['session_id'], isNot('11111111'));
      expect(
        liveHeaders['fp_local'],
        isNot(
          '1111111111111111111111111111111111111111111111111111111111111111',
        ),
      );
    },
  );

  test('gaia workflow fields are preserved without local synthesis', () {
    expect(RequestIdentityAdapter.preserveGaiaFields(), isEmpty);
    expect(RequestIdentityAdapter.gaiaCookieHeaders(), isEmpty);

    expect(
      RequestIdentityAdapter.preserveGaiaFields(
        gaiaVtoken: 'gaia-token',
        vVoucher: 'voucher-token',
        griskId: 'risk-id',
      ),
      equals({
        'gaia_vtoken': 'gaia-token',
        'v_voucher': 'voucher-token',
        'grisk_id': 'risk-id',
      }),
    );
    expect(
      RequestIdentityAdapter.gaiaCookieHeaders(gaiaVtoken: 'gaia-token'),
      equals({'cookie': 'x-bili-gaia-vtoken=gaia-token'}),
    );
  });
}

LoginAccount _createLoginAccount({
  required int mid,
  required String buvid,
  Set<AccountType>? type,
}) {
  return LoginAccount(
    _createCookieJar(mid: mid),
    'ACCESS_KEY_$mid',
    'REFRESH_$mid',
    type,
    buvid,
  );
}

DefaultCookieJar _createCookieJar({required int mid}) {
  final cookieJar = DefaultCookieJar(ignoreExpires: true);
  final cookies = <Cookie>[
    Cookie('DedeUserID', '$mid')..setBiliDomain(),
    Cookie('bili_jct', 'csrf_$mid')..setBiliDomain(),
    Cookie('SESSDATA', 'sess_$mid')..setBiliDomain(),
  ];
  cookieJar.domainCookies['bilibili.com'] = {
    '/': {
      for (final cookie in cookies) cookie.name: SerializableCookie(cookie),
    },
  };
  return cookieJar;
}
