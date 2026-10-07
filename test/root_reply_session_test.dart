import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart' as gen;
import 'package:PiliPlus/grpc/bilibili/rpc.pb.dart' show Status;
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/reply.dart' show ReplyGrpc;
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart' as state;
import 'package:PiliPlus/http/root_reply.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
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
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart' show Any;

import 'support/test_root_reply_controller.dart';

/// 根评论回退链路的回归（REST 过滤 / 空首页自动追页 / 游标推进与回滚 /
/// 在飞过时结果 / 传输切换 / UP 置顶标志）。
///
/// 全部走内存 adapter：真实 `Request` / `AccountManager` / `GrpcReq` /
/// `ReplyRest` / `RootReplySession` / `RootReplyController`，不发真实请求。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _RootAdapter adapter;
  late HttpClientAdapter originalAdapter;
  late AccountService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili_root_reply2_test_');
    debugSetAppSupportDirPath(tempDir.path);
    await GStorage.init();
    await GStorage.setting.put(SettingBoxKey.retryCount, 0);
    await GStorage.setting.put(SettingBoxKey.enableHttp2, false);
    await GStorage.setting.put(SettingBoxKey.enableCustomApiHost, false);
    await GStorage.setting.put(SettingBoxKey.showBlockedReplyBanner, false);
    await GStorage.setting.put(SettingBoxKey.autoShowFoldedReply, false);
    await GStorage.setting.put(SettingBoxKey.antiGoodsReply, true);
    await GStorage.setting.put(SettingBoxKey.banWordForReply, '');
    await GStorage.setting.put(SettingBoxKey.minLevelForReply, 0);
    await GStorage.setting.put(SettingBoxKey.enableAtFilter, false);
    await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, false);
    Request();
    Request.accountManager = AccountManager();
    Request.dio.interceptors.add(Request.accountManager);
    Request.dio.interceptors.removeWhere(
      (entry) => entry.runtimeType.toString().contains('LogInterceptor'),
    );
    originalAdapter = Request.dio.httpClientAdapter;
    adapter = _RootAdapter();
    Request.dio.httpClientAdapter = adapter;
    // 刻意不 enableValidation()：评论路径只读已发布状态，不得触发校验请求。
    service = Get.put(AccountService());
  });

  setUp(() {
    adapter.reset();
    service = Get.put(AccountService());
    // 屏蔽规则的静态缓存属于全局：每例重置，避免跨例串味。
    ReplyGrpc.showBlockedReplyBanner = false;
    ReplyGrpc.antiGoodsReply = true;
    ReplyGrpc.clearBlockedReasons();
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

  LoginAccount loginAccount({int mid = 8301, bool token = true}) =>
      LoginAccount(
        BiliCookieJar.fromJson({
          'DedeUserID': '$mid',
          'bili_jct': 'csrf_$mid',
        }),
        token ? 'ACCESS_KEY_$mid' : null,
        'REFRESH_$mid',
        null,
        IdentityCoreGenerators.deriveBuvidFromSeed('root2-$mid'),
        AppDeviceProfiles.defaultDeviceProfileForOwner('account:$mid'),
        'android',
      )..activated = true;

  void publish(
    Account account, {
    bool cookie = true,
    bool token = true,
    AccountKind kind = AccountKind.formal,
  }) {
    service.seedForTest(
      AccountHealthIdentity.capture(account),
      cookie: cookie ? CookieHealth.valid : CookieHealth.invalid,
      token: account.accessKey == null
          ? TokenHealth.missing
          : (token ? TokenHealth.valid : TokenHealth.invalid),
      kind: kind,
    );
  }

  TestRootReplyController controller() =>
      Get.put(TestRootReplyController(oid: 12345, replyType: 1));

  List<int> ids(TestRootReplyController ctr) =>
      ctr.loadingState.value.dataOrNull?.map((r) => r.id.toInt()).toList() ??
      [];

  /// cookie-only 账号：确定性走 REST。
  TestRootReplyController restController({int mid = 8302}) {
    final acc = loginAccount(mid: mid, token: false);
    Accounts.accountMode[AccountType.main.index] = acc;
    publish(acc);
    return controller();
  }

  group('REST 空首页自动追页', () {
    test('首屏服务端空页但 offset 仍在：自动续页拿到内容，无需手动 onLoadMore', () async {
      adapter.restPages = {
        '': _restPage(const [], nextOffset: 'p2'),
        'p2': _restPage([11, 12], nextOffset: ''),
      };
      final ctr = restController();

      // 注意：这里**没有**调用 onLoadMore —— 旧实现在这种情况下会把
      // Success([]) 直接落地，而所有根评论视图只在列表非空时才创建
      // footer/onLoadMore，界面会永远停在「还没有评论」。
      await ctr.queryData();

      expect(ids(ctr), [11, 12]);
      expect(ctr.isEnd, isTrue, reason: 'offset 为空才是真结束');
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', 'p2'],
        reason: '必须自己续页，而不是把空页丢给 UI',
      );
      expect(adapter.probePaths, isEmpty, reason: '评论路径不得触发账号校验');
    });

    test('整页被屏蔽（非横幅模式）：自动续页，屏蔽规则与 gRPC 完全一致', () async {
      ReplyGrpc.antiGoodsReply = true;
      ReplyGrpc.showBlockedReplyBanner = false;
      adapter.restPages = {
        '': _restPage([_goodsReplyJson(9001)], nextOffset: 'p2'),
        'p2': _restPage([_plainReplyJson(9002)], nextOffset: ''),
      };
      final ctr = restController(mid: 8303);

      await ctr.queryData();

      expect(ids(ctr), [9002], reason: '带货评论必须与 gRPC 一样被移除');
      expect(adapter.restRequests, hasLength(2));
    });

    test('横幅模式：屏蔽项保留在列表里并登记原因，不自动翻页', () async {
      ReplyGrpc.showBlockedReplyBanner = true;
      adapter.restPages = {
        '': _restPage([_goodsReplyJson(9003)], nextOffset: 'p2'),
        'p2': _restPage([_plainReplyJson(9004)], nextOffset: ''),
      };
      final ctr = restController(mid: 8304);

      await ctr.queryData();

      expect(ids(ctr), [9003], reason: '横幅模式不移除，只标记');
      expect(
        ReplyGrpc.getBriefBlockReason(gen.ReplyInfo(id: Int64(9003))),
        '带货评论',
      );
      expect(adapter.restRequests, hasLength(1), reason: '横幅模式不该自动翻页');
    });

    test('@ 过滤在 REST 路径同样生效', () async {
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, true);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, true);
      final banned = _plainReplyJson(9005);
      (banned['content'] as Map)['message'] = '@only';
      (banned['content'] as Map)['members'] = [
        {'uname': 'only', 'mid': 55},
      ];
      adapter.restPages = {
        '': _restPage([banned], nextOffset: 'p2'),
        'p2': _restPage([_plainReplyJson(9006)], nextOffset: ''),
      };
      final ctr = restController(mid: 8305);

      await ctr.queryData();
      expect(ids(ctr), [9006], reason: '纯 @ 无正文必须被过滤掉');
      await GStorage.setting.put(SettingBoxKey.enableAtFilter, false);
      await GStorage.setting.put(SettingBoxKey.enableAtFilterPureAt, false);
    });

    test('连续空页到达追页上限：可见 Error、isEnd 不变、保留游标，重试可继续', () async {
      // 注意必须给首屏 offset '' 也配上「还有下一页」，否则第一页就是终点。
      // p5 放一条可见评论：重试会从 p5 继续并在这里精确收束，便于逐条断言。
      adapter.restPages = {
        '': _restPage(const [], nextOffset: 'p1'),
        for (var i = 1; i < 5; i++)
          'p$i': _restPage(const [], nextOffset: 'p${i + 1}'),
        'p5': _restPage([77], nextOffset: ''),
      };
      final ctr = restController(mid: 8306);

      await ctr.queryData();

      expect(ctr.loadingState.value, isA<state.Error>());
      expect(
        ctr.loadingState.value,
        isA<state.Error>().having(
          (e) => e.errMsg,
          'errMsg',
          contains('点击重试继续加载'),
        ),
      );
      expect(
        ctr.isEnd,
        isFalse,
        reason: '追页上限不是「列表结束」，绝不能把 isEnd 置真',
      );
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', 'p1', 'p2', 'p3', 'p4'],
        reason: '上限 5 页，不能无限追下去',
      );

      // 「重试」= 从当前游标继续（p5），而不是回首屏重来。
      await ctr.onReload();
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', 'p1', 'p2', 'p3', 'p4', 'p5'],
        reason: '保留游标：重试恰好从 p5 继续，不再回首屏',
      );
      expect(ids(ctr), [77], reason: '重试取到的内容进入列表');
    });
  });

  group('REST 游标推进与失败回滚', () {
    test('正常翻页：成功页推进的 next 不会被下一次 load-more 自拒', () async {
      adapter.restPages = {
        '': _restPage([1], nextOffset: 'p2'),
        'p2': _restPage([2], nextOffset: 'p3'),
        'p3': _restPage([3], nextOffset: ''),
      };
      final ctr = restController(mid: 8307);

      await ctr.queryData();
      expect(ids(ctr), [1]);

      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2], reason: 'p2 必须被真正请求，不能被环检测拒绝');

      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2, 3]);
      expect(ctr.isEnd, isTrue);
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', 'p2', 'p3'],
      );
    });

    test('非首屏请求失败：保留已加载列表，且同一 offset 可以原样重试', () async {
      adapter.restPages = {
        '': _restPage([1], nextOffset: 'p2'),
        'p2': _restPage([2], nextOffset: 'p3'),
        'p3': _restPage([3], nextOffset: ''),
      };
      adapter.failOffsetsOnce = {'p3'};
      final ctr = restController(mid: 8308);

      await ctr.queryData();
      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2]);

      // p3 网络失败：非刷新路径的基类行为是保留原列表（不覆盖成 Error）。
      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2], reason: '失败不得追加内容，也不得清空已加载列表');

      // 失败的那个 offset 必须可以原样重试（不能被自己的环检测永久拉黑）。
      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2, 3]);
      expect(ctr.isEnd, isTrue);
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', 'p2', 'p3', 'p3'],
      );
    });

    test('续页 -101：登记鉴权失败并从 REST 首屏替换列表', () async {
      adapter.restPages = {
        '': _restPage([1], nextOffset: 'p2'),
        'p2': _restPage([2], nextOffset: ''),
      };
      adapter.authFailOffsets = {'p2'};
      final ctr = restController(mid: 8309);

      await ctr.queryData();
      expect(ids(ctr), [1]);

      await ctr.onLoadMore();
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', 'p2', ''],
        reason: '-101 之后必须从首屏重启替换列表',
      );
      expect(ids(ctr), [1], reason: '重启后的首屏内容');
    });

    test('手动刷新会清空游标：重新从首屏取', () async {
      adapter.restPages = {
        '': _restPage([1], nextOffset: 'p2'),
        'p2': _restPage([2], nextOffset: ''),
      };
      final ctr = restController(mid: 8310);

      await ctr.queryData();
      await ctr.onLoadMore();
      expect(ids(ctr), [1, 2]);

      await ctr.onRefresh();
      expect(ids(ctr), [1]);
      expect(adapter.restRequests.last.paginationOffset, '');
    });
  });

  group('UP 置顶标志', () {
    test('REST 的 top.upper 会带上 isUpTop（取消/重设置顶全依赖它）', () async {
      adapter.restPages = {
        '': _restTopReplyPage(upperId: 7001, replyIds: [7001, 7002]),
      };
      final ctr = restController(mid: 8311);

      await ctr.queryData();

      expect(ctr.hasUpTop, isTrue);
      final upTop = ctr.loadingState.value.dataOrNull!.first;
      expect(upTop.id.toInt(), 7001);
      expect(
        upTop.replyControl.isUpTop,
        isTrue,
        reason: '不置位会让「取消置顶」的意图反掉',
      );
      expect(
        ids(ctr),
        [7001, 7002],
        reason: '置顶项插到首位，同时从 replies 中去除重复',
      );
    });
  });

  group('在飞过时结果', () {
    test('gRPC 请求在飞时切换账号：旧结果不落地，也不污染链上游标', () async {
      final first = loginAccount(mid: 8312);
      Accounts.accountMode[AccountType.main.index] = first;
      publish(first);
      adapter.grpcPages = {
        0: _grpcPage([1], next: 10, isEnd: false),
        10: _grpcPage([2], next: 0, isEnd: true),
      };
      adapter.gateGrpcOnce = true;
      final ctr = controller();

      final pending = ctr.queryData();
      await adapter.grpcPaused.future;

      final second = loginAccount(mid: 8313, token: false);
      Accounts.accountMode[AccountType.main.index] = second;
      publish(second);
      adapter.restPages = {
        '': _restPage([21, 22], nextOffset: ''),
      };
      adapter.releaseGrpc();

      await pending;

      expect(ids(ctr), [21, 22], reason: '旧 gRPC 结果必须被丢弃，改为 REST 首屏');
      expect(adapter.restRequests.single.paginationOffset, '');
      expect(ctr.isEnd, isTrue, reason: 'REST next_offset 为空就是列表末尾');
    });

    test('会话换代隔离：reset 后过时 gRPC 响应不得改写新一代游标', () async {
      // 并发刷新不是控制器的合法用法（`onRefresh` 在加载中会按既有约定让路），
      // 所以这里直接在会话层验证「换代在途隔离」。
      final acc = loginAccount(mid: 8314);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.grpcPages = {
        0: _grpcPage([1], next: 10, isEnd: false),
        10: _grpcPage([2], next: 0, isEnd: true),
      };
      // 第一个请求（会被 reset 顶掉）返回一个会污染游标的 next=99。
      adapter.firstGrpcNextOverride = 99;
      adapter.gateGrpcOnce = true;

      final session = RootReplySession(
        healthOf: (account) => service.healthFor(account),
      );
      const oid = 12345;
      const type = 1;
      final stale = session.fetch(
        oid: oid,
        type: type,
        mode: gen.Mode.MAIN_LIST_HOT,
      );
      await adapter.grpcPaused.future;

      // 换代（等价于控制器 reset）：新一代从首屏取并提交 cursor=10。
      session.reset();
      final fresh = await session.fetch(
        oid: oid,
        type: type,
        mode: gen.Mode.MAIN_LIST_HOT,
      );
      expect(fresh, isA<state.Success<gen.MainListReply>>());

      // 放行过时请求：它的 next=99 属于上一代。
      adapter.releaseGrpc();
      expect(await stale, isA<state.Error>());

      final more = await session.fetch(
        oid: oid,
        type: type,
        mode: gen.Mode.MAIN_LIST_HOT,
      );
      expect(more, isA<state.Success<gen.MainListReply>>());
      expect(
        adapter.grpcRequests.map((r) => r.cursor.next.toInt()),
        [0, 0, 10],
        reason: '第三个请求必须从 10 继续；若被污染会去请求 99',
      );
    });

    test('REST 响应轮换 cookie：过时结果丢弃后自动重启，用户无需手动刷新', () async {
      final acc = loginAccount(mid: 8315, token: false);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.restPages = {
        '': _restPage([31], nextOffset: ''),
      };
      adapter.rotateCookieOnce = 'buvid3=ROTATED-8315';
      final ctr = controller();

      await ctr.queryData();

      expect(ids(ctr), [31], reason: '控制器按新凭证自动重启并替换列表');
      expect(
        adapter.restRequests.map((r) => r.paginationOffset),
        ['', ''],
        reason: '第一个请求的过时结果被丢弃，第二个请求才是生效结果',
      );
      expect(
        acc.cookieJar.toJson()['buvid3'],
        'ROTATED-8315',
        reason: 'Set-Cookie 仍由 AccountManager 正常保存（没有绕过）',
      );
    });
  });

  group('生命周期降级', () {
    test('另一会话把 token 标为失效：gRPC 续页立刻改走 REST 首屏', () async {
      final acc = loginAccount(mid: 8316);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.grpcPages = {
        0: _grpcPage([1], next: 10, isEnd: false),
        10: _grpcPage([2], next: 0, isEnd: true),
      };
      adapter.restPages = {
        '': _restPage([41, 42], nextOffset: ''),
      };
      final ctr = controller();

      await ctr.queryData();
      expect(ids(ctr), [1]);

      // 别的会话（例如账号页复检）标记该凭证 token 失效。
      service.markTokenInvalid(AccountHealthIdentity.capture(acc));

      await ctr.onLoadMore();
      expect(ids(ctr), [41, 42], reason: '必须从 REST 首屏替换，不能继续 gRPC');
      expect(adapter.grpcRequests, hasLength(1), reason: '降级后不再发 gRPC');
    });

    test('重检进行中（checking）也改走 REST 首屏，不沿用旧授权', () async {
      final acc = loginAccount(mid: 8317);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.grpcPages = {
        0: _grpcPage([1], next: 10, isEnd: false),
        10: _grpcPage([2], next: 0, isEnd: true),
      };
      adapter.restPages = {
        '': _restPage([51], nextOffset: ''),
      };
      final ctr = controller();

      await ctr.queryData();
      expect(ids(ctr), [1]);

      // 真实进入「校验中」：注入可门控探针 + 生命周期发布（不是 seed 出来的假状态）。
      final probe = _SessionProbe();
      final gate = Completer<void>();
      probe.gate = gate;
      probe.navEntered = Completer<void>();
      service
        ..debugSetProbe(probe)
        ..enableValidation();
      service.onAccountsPublished([acc], recheck: true);
      await probe.navEntered!.future;

      expect(service.healthFor(acc).checking, isTrue);
      expect(service.healthFor(acc).canUseReplyGrpc, isFalse);

      await ctr.onLoadMore();
      expect(ids(ctr), [51], reason: 'checking 期间不得继续使用旧授权');

      // 收尾：放行并等待，不留下未完成的校验任务。
      gate.complete();
      await service.pendingFor(acc);
    });

    test('gRPC 有效账号在会话中途切到另一个有效账号：按新健康状态重新判定', () async {
      final first = loginAccount(mid: 8318);
      Accounts.accountMode[AccountType.main.index] = first;
      publish(first);
      adapter.grpcPages = {
        0: _grpcPage([1], next: 10, isEnd: false),
        10: _grpcPage([2], next: 0, isEnd: true),
      };
      final ctr = controller();

      await ctr.queryData();
      expect(ids(ctr), [1]);

      final second = loginAccount(mid: 8319);
      Accounts.accountMode[AccountType.main.index] = second;
      publish(second);

      await ctr.onLoadMore();
      expect(
        ids(ctr),
        [1],
        reason: '新账号同样是有效正式号：重启后从首屏（cursor 0）取，而不是沿用旧链游标',
      );
      expect(
        adapter.grpcRequests.map((r) => r.cursor.next.toInt()),
        [0, 0],
        reason: '重启必须从 cursor 0 开始',
      );
      expect(adapter.restRequests, isEmpty);
    });

    test('gRPC 追页在飞时健康降级：下一次取数前发现，改走 REST 首屏', () async {
      final acc = loginAccount(mid: 8320);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.grpcPages = {
        0: _grpcPage(const [], next: 10, isEnd: false),
        10: _grpcPage(const [], next: 20, isEnd: false),
        20: _grpcPage([9], next: 0, isEnd: true),
      };
      adapter.restPages = {
        '': _restPage([61], nextOffset: ''),
      };
      // 续页（cursor 10）在飞时把 token 标为失效。
      adapter.gateGrpcCursor = 10;
      final ctr = controller();

      final pending = ctr.queryData();
      await adapter.grpcPaused.future;
      service.markTokenInvalid(AccountHealthIdentity.capture(acc));
      adapter.releaseGrpc();
      await pending;

      expect(ids(ctr), [61], reason: '降级后从 REST 首屏替换');
      expect(
        adapter.grpcRequests.map((r) => r.cursor.next.toInt()),
        [0, 10],
        reason: '健康降级在第三次取数前生效，不再发 gRPC',
      );
    });

    test('连续切换三个有效账号：每次各自一次重启都成功（预算不跨事务累计）', () async {
      // 首屏都是**terminal**（next_offset='' → isEnd=true）：这样基类的
      // load-more 会被 isEnd 拦下，必须靠取数前的账号预检才能发现账号变化。
      // 每个账号内容不同，避免「旧列表恰好相等」的假阳性。
      final first = loginAccount(mid: 8321, token: false);
      Accounts.accountMode[AccountType.main.index] = first;
      publish(first);
      adapter.restPagesByMid = {
        8321: _restPage([1], nextOffset: ''),
        8322: _restPage([2], nextOffset: ''),
        8323: _restPage([3], nextOffset: ''),
        8324: _restPage([4], nextOffset: ''),
      };
      final ctr = controller();
      await ctr.queryData();
      expect(ids(ctr), [1]);
      expect(ctr.isEnd, isTrue, reason: 'terminal：基类 load-more 会被 isEnd 拦下');

      var expected = 2;
      for (final mid in [8322, 8323, 8324]) {
        final next = loginAccount(mid: mid, token: false);
        Accounts.accountMode[AccountType.main.index] = next;
        publish(next);

        await ctr.onLoadMore();

        expect(
          ctr.loadingState.value.isSuccess,
          isTrue,
          reason: '第 $mid 次切换不应因「过于频繁」被拒',
        );
        expect(
          ids(ctr),
          [expected],
          reason: '必须是新账号的首屏内容（terminal 也要能发现账号变化）',
        );
        expected++;
      }
      expect(
        adapter.restRequests.length,
        4,
        reason: '首屏 + 每次切换各一次首屏请求',
      );
    });

    test('gRPC 可见页在飞时健康降级：不提交旧授权结果，改走 REST 首屏', () async {
      final acc = loginAccount(mid: 8330);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.grpcPages = {
        0: _grpcPage([1], next: 10, isEnd: false),
      };
      adapter.restPages = {
        '': _restPage([71], nextOffset: ''),
      };
      adapter.gateGrpcOnce = true;
      final ctr = controller();

      final pending = ctr.queryData();
      await adapter.grpcPaused.future;
      // 网络在飞期间授权失效：响应本身是**可见页**，也绝不能落地。
      service.markTokenInvalid(AccountHealthIdentity.capture(acc));
      adapter.releaseGrpc();
      await pending;

      expect(
        ids(ctr),
        [71],
        reason: '旧授权的可见页不得提交，必须换成 REST 首屏',
      );
      expect(adapter.grpcRequests, hasLength(1), reason: '降级后不再发 gRPC');
      expect(ctr.isEnd, isTrue);
    });

    test('凭证被反复改写：一次事务内两次重启后用可操作错误收敛', () async {
      final acc = loginAccount(mid: 8327, token: false);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.restPages = {
        '': _restPage([1], nextOffset: ''),
      };
      adapter.rotateCookieEach = true;
      final ctr = controller();

      await ctr.queryData();

      expect(
        ctr.loadingState.value,
        isA<state.Error>().having(
          (e) => e.errMsg,
          'errMsg',
          contains('过于频繁'),
        ),
        reason: '不停自改写必须收敛，而不是无限刷新',
      );
      expect(
        adapter.restRequests.length,
        3,
        reason: '首屏 + 2 次重启后到达预算上限',
      );
    });
  });

  group('访客与预检', () {
    test('访客分页：稳定 AnonymousAccount 的 load-more 继续翻页且不发校验', () async {
      Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
      adapter.restPages = {
        '': _restPage([1], nextOffset: 'p2'),
        'p2': _restPage([2], nextOffset: ''),
      };
      final ctr = controller();

      await ctr.queryData();
      expect(ids(ctr), [1]);
      expect(ctr.isEnd, isFalse);

      await ctr.onLoadMore();
      expect(
        ids(ctr),
        [1, 2],
        reason: '访客也必须能翻页（早期实现把稳定访客误判成「换号」，只给一页）',
      );
      expect(ctr.isEnd, isTrue);
      expect(adapter.restRequests.map((r) => r.paginationOffset), ['', 'p2']);
      expect(adapter.probePaths, isEmpty, reason: '访客分页不得触发账号校验');
    });

    test('访客 terminal 列表：重复 load-more 不再发请求', () async {
      Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
      adapter.restPages = {
        '': _restPage([1], nextOffset: ''),
      };
      final ctr = controller();
      await ctr.queryData();
      expect(ctr.isEnd, isTrue);

      final before = adapter.restRequests.length;
      await ctr.onLoadMore();
      await ctr.onLoadMore();
      expect(
        adapter.restRequests.length,
        before,
        reason: 'terminal 且账号未变：不该有任何新请求',
      );
      expect(ids(ctr), [1]);
    });

    test('访客切登录号 / 登录号切访客：都从首屏替换', () async {
      // 访客 → 登录号
      Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
      adapter.restPages = {
        '': _restPage([1], nextOffset: ''),
      };
      final ctr = controller();
      await ctr.queryData();
      expect(ids(ctr), [1]);

      final login = loginAccount(mid: 8332, token: false);
      Accounts.accountMode[AccountType.main.index] = login;
      publish(login);
      adapter.restPages = {
        '': _restPage([2], nextOffset: ''),
      };
      await ctr.onLoadMore();
      expect(ids(ctr), [2], reason: '访客 → 登录号必须首屏替换');

      // 登录号 → 访客
      Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
      adapter.restPages = {
        '': _restPage([3], nextOffset: ''),
      };
      await ctr.onLoadMore();
      expect(ids(ctr), [3], reason: '登录号 → 访客必须首屏替换');
    });

    test('旧请求在飞时切号并再次 load-more：不并发、不提前 reset，最终换到新账号首屏', () async {
      final first = loginAccount(mid: 8333, token: false);
      Accounts.accountMode[AccountType.main.index] = first;
      publish(first);
      adapter.restPagesByMid = {
        8333: _restPage([1], nextOffset: ''),
        8334: _restPage([2], nextOffset: ''),
      };
      adapter.gateRestOnce = true;
      final ctr = controller();

      final pending = ctr.queryData();
      await adapter.restPaused.future;

      final second = loginAccount(mid: 8334, token: false);
      Accounts.accountMode[AccountType.main.index] = second;
      publish(second);

      // 在飞期间再次触加载：必须立即返回（不并发、也不提前 reset 会话游标）。
      await ctr.onLoadMore();
      expect(
        adapter.restRequests.length,
        1,
        reason: '在飞期间不得发第二个请求，也不得把会话游标提前清掉',
      );

      adapter.releaseRest();
      await pending;

      expect(ids(ctr), [2], reason: '旧请求返回后自动重启到新账号首屏');
      expect(adapter.restRequests.length, 2);
    });
  });

  group('gRPC 自动追页（只认 cursor.next）', () {
    test('空页 + 无 pagination_reply：按 cursor.next 继续追页直到上限', () async {
      final acc = loginAccount(mid: 8328);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      // 每页都空、isEnd=false、cursor 每次 +10，且**不带** pagination_reply
      //（gRPC 链实际只发 cursorNext，服务端可能不回分页对象）。
      adapter.grpcPages = {
        for (var i = 0; i < 8; i++)
          i * 10: _grpcPage(const [], next: (i + 1) * 10, isEnd: false),
      };
      final ctr = controller();

      await ctr.queryData();

      expect(ctr.loadingState.value, isA<state.Error>());
      expect(ctr.isEnd, isFalse, reason: '上限不是列表末尾');
      expect(
        adapter.grpcRequests.map((r) => r.cursor.next.toInt()),
        [0, 10, 20, 30, 40],
        reason: '没有 pagination_reply 也要按 cursor.next 追满上限',
      );
    });

    test('追页途中服务端报错：向上抛错，不把空列表当成功', () async {
      final acc = loginAccount(mid: 8329);
      Accounts.accountMode[AccountType.main.index] = acc;
      publish(acc);
      adapter.grpcPages = {
        0: _grpcPage(const [], next: 10, isEnd: false),
      };
      // 只有续页（cursor 10）失败：首屏成功但整页无内容。
      adapter.grpcStatusCursor = 10;
      final ctr = controller();

      await ctr.queryData();

      expect(ctr.loadingState.value, isA<state.Error>());
      expect(
        adapter.grpcRequests.map((r) => r.cursor.next.toInt()),
        [0, 10],
      );
      expect(
        ctr.loadingState.value.isSuccess,
        isFalse,
        reason: '续页失败必须冒泡，不能落成 Success(空)',
      );
    });
  });
}

/// 只用于让校验停在「校验中」的探针（不联网）。
class _SessionProbe implements AccountHealthProbe {
  Completer<void>? gate;
  Completer<void>? navEntered;

  @override
  Future<({UserInfoData? info, int? code})> cookieNav(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async {
    final entered = navEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    if (gate != null) await gate!.future;
    return (info: null, code: null);
  }

  @override
  Future<Map<String, dynamic>?> tokenNav(
    LoginAccount account,
    AccountHealthIdentity identity,
    String accessKey,
  ) async => null;

  @override
  Future<Map<String, dynamic>?> spaceMyInfo(
    LoginAccount account,
    AccountHealthIdentity identity,
  ) async => null;
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

Map<String, dynamic> _plainReplyJson(int id) => <String, dynamic>{
  'rpid': id,
  'oid': 12345,
  'type': 1,
  'mid': 4242,
  'like': 3,
  'ctime': 1700000000,
  'content': <String, dynamic>{'message': 'reply $id'},
  'member': <String, dynamic>{
    'mid': '4242',
    'uname': 'user$id',
    'avatar': 'https://example.invalid/a.png',
    'level_info': <String, dynamic>{'current_level': 5},
    'vip': <String, dynamic>{'vipStatus': 1, 'vipType': 2},
  },
  'reply_control': <String, dynamic>{'time_desc': '1天前'},
};

/// 带货评论：正文里带商品链接（`needRemoveGoodGrpc` 的判定依据之一）。
///
/// 注意每层都要显式 `<String, dynamic>`：否则嵌套字面量会被推断成
/// `Map<String, String>`，写 `jump_url`/`members` 时运行时直接抛类型错误
///（fixture 自身失败，与过滤逻辑无关）。
Map<String, dynamic> _goodsReplyJson(int id) {
  final json = _plainReplyJson(id);
  final content = json['content'] as Map<String, dynamic>;
  content['message'] = '好物推荐 https://mall.bilibili.com/detail.html?id=1';
  content['jump_url'] = <String, dynamic>{
    'https://mall.bilibili.com/detail.html?id=1': <String, dynamic>{
      'title': '商品',
      'extra': <String, dynamic>{'goods_item_id': 123},
    },
  };
  return json;
}

/// 测试用分页构造：`replies` 允许直接写 rpid（int）或完整 JSON。
Map<String, dynamic> _restPage(
  List<Object> replies, {
  required String nextOffset,
}) => <String, dynamic>{
  'cursor': <String, dynamic>{
    'is_end': nextOffset.isEmpty,
    'all_count': nextOffset.isEmpty ? replies.length : -1,
    'pagination_reply': <String, dynamic>{'next_offset': nextOffset},
  },
  'replies': [
    for (final item in replies)
      item is int ? _plainReplyJson(item) : item as Map<String, dynamic>,
  ],
};

Map<String, dynamic> _restTopReplyPage({
  required int upperId,
  required List<int> replyIds,
}) => <String, dynamic>{
  'cursor': <String, dynamic>{
    'is_end': true,
    'all_count': replyIds.length,
    'pagination_reply': <String, dynamic>{'next_offset': ''},
  },
  'top': <String, dynamic>{'upper': _plainReplyJson(upperId)},
  'replies': replyIds.map(_plainReplyJson).toList(),
};

class _RootAdapter implements HttpClientAdapter {
  final grpcRequests = <gen.MainListReq>[];
  final restRequests = <_RestRequest>[];
  final probePaths = <String>[];

  Map<int, gen.MainListReply> grpcPages = const {};
  Map<String, Map<String, dynamic>> restPages = const {};

  /// 按账号区分的 REST 首屏内容（切号用例：内容不同才不会有旧列表假阳性）。
  Map<int, Map<String, dynamic>> restPagesByMid = const {};
  int grpcStatus = 0;
  String? grpcMessage;
  int? grpcErrorCode;
  int grpcErrorRequests = 0;

  /// 指定 offset 首次请求返回网络错误（用于游标回滚回归）。
  Set<String> failOffsetsOnce = {};
  final _failedOffsets = <String>{};

  /// 指定 offset 返回 -101。
  Set<String> authFailOffsets = {};

  /// 只在第一次响应里轮换 cookie（模拟响应自身改写凭证）。
  String? rotateCookieOnce;

  /// 每次响应都轮换 cookie（模拟凭证被反复改写 → 重启风暴）。
  bool rotateCookieEach = false;
  int _rotateCount = 0;

  /// 指定 cursor 返回 grpc-status 错误（续页失败回归）。
  int? grpcStatusCursor;
  int grpcStatusAtCursor = 13;

  /// 第一次 gRPC 请求返回的 next（用于构造「过时响应污染游标」）。
  int? firstGrpcNextOverride;
  int _grpcCalls = 0;

  /// 暂停第一个 gRPC 请求，直到 [releaseGrpc]。
  bool gateGrpcOnce = false;

  /// 暂停指定 cursor 的 gRPC 请求（用于「续页在飞时健康降级」）。
  int? gateGrpcCursor;
  Completer<void> grpcPaused = Completer<void>();
  Completer<void> grpcGate = Completer<void>();

  /// 暂停第一个 REST 请求（用于「旧请求在飞时切号并再次 load-more」）。
  bool gateRestOnce = false;
  Completer<void> restPaused = Completer<void>();
  Completer<void> restGate = Completer<void>();

  void releaseGrpc() {
    if (!grpcGate.isCompleted) grpcGate.complete();
  }

  void releaseRest() {
    if (!restGate.isCompleted) restGate.complete();
  }

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
    failOffsetsOnce = {};
    _failedOffsets.clear();
    authFailOffsets = {};
    rotateCookieOnce = null;
    rotateCookieEach = false;
    _rotateCount = 0;
    grpcStatusCursor = null;
    firstGrpcNextOverride = null;
    _grpcCalls = 0;
    gateGrpcOnce = false;
    gateGrpcCursor = null;
    gateRestOnce = false;
    // 每例重建门控：否则上一例已完成的 Completer 会让 gate 直接失效。
    grpcPaused = Completer<void>();
    grpcGate = Completer<void>();
    restPaused = Completer<void>();
    restGate = Completer<void>();
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
      return _json({'code': -404});
    }
    if (path == GrpcUrl.mainList) {
      // 关键时序：请求一进入 adapter 就解析、记账、分配序号并确定本请求的
      // next 覆盖值 —— 全部在 gate **之前**。否则被挂起的旧请求不占序号，
      // 后到的请求会抢到 call 0 拿到覆盖值（fixture 假象）。
      final call = _grpcCalls++;
      final req = gen.MainListReq.fromBuffer(
        GrpcReq.decompressProtobuf(options.data as Uint8List),
      );
      grpcRequests.add(req);
      final override = call == 0 ? firstGrpcNextOverride : null;

      if (gateGrpcOnce) {
        gateGrpcOnce = false;
        if (!grpcPaused.isCompleted) grpcPaused.complete();
        await grpcGate.future;
      }

      // 指定 cursor 的门控：请求已记账后才挂起，便于「续页在飞时改状态」。
      if (gateGrpcCursor != null && req.cursor.next.toInt() == gateGrpcCursor) {
        gateGrpcCursor = null;
        if (!grpcPaused.isCompleted) grpcPaused.complete();
        await grpcGate.future;
      }

      // 指定 cursor 的 grpc-status 错误（续页失败的确定性构造）。
      if (grpcStatusCursor != null &&
          req.cursor.next.toInt() == grpcStatusCursor) {
        return ResponseBody.fromBytes(
          Uint8List(0),
          200,
          headers: {
            'grpc-status': ['$grpcStatusAtCursor'],
            'grpc-message': ['internal error'],
            Headers.contentTypeHeader: ['application/grpc'],
          },
        );
      }

      if (grpcErrorCode != null) {
        grpcErrorRequests++;
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
      var effective = page;
      // 使用 gate **之前**捕获的 override（`call == 0` 的那个请求），
      // 不能用请求返回时的状态重新判定。
      if (override != null) {
        effective = page.deepCopy()
          ..cursor = gen.CursorReply(
            next: Int64(override),
            isEnd: page.cursor.isEnd,
          );
      }
      return ResponseBody.fromBytes(
        GrpcReq.compressProtobuf(effective.writeToBuffer()),
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
      final setCookies = <String>[
        if (rotateCookieOnce != null && offset.isEmpty)
          '${rotateCookieOnce!}; Path=/; Domain=.bilibili.com',
        if (rotateCookieEach)
          'buvid3=ROTATE-${++_rotateCount}; Path=/; Domain=.bilibili.com',
      ];
      rotateCookieOnce = null;
      if (failOffsetsOnce.contains(offset) &&
          !_failedOffsets.contains(offset)) {
        _failedOffsets.add(offset);
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        );
      }
      if (authFailOffsets.contains(offset)) {
        return _json(
          {'code': -101, 'message': '账号未登录'},
          setCookies: setCookies,
        );
      }
      final bound = options.extra['account'];
      final mid = bound is Account ? bound.mid : 0;
      // 请求一进入就记账（含 gate 之前），保证「在飞期间是否又发了请求」可断言。
      if (gateRestOnce) {
        gateRestOnce = false;
        if (!restPaused.isCompleted) restPaused.complete();
        await restGate.future;
      }
      final page = restPagesByMid[mid] ?? restPages[offset];
      if (page == null) {
        return _json(<String, dynamic>{
          'code': 0,
          'data': <String, dynamic>{
            'replies': <Object>[],
            'cursor': <String, dynamic>{},
          },
        }, setCookies: setCookies);
      }
      return _json({'code': 0, 'data': page}, setCookies: setCookies);
    }
    throw StateError('unexpected offline request: $path');
  }

  ResponseBody _json(Map<String, dynamic> body, {List<String>? setCookies}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          if (setCookies != null && setCookies.isNotEmpty)
            HttpHeaders.setCookieHeader: setCookies,
        },
      );

  @override
  void close({bool force = false}) {}
}

class _RestRequest {
  const _RestRequest({required this.paginationOffset, required this.query});

  final String paginationOffset;
  final Map<String, dynamic> query;
}
