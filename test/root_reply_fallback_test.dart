import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart' as gen;
import 'package:PiliPlus/grpc/bilibili/rpc.pb.dart' show Status;
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart' show Any;
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
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
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 根评论双层路由：正式有效 token 走 gRPC，其余走 REST，并且**两条链各自
/// 维护游标**（绝不把 REST offset 送进 gRPC cursor，反之亦然）。
///
/// 全部使用内存 adapter：真实 `Request` / `AccountManager` / `GrpcReq` /
/// `ReplyRest`，但不发任何真实请求。评论页只读已发布的健康状态，不会在这里
/// 触发账号校验（用例显式断言这一点）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _RootAdapter adapter;
  late HttpClientAdapter originalAdapter;
  late AccountService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_root_reply_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableHttp2, false);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    await GStorage.setting.put(SettingBoxKey.showBlockedReplyBanner, false);
    await GStorage.setting.put(SettingBoxKey.autoShowFoldedReply, false);
    Request();
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    Request.dio.interceptors.removeWhere((entry) => entry is LogInterceptor);
    // `Request.dio` 是全局单例：保留并还原原 adapter，避免影响同进程的后续测试。
    originalAdapter = Request.dio.httpClientAdapter;
    adapter = _RootAdapter();
    Request.dio.httpClientAdapter = adapter;
    // 刻意不 enableValidation()：评论路径只读已发布状态，不得触发校验请求。
    service = Get.put(AccountService());
  });

  setUp(() {
    adapter.reset();
    // 每个用例都重新注册服务：tearDown 的 Get.reset() 会注销上一个实例，
    // 否则控制器的只读 healthOf 会退回保守 REST，掩盖 gRPC 路径。
    service = Get.put(AccountService());
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

  LoginAccount loginAccount({
    int mid = 8001,
    String? accessKey = 'ACCESS_KEY_8001',
  }) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'csrf_$mid'}),
    accessKey,
    'REFRESH_$mid',
    null,
    IdentityCoreGenerators.deriveBuvidFromSeed('root-$mid'),
    AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
    'android',
  )..activated = true;

  /// 只发布状态，不联网：评论路径必须只读它。
  void publish(Account account, {bool formal = true, bool token = true}) {
    service.seedForTest(
      AccountHealthIdentity.capture(account),
      cookie: formal ? CookieHealth.valid : CookieHealth.invalid,
      token: account.accessKey == null
          ? TokenHealth.missing
          : (token ? TokenHealth.valid : TokenHealth.invalid),
      kind: formal ? AccountKind.formal : AccountKind.unknown,
    );
  }

  VideoReplyController controller() => Get.put(
    VideoReplyController(aid: 12345, videoType: VideoType.ugc, heroTag: 'root'),
  );

  List<int> ids(VideoReplyController ctr) =>
      ctr.loadingState.value.data!.map((r) => r.id.toInt()).toList();

  test('正式有效 token：走 gRPC，游标按 cursor.next 推进', () async {
    final acc = loginAccount();
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    adapter.grpcPages = {
      0: _grpcPage([1, 2], next: 10, isEnd: false),
      10: _grpcPage([3], next: 0, isEnd: true),
    };

    final ctr = controller();
    await ctr.queryData();
    expect(ids(ctr), [1, 2]);
    expect(ctr.isEnd, isFalse);

    await ctr.onLoadMore();
    expect(ids(ctr), [1, 2, 3]);
    expect(ctr.isEnd, isTrue);

    expect(adapter.grpcRequests.length, 2);
    expect(adapter.grpcRequests.map((r) => r.cursor.next.toInt()), [0, 10]);
    // gRPC 链不得发 REST 请求。
    expect(adapter.restRequests, isEmpty);
    // 评论路径不触发账号校验。
    expect(adapter.probePaths, isEmpty);
  });

  test('无 token 的 cookie-only 账号：走 REST，offset 正确转义并翻页', () async {
    final acc = loginAccount(mid: 8002, accessKey: null);
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    adapter.restPages = {
      '': _restPage([11, 12], nextOffset: 'off"set\\2'),
      'off"set\\2': _restPage([12, 13], nextOffset: ''),
    };

    final ctr = controller();
    await ctr.queryData();
    expect(ids(ctr), [11, 12]);
    expect(ctr.isEnd, isFalse);

    await ctr.onLoadMore();
    // 去重保留 12，追加 13。
    expect(ids(ctr), [11, 12, 13]);
    expect(ctr.isEnd, isTrue);

    expect(adapter.restRequests.length, 2);
    expect(adapter.restRequests.first.paginationOffset, '');
    expect(adapter.restRequests.last.paginationOffset, 'off"set\\2');
    expect(
      adapter.restRequests.last.query['pagination_str'],
      jsonEncode({'offset': 'off"set\\2'}),
      reason: 'offset 必须作为 JSON 整体编码，不能手拼转义',
    );
    expect(adapter.grpcRequests, isEmpty);
    expect(adapter.probePaths, isEmpty);
  });

  test('REST 未知总数（count=-1）不按显示条数提前结束', () async {
    final acc = loginAccount(mid: 8003, accessKey: null);
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    // 服务端没有 cursor.all_count，第一条也远小于 count。
    adapter.restPages = {
      '': _restPage([1], nextOffset: 'p2'),
      'p2': _restPage([2], nextOffset: 'p3'),
      'p3': _restPage([3], nextOffset: ''),
    };

    final ctr = controller();
    await ctr.queryData();
    await ctr.onLoadMore();
    await ctr.onLoadMore();
    expect(ids(ctr), [1, 2, 3]);
    expect(ctr.isEnd, isTrue);
  });

  test('REST 空页但仍有 offset：自动续页取到内容，不当作「没有更多」', () async {
    final acc = loginAccount(mid: 8004, accessKey: null);
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    adapter.restPages = {
      '': _restPage([], nextOffset: 'p2'),
      'p2': _restPage([7], nextOffset: ''),
    };

    final ctr = controller();
    // 首屏就没有内容，但服务端仍在推进 offset：必须自己续页，否则界面会停在
    // 「还没有评论」（所有根评论视图只在列表非空时才创建 footer/onLoadMore）。
    await ctr.queryData();
    expect(ids(ctr), [7]);
    expect(ctr.isEnd, isTrue, reason: 'offset 为空才是真结束');
    expect(
      adapter.restRequests.map((r) => r.paginationOffset),
      ['', 'p2'],
    );
  });

  test('REST 游标不推进：报错而不是假装列表结束', () async {
    final acc = loginAccount(mid: 8005, accessKey: null);
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    adapter.restPages = {
      '': _restPage([1], nextOffset: 'loop'),
      'loop': _restPage([2], nextOffset: 'loop'),
    };

    final ctr = controller();
    await ctr.queryData();
    await ctr.onLoadMore();
    expect(ids(ctr), [1], reason: '游标不推进时不追加数据');
    expect(ctr.isEnd, isFalse);
    expect(ctr.loadingState.value.isSuccess, isTrue);
  });

  test('gRPC 明确鉴权失败(-101)：切换 REST 并从首屏替换列表', () async {
    final acc = loginAccount(mid: 8006, accessKey: 'STALE_KEY');
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    adapter.grpcStatus = 0;
    adapter.grpcErrorCode = -101;
    adapter.restPages = {
      '': _restPage([21, 22], nextOffset: ''),
    };

    final ctr = controller();
    await ctr.queryData();

    expect(ids(ctr), [21, 22], reason: '应回退 REST 并替换列表');
    expect(adapter.grpcErrorRequests, 1);
    expect(adapter.restRequests.length, 1);
    // 该凭证被标记失效，后续不再走 gRPC。
    expect(service.healthFor(acc).token, TokenHealth.invalid);
  });

  test('gRPC 状态 9（封禁）不当作 token 过期', () async {
    final acc = loginAccount(mid: 8007, accessKey: 'BANNED_KEY');
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);

    adapter.grpcStatus = 9;
    adapter.grpcMessage = 'request was banned';

    final ctr = controller();
    await ctr.queryData();

    expect(ctr.loadingState.value.isSuccess, isFalse);
    expect(adapter.restRequests, isEmpty, reason: '封禁不是认证结论');
    expect(service.healthFor(acc).token, TokenHealth.valid);
  });

  test('账号在会话中途切换：不追加旧结果，下一次从头判定', () async {
    final first = loginAccount(mid: 8008, accessKey: 'KEY_A');
    Accounts.accountMode[AccountType.main.index] = first;
    publish(first);
    adapter.grpcPages = {
      0: _grpcPage([1], next: 10, isEnd: false),
    };

    final ctr = controller();
    await ctr.queryData();
    expect(ids(ctr), [1]);

    // 切到另一个账号（未校验 → 保守 REST），旧 gRPC 链必须重启。
    final second = loginAccount(mid: 8009, accessKey: null);
    Accounts.accountMode[AccountType.main.index] = second;
    publish(second);
    adapter.restPages = {
      '': _restPage([31, 32], nextOffset: ''),
    };

    await ctr.onLoadMore();
    expect(ids(ctr), [31, 32], reason: '传输变化必须从首屏替换');
    expect(ctr.isEnd, isTrue);
  });

  test('真实 VideoReplyController：列表到末尾后切号，load-more 仍能发现变化', () async {
    // terminal REST（next_offset='' → isEnd=true）。注意 video 控制器外层是
    // `ReplyFoldMixin.queryData`，它的 `(!isRefresh && isEnd)` 守卫位于
    // RootReplyController 之上：预检必须在最外层 onLoadMore 也生效，
    // 否则账号变化永远发现不了，界面停在上一个账号的内容上。
    final first = loginAccount(mid: 8010, accessKey: null);
    Accounts.accountMode[AccountType.main.index] = first;
    publish(first);
    adapter.restPagesByMid = {
      8010: _restPage([1], nextOffset: ''),
      8011: _restPage([2], nextOffset: ''),
      8012: _restPage([3], nextOffset: ''),
      8013: _restPage([4], nextOffset: ''),
    };

    final ctr = controller();
    await ctr.queryData();
    expect(ids(ctr), [1]);
    expect(ctr.isEnd, isTrue, reason: 'terminal：基类 load-more 会被 isEnd 拦下');

    var expected = 2;
    for (final mid in [8011, 8012, 8013]) {
      final next = loginAccount(mid: mid, accessKey: null);
      Accounts.accountMode[AccountType.main.index] = next;
      publish(next);

      await ctr.onLoadMore();

      expect(
        ids(ctr),
        [expected],
        reason: 'terminal 列表也必须换成新账号首屏（内容逐账号不同，避免假阳性）',
      );
      expected++;
    }
    expect(adapter.restRequests.length, 4);
  });
}

gen.MainListReply _grpcPage(
  List<int> ids, {
  required int next,
  required bool isEnd,
}) => gen.MainListReply(
  cursor: gen.CursorReply(next: Int64(next), isEnd: isEnd),
  subjectControl: gen.SubjectControl(count: Int64(100)),
  replies: ids.map((id) => gen.ReplyInfo(id: Int64(id))).toList(),
);

Map<String, dynamic> _restPage(
  List<int> ids, {
  required String nextOffset,
}) => {
  'cursor': {
    'is_end': nextOffset.isEmpty,
    'all_count': -1,
    'pagination_reply': {'next_offset': nextOffset},
  },
  'replies': [
    for (final id in ids)
      {
        'rpid': id,
        'oid': 12345,
        'type': 1,
        'mid': 4242,
        'like': 3,
        'ctime': 1700000000,
        'content': {'message': 'reply $id'},
        'member': {
          'mid': '4242',
          'uname': 'user$id',
          'avatar': 'https://example.invalid/a.png',
          'level_info': {'current_level': 5},
          'vip': {'vipStatus': 1, 'vipType': 2},
        },
        'reply_control': {'time_desc': '1天前'},
      },
  ],
};

class _RootAdapter implements HttpClientAdapter {
  final grpcRequests = <gen.MainListReq>[];
  final restRequests = <_RestRequest>[];
  final probePaths = <String>[];

  Map<int, gen.MainListReply> grpcPages = const {};
  Map<String, Map<String, dynamic>> restPages = const {};

  /// 按账号区分的 REST 首屏（切号用例：内容不同才不会有旧列表假阳性）。
  Map<int, Map<String, dynamic>> restPagesByMid = const {};
  int grpcStatus = 0;
  String? grpcMessage;
  int? grpcErrorCode;
  int grpcErrorRequests = 0;

  void reset() {
    grpcRequests.clear();
    restRequests.clear();
    probePaths.clear();
    grpcPages = const {};
    restPages = const {};
    restPagesByMid = const {};
    grpcStatus = 0;
    grpcMessage = null;
    grpcErrorCode = null;
    grpcErrorRequests = 0;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/x/web-interface/nav' || path == '/x/space/myinfo') {
      probePaths.add(path);
      return ResponseBody.fromString(
        jsonEncode({'code': -404}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (path == GrpcUrl.mainList) {
      final req = gen.MainListReq.fromBuffer(
        GrpcReq.decompressProtobuf(options.data as Uint8List),
      );
      grpcRequests.add(req);

      if (grpcErrorCode != null) {
        grpcErrorRequests++;
        // app 层业务码走 `grpc-status != 0` + details 内层 Status
        // （GrpcReq 的解析路径），不是 status 0 的成功响应。
        return ResponseBody.fromBytes(
          Uint8List(0),
          200,
          headers: {
            'grpc-status': ['2'],
            'grpc-status-details-bin': [
              base64Encode(
                Status(
                  code: 2,
                  message: 'auth',
                  details: [
                    Any(
                      value: Status(
                        code: grpcErrorCode,
                        message: 'auth',
                      ).writeToBuffer(),
                    ),
                  ],
                ).writeToBuffer(),
              ),
            ],
            Headers.contentTypeHeader: ['application/grpc'],
          },
        );
      }
      if (grpcStatus != 0) {
        return ResponseBody.fromBytes(
          Uint8List(0),
          200,
          headers: {
            'grpc-status': ['$grpcStatus'],
            if (grpcMessage != null) 'grpc-message': [grpcMessage!],
            Headers.contentTypeHeader: ['application/grpc'],
          },
        );
      }
      final page = grpcPages[req.cursor.next.toInt()];
      if (page == null) {
        throw StateError('no gRPC page for cursor ${req.cursor.next}');
      }
      return ResponseBody.fromBytes(
        GrpcReq.compressProtobuf(page.writeToBuffer()),
        200,
        headers: {
          'grpc-status': ['0'],
          Headers.contentTypeHeader: ['application/grpc'],
        },
      );
    }
    if (path == Api.replyMain) {
      final rawOffset = options.queryParameters['pagination_str'];
      final offset = rawOffset is String
          ? ((jsonDecode(rawOffset) as Map)['offset'] as String? ?? '')
          : '';
      restRequests.add(
        _RestRequest(
          paginationOffset: offset,
          query: Map<String, dynamic>.from(options.queryParameters),
        ),
      );
      final bound = options.extra['account'];
      final mid = bound is Account ? bound.mid : 0;
      final page = restPagesByMid[mid] ?? restPages[offset];
      if (page == null) {
        return ResponseBody.fromString(
          jsonEncode({
            'code': 0,
            'data': {'replies': [], 'cursor': {}},
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      return ResponseBody.fromString(
        jsonEncode({'code': 0, 'data': page}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    throw StateError('unexpected offline request: $path');
  }

  @override
  void close({bool force = false}) {}
}

class _RestRequest {
  const _RestRequest({required this.paginationOffset, required this.query});

  final String paginationOffset;
  final Map<String, dynamic> query;
}
