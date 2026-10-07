import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply_rest.dart';
import 'package:PiliPlus/http/reply_rest_adapter.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:fixnum/fixnum.dart';

/// 根评论读取会话：决定当前链走 gRPC 还是 REST，并各自维护游标。
///
/// 设计要点：
/// - **只读**已发布的账号健康状态（`AccountHealth`），绝不在评论路径发起校验；
/// - 每条链的传输方式固定（sticky），中途不把 gRPC cursor 与 REST offset 混用；
/// - 传输变化（凭证失效 / 健康降级 / 账号变化）只上报一次 restart，由控制器
///   从首屏替换列表；
/// - 每个控制器各持一个会话，不共享游标；
/// - 每条链的结果都经过 `ReplyGrpc.filterMainList`（屏蔽规则只此一份）；
/// - **每个 await 之后立刻核对代际**：会话已换代（`reset`）则丢弃结果且不安排
///   重启；只有凭证/选中账号变了才上报 `account`。过时结果绝不推进游标。
final class RootReplySession {
  RootReplySession({required this.healthOf});

  /// 账号健康状态的**只读**读取器（控制器注入，通常是
  /// `AccountService.healthFor`）。会话本身不依赖服务，也不发起校验。
  final AccountHealth Function(Account account) healthOf;

  RootReplyBackend? _backend;
  bool _forceRest = false;
  Account? _account;
  AccountHealthIdentity? _identity;

  /// 会话代数：`reset()` 自增。请求返回后代数不同即视为过时结果。
  int _epoch = 0;

  /// gRPC 链游标（只在核对通过后提交）。
  Int64? _grpcNext;

  /// REST 链游标：只有服务端确认接受过该页才提交。
  String _restNextOffset = '';

  /// 本会话已**消费**过的 REST offset（含空串）：同一个 offset 再次出现即为环。
  ///
  /// 只在请求发出前登记、失败时撤销。绝不能把「下一个待取 offset」提前登记，
  /// 否则下一次正常的 load-more 会被自己的环检测拒绝。
  final _requestedRestOffsets = <String>{};

  /// 正在飞行中的 REST offset（失败时只撤销这一个）。
  String? _restInFlightOffset;

  /// 上一次取数因「整页无可展示内容但游标仍在」返回了可操作错误。
  /// 控制器据此把「重试」实现为**沿当前游标继续**，而不是回首屏。
  bool _canContinueFromCursor = false;
  bool get canContinueFromCursor => _canContinueFromCursor;

  /// 鉴权被服务端明确拒绝时的回调（由控制器注入，用于把该凭证标记失效）。
  void Function(AccountHealthIdentity identity)? onAuthRejected;

  /// 待处理的重启请求（控制器消费后清空）。
  String? pendingRestartReason;

  RootReplyBackend? get backend => _backend;

  Account? get account => _account;

  AccountHealthIdentity? get identity => _identity;

  /// 当前链已确定走 REST（控制器据此调整结束判定）。
  bool get isRest => _backend == RootReplyBackend.rest;

  /// 会话绑定的账号/凭证是否已经变了（**通用比较，不按账号类型判断**）。
  ///
  /// - 凭证指纹（mid / accessKey / buvid / mobiApp / 设备 / cookie 摘要）一致；
  /// - 会话绑定的账号仍是当前 `Accounts.main` 的那个实例。
  ///
  /// 必须对**所有**账号类型成立：早期实现写成「main 不是 LoginAccount 就算变了」，
  /// 于是稳定访客（AnonymousAccount）每次 load-more 都被判成变化、会话被重置回
  /// 首屏，永远只能看到一页。纯读取：不建立表项、不发起校验。
  bool get contextChanged {
    final account = _account;
    final identity = _identity;
    if (account == null || identity == null) return false;
    final main = Accounts.main;
    return !identity.matches(account) ||
        !identity.matches(main) ||
        !identical(account, main);
  }

  /// 该凭证连续被抓取的上限（gRPC 自动追页与 REST 自动追页共用）。
  static const maxConsecutivePages = 5;

  /// 「有下一页但整页没有可展示内容」时的错误文案（可操作：点击重试继续）。
  static const emptyPageMessage = '当前页评论均被屏蔽，点击重试继续加载';

  /// 刷新/换链：清空全部游标，下一次 fetch 重新选择传输。
  ///
  /// [forceRest] 用于「本轮已经判定不能走 gRPC」（凭证失效 / 传输切换），
  /// 让下一次首屏直接走 REST；用户手动刷新时用默认值重新按健康状态判定。
  void reset({bool forceRest = false}) {
    _epoch++;
    _backend = null;
    _forceRest = forceRest;
    _account = null;
    _identity = null;
    _grpcNext = null;
    _restNextOffset = '';
    _restInFlightOffset = null;
    _requestedRestOffsets.clear();
    _canContinueFromCursor = false;
    pendingRestartReason = null;
  }

  /// 取一页根评论。
  Future<LoadingState<MainListReply>> fetch({
    required int oid,
    required int type,
    required Mode mode,
  }) async {
    // reset(forceRest) 会只设置 backend 而清掉账号，所以初始化条件是
    // 「三件套缺任一」，否则重启后的首屏会拿到空账号。
    if (_backend == null || _account == null || _identity == null) {
      final account = Accounts.main;
      final health = healthOf(account);
      _account = account;
      _identity = AccountHealthIdentity.capture(account);
      _backend = (_forceRest || !health.canUseReplyGrpc)
          ? RootReplyBackend.rest
          : RootReplyBackend.grpc;
    }

    final account = _account!;
    final identity = _identity!;
    // 账号或凭证在链中途变了：本轮不再发请求，交给控制器重启。
    if (!identity.matches(account) || !identical(account, Accounts.main)) {
      pendingRestartReason = 'account';
      return const Error('账号已切换');
    }

    final epoch = _epoch;
    return switch (_backend) {
      RootReplyBackend.grpc => _fetchGrpc(
        epoch: epoch,
        account: account,
        identity: identity,
        oid: oid,
        type: type,
        mode: mode,
      ),
      RootReplyBackend.rest => _fetchRest(
        epoch: epoch,
        account: account,
        identity: identity,
        oid: oid,
        type: type,
        mode: mode,
      ),
      null => const Error(null),
    };
  }

  /// 每个 await 之后立刻核对。
  ///
  /// - [RootReplyStaleness.stale]：会话已换代（reset / 新会话）→ 丢弃结果，
  ///   **不**安排重启（重启属于上一代，硬塞给新会话会造成无意义刷新）；
  /// - [RootReplyStaleness.restart]：仍是本会话但凭证/选中账号变了 → 交给
  ///   控制器从首屏重启。
  RootReplyStaleness _staleness(
    int epoch,
    AccountHealthIdentity identity,
    Account account,
  ) {
    if (_epoch != epoch) return RootReplyStaleness.stale;
    if (!identity.matches(account) || !identical(account, Accounts.main)) {
      return RootReplyStaleness.restart;
    }
    return RootReplyStaleness.fresh;
  }

  Future<LoadingState<MainListReply>> _fetchGrpc({
    required int epoch,
    required Account account,
    required AccountHealthIdentity identity,
    required int oid,
    required int type,
    required Mode mode,
  }) async {
    MainListReply? collected;
    var requestedCursor = _grpcNext;
    var hasContent = false;
    var terminal = false;

    for (var depth = 0; depth < maxConsecutivePages; depth++) {
      // 每次取数前重新读取**纯**健康状态：只要不再是「正式 + token 有效」
      // （含 checking / unknown / tourist / invalid / missing），就必须从
      // REST 首屏重启（reason='health'），绝不在生命周期复检期间沿用旧授权。
      if (_transportUnusable()) {
        pendingRestartReason = 'health';
        return const Error('凭证状态已变化');
      }

      final res = await ReplyGrpc.mainList(
        oid: oid,
        type: type,
        mode: mode,
        cursorNext: requestedCursor,
        offset: null,
        account: account,
        expectedIdentity: identity,
        filter: false,
        autoPaginate: false,
      );
      // await 之后、产生任何副作用之前核对代际：过时结果既不标记凭证失效，
      // 也不过滤、不推进游标。
      final staleness = _staleness(epoch, identity, account);
      if (staleness != RootReplyStaleness.fresh) {
        if (staleness == RootReplyStaleness.restart) {
          pendingRestartReason = 'account';
        }
        return const Error('账号或会话已更新');
      }

      // 身份没变：先处理**明确拒绝**，再考虑「授权刚在飞行中失效」。
      // 顺序很关键：真正的 -101 必须始终被登记为 auth 拒绝（并走 markTokenInvalid），
      // 不能被 health 检查吞掉 —— 显式拒绝比「未知」可靠得多。
      if (res case Error(:final code)) {
        // 服务端明确拒绝认证：该凭证不再可用，下次从 REST 首屏重新加载。
        if (code == -101) {
          onAuthRejected?.call(identity);
          pendingRestartReason = 'auth';
        }
        return res;
      }

      // 成功响应：授权可能在这段网络时间里刚刚失效（另一会话标记 token 失效 /
      // 复检开始）。必须在提交任何内容之前再读一次纯健康状态，
      // 否则一个可见的旧授权页面会被当作成功落地。
      if (_transportUnusable()) {
        pendingRestartReason = 'health';
        return const Error('凭证状态已变化');
      }

      final response = (res as Success<MainListReply>).response;
      // 共用过滤：UP 置顶 / 主列表 / 嵌套子回复 / 横幅原因表。
      ReplyGrpc.filterMainList(response);

      // 首屏请求实际发出的是 cursor 0（protobuf 默认值），所以比较必须把
      // null 归一成 0，不能因为「没有游标」就无条件当成已推进。
      final requested = requestedCursor ?? Int64.ZERO;
      final next = response.cursor.next;
      final advanced = next != requested;
      if (advanced) {
        // 核对通过后才提交链上游标。
        _grpcNext = next;
        requestedCursor = next;
      }
      collected = _mergePage(collected, response);

      if (_hasVisibleContent(response)) {
        hasContent = true;
        break;
      }
      // 服务端明确说结束：空页也是「真的没有评论」，按 Success(空)+isEnd
      // 返回，不能报成「被屏蔽」的可操作错误。
      if (response.cursor.isEnd) {
        terminal = true;
        break;
      }
      // 游标没推进（服务端原地打转）且未结束：不能当作列表末尾，也不能
      // 「消费」该 cursor —— 保留游标交给控制器给可操作错误，用户重试仍可恢复。
      if (!advanced) break;
      // 横幅模式下列表非空（含被标记的横幅评论），不自动追页。
      if (ReplyGrpc.showBlockedReplyBanner) break;
    }

    if (!hasContent && !terminal) {
      // 追页上限用尽（或游标不再推进）仍无可见内容：保留游标，给可操作错误。
      _canContinueFromCursor = true;
      return const Error(emptyPageMessage);
    }
    _canContinueFromCursor = false;
    return Success(collected!);
  }

  /// 真正会在 UI 上出现的内容。
  ///
  /// 只算 `replies` 与 `upTop`（横幅）：`ReplyController.getDataList` 只把
  /// `replies` 交给列表，`customHandleResponse` 只额外插入 `upTop`；
  /// `topReplies` 在根评论页根本没有渲染路径，不能因为它非空就停止自动追页。
  bool _hasVisibleContent(MainListReply response) =>
      response.replies.isNotEmpty || response.hasUpTop();

  /// 已发布的健康状态是否已经不允许继续走 gRPC。
  ///
  /// 判据就是 gRPC 的唯一准入条件 [AccountHealth.canUseReplyGrpc] 的否定：
  /// checking（重检进行中）/ unknown（网络异常、风控、未校验）/ tourist /
  /// invalid / missing 全部视为不可用 —— 复检期间不得继续沿用旧授权。
  bool _transportUnusable() {
    final identity = _identity;
    if (identity == null) return false;
    final health = healthOf(Accounts.main);
    // 读到别的凭证的状态：不可据此判断本链。
    if (health.identity != identity) return false;
    return !health.canUseReplyGrpc;
  }

  Future<LoadingState<MainListReply>> _fetchRest({
    required int epoch,
    required Account account,
    required AccountHealthIdentity identity,
    required int oid,
    required int type,
    required Mode mode,
  }) async {
    // 本地游标：只有服务端确认接受过这一页，才提交到 `_restNextOffset`。
    var offset = _restNextOffset;
    MainListReply? collected;
    var hasContent = false;
    var terminal = false;

    for (var depth = 0; depth < maxConsecutivePages; depth++) {
      // 只有「消费」才登记：登记「下一个待取 offset」会让正常的 load-more 自拒。
      if (!_requestedRestOffsets.add(offset)) {
        return const Error('评论分页游标未推进');
      }
      _restInFlightOffset = offset;

      final result = await ReplyRest.mainListRaw(
        account: account,
        identity: identity,
        oid: oid,
        type: type,
        mode: mode == Mode.MAIN_LIST_TIME ? 2 : 3,
        offset: offset,
      );
      // 每个 await 之后立刻核对：过时结果不落地、不推进游标。
      final staleness = _staleness(epoch, identity, account);
      if (staleness != RootReplyStaleness.fresh) {
        _rollbackRestInFlight(epoch);
        if (staleness == RootReplyStaleness.restart) {
          pendingRestartReason = 'account';
        }
        return const Error('账号或会话已更新');
      }

      if (result.data == null) {
        if (result.code == -101) {
          // REST 续页回 -101：cookie 会话也失效了。登记鉴权失败，并从首屏
          // 重新取（以未登录视角），不要停在半截列表上。
          onAuthRejected?.call(identity);
          pendingRestartReason = 'auth';
        }
        // 失败必须向上传递：吞掉错误会让整页变成「空成功」。
        return _restFailure(
          epoch,
          result.message ?? '获取评论失败',
          result.code,
        );
      }

      final MainListReply page;
      try {
        page = ReplyRestAdapter.mainList(
          result.data!,
          oid: oid,
          type: type,
          mode: mode,
        );
      } catch (e) {
        // 解析失败不是「已到末尾」：撤销本 offset 的登记后原样报错。
        return _restFailure(epoch, e.toString(), null);
      }
      // REST 与 gRPC 共用同一套屏蔽规则（关键词/等级/带货/@/黑名单/横幅）。
      ReplyGrpc.filterMainList(page);

      final next = page.paginationReply.nextOffset;
      if (next.isNotEmpty && next == offset) {
        return _restFailure(epoch, '评论分页游标未推进', null);
      }
      // 这一页已被接受：提交游标（含 ''，即列表末尾）。
      _restNextOffset = next;
      _restInFlightOffset = null;
      collected = _mergePage(collected, page);

      if (_hasVisibleContent(page)) {
        hasContent = true;
        break;
      }
      if (next.isEmpty) {
        terminal = true;
        break;
      }
      offset = next;
    }

    if (!hasContent && !terminal) {
      // 追页上限用尽仍无可见内容：保留游标，给可操作错误。
      _canContinueFromCursor = true;
      return const Error(emptyPageMessage);
    }
    _canContinueFromCursor = false;
    return Success(collected!);
  }

  /// 失败/过时：只撤销本次飞行中的 offset 登记，保证同一 offset 可以原样重试。
  ///
  /// 会话已换代时**直接返回**：`reset()` 已经清空集合，此时再动 `_restInFlightOffset`
  /// 会误伤新一代正在飞行的请求。
  void _rollbackRestInFlight(int epoch) {
    if (_epoch != epoch) return;
    final inFlight = _restInFlightOffset;
    if (inFlight != null) {
      _requestedRestOffsets.remove(inFlight);
    }
    _restInFlightOffset = null;
  }

  LoadingState<MainListReply> _restFailure(
    int epoch,
    String message,
    int? code,
  ) {
    _rollbackRestInFlight(epoch);
    return Error(message, code: code);
  }

  /// 把一页并入本轮的累积结果：游标取最远位置，回复按 rpid 去重后追加。
  ///
  /// 用 protobuf 对象而不是回灌 JSON：`writeToJsonMap` 的名字映射不可靠，
  /// 回灌会丢字段（表情 / @ / goods extra）。
  static MainListReply _mergePage(
    MainListReply? accumulated,
    MainListReply page,
  ) {
    if (accumulated == null) return page;
    accumulated
      ..cursor = page.cursor
      ..paginationReply = page.paginationReply
      ..subjectControl = page.subjectControl;
    if (page.hasUpTop()) accumulated.upTop = page.upTop;
    final seen = accumulated.replies.map((reply) => reply.id).toSet();
    accumulated.replies.addAll(
      page.replies.where((reply) => seen.add(reply.id)),
    );
    accumulated.topReplies.addAll(page.topReplies);
    return accumulated;
  }
}

/// 一次 await 之后的结果时效性。
enum RootReplyStaleness {
  /// 仍是本会话、凭证未变。
  fresh,

  /// 会话已换代：丢弃结果，不安排重启。
  stale,

  /// 本会话但凭证/选中账号变了：需要控制器重启。
  restart,
}

enum RootReplyBackend { grpc, rest }
