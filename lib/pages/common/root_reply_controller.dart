import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/root_reply.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:get/get.dart';

/// 根评论列表控制器：按账号凭证健康状态在 gRPC 与 REST 之间选择传输。
///
/// 与 [ReplyController] 的差别只有三处：
/// 1. 取数走 [RootReplySession]（只读已发布的健康状态，自身不发校验请求）；
/// 2. REST 的结束条件只认服务端 offset，不按「已加载条数 ≥ count」提前结束；
/// 3. 传输变化/凭证失效时从首屏替换列表，绝不把 REST offset 送进 gRPC cursor。
///
/// 楼中楼与其它列表继续用 [ReplyController]，不受影响。
abstract class RootReplyController extends ReplyController<MainListReply> {
  RootReplyController({super.count});

  late final rootSession =
      RootReplySession(
          healthOf: (account) {
            final service = Get.isRegistered<AccountService>()
                ? Get.find<AccountService>()
                : null;
            // 服务未注册（极简单测）时保守走 REST，绝不因此发起网络校验。
            if (service == null) return AccountHealth.initial(account);
            return service.healthFor(account);
          },
        )
        ..onAuthRejected = (identity) {
          if (Get.isRegistered<AccountService>()) {
            Get.find<AccountService>().markTokenInvalid(identity);
          }
        };

  /// 会话自动重启的次数上限（**每次顶层事务**独立计数）。
  ///
  /// 普通 REST 响应会顺手轮换 non-auth cookie（buvid 等），指纹变化可能再次
  /// 触发重启；这里硬性设上限，把「响应自身改写凭证」导致的重启风暴截断。
  /// 预算随事务结束作废：否则几次正常的账号切换累计下来，第三次切换会被
  /// 永久拒绝。
  static const _maxAutoRestarts = 2;

  /// 正在处理一次重启事务（防重入：内层 `queryData` 的收尾交回最外层）。
  bool _isRestarting = false;

  int get rootOid;

  int get rootReplyType;

  @override
  Future<LoadingState<MainListReply>> customGetData() => rootSession.fetch(
    oid: rootOid,
    type: rootReplyType,
    mode: mode,
  );

  @override
  List<ReplyInfo>? getDataList(MainListReply response) => response.replies;

  @override
  void checkIsEnd(int length) {
    // REST 的总数由 cursor.all_count 给出（未知时为 -1），但结束只认 offset；
    // 按显示条数提前结束会让回退路径重新出现「一页就没了」。
    if (rootSession.isRest) return;
    super.checkIsEnd(length);
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    // 正在飞行/已关闭：**不打断当前轮**（基类与 FoldMixin 的既有约定）。
    // 关键：预检的 reset 必须排在这个守卫**之后** —— 否则会先把会话游标清掉，
    // 而基类因 `isLoading` 拒绝新的取数，旧请求返回时又不设 restart，
    // 最终停在错误态、永远拿不到新账号的首屏。旧请求返回后由 post-await 核对
    // 设置 `pendingRestartReason='account'`，再由本方法统一从首屏重启。
    if (isClosed || isLoading) return;
    // 取数前的纯会话核对：账号/凭证已经换了（完整指纹 + 实例比较）时，基类
    // 可能因为上一轮已到末尾（`!isRefresh && isEnd`）直接返回，于是永远发现
    // 不了变化、界面停在上一个账号的内容上。这里只读会话上下文、不发任何校验，
    // 然后按「首屏替换」重启会话游标。
    if (rootSession.contextChanged) {
      rootSession.reset();
      isRefresh = true;
    }
    await super.queryData(isRefresh);
    await _handlePendingRestart();
  }

  /// 会话上报的重启（凭证失效 / 健康降级 / 账号变化）：从首屏替换列表。
  ///
  /// - `auth`：本轮已判定该凭证不能走 gRPC，下一次直接 REST；
  /// - `account` / `health`：凭证或状态变了，重新按**已发布**的健康状态判定
  ///   （账号换成另一个有效正式号时不该被强行按到 REST）。
  /// 预算用尽时不再自动重启：清掉待办并给出可操作的错误，用户手动刷新会开启
  /// 新事务。绝不能在这里无条件循环——`reset()` 是幂等的，拿「已用次数」当
  /// 循环条件会退化成死循环。
  Future<void> _handlePendingRestart() async {
    // 嵌套调用（重启过程中的新一轮 queryData）直接返回：待办由最外层事务统一
    // 消费，共享同一份本次预算。
    if (_isRestarting) return;
    _isRestarting = true;
    try {
      var remaining = _maxAutoRestarts;
      while (rootSession.pendingRestartReason != null &&
          !isClosed &&
          remaining > 0) {
        if (isLoading) {
          // 当前轮的收尾由外层负责：不并发重启，等下一轮。
          return;
        }
        final reason = rootSession.pendingRestartReason;
        remaining--;
        rootSession.reset(forceRest: reason == 'auth');
        await super.onRefresh();
      }
      _dropPendingRestart();
    } finally {
      _isRestarting = false;
    }
  }

  /// 预算用尽：清掉待办并给出可操作错误，避免每轮都被同一条重启请求拖着刷新。
  ///
  /// 只清待办、**不**动会话：这里可能发生在一次成功加载之后，回退会话会连同
  /// 已加载内容一起作废。用户手动刷新会重新按最新健康状态选链。
  void _dropPendingRestart() {
    if (isClosed || rootSession.pendingRestartReason == null) return;
    if (isLoading) return;
    rootSession.pendingRestartReason = null;
    loadingState.value = const Error('账号状态变化过于频繁，请手动刷新评论');
  }

  @override
  Future<void> onRefresh() {
    // 与 `ReplyFoldMixin.onRefresh` 的既有约定保持一致：正在加载/已关闭时
    // 不打断当前轮。**先判断再 reset**：否则会在当前请求在途时清掉会话游标，
    // 而基类的 `isLoading` 守卫又会拒绝新的取数，把首屏变成空错误。
    if (isClosed || isLoading) return Future<void>.value();
    rootSession.reset();
    return super.onRefresh();
  }

  @override
  Future<void> onLoadMore() {
    // 在飞期间不并发：旧请求返回后的 post-await 核对会接手（设置
    // `pendingRestartReason='account'`），再由 queryData 统一重启。
    if (isClosed || isLoading) return Future<void>.value();
    // 账号预检必须在**最外层**也生效：视频/动态根评论控制器的线性化里，
    // `ReplyFoldMixin.queryData` 位于本类之上，它的 `(!isRefresh && isEnd)`
    // 守卫会让「列表已到末尾」的 load-more 直接返回 —— 那样账号切换就永远
    // 发现不了，界面会一直停在上一个账号的内容上。这里只做只读判定，
    // 真正的会话重置与首屏语义仍由 `queryData` 的 preflight 统一处理。
    if (rootSession.contextChanged) return queryData(true);
    return queryData(false);
  }

  @override
  Future<void> onReload() {
    // 空页/全部被屏蔽：会话已明确表示「游标仍可继续」，「重试」必须沿当前
    // 游标继续，而不是回首屏。
    //
    // 不走 `super.onReload()`：基类先把 loadingState 置为 Loading 再调
    // `onRefresh()`，而 `onRefresh` 会 reset 会话（丢游标），并且基于 Loading
    // 状态的追加分支永远不会提交数据。
    if (isClosed || isLoading) return Future<void>.value();
    if (!rootSession.canContinueFromCursor) return super.onReload();
    return _continueFromCursor();
  }

  /// 沿当前游标继续取数：刷新语义（基类替换列表），但保留会话游标。
  Future<void> _continueFromCursor() async {
    loadingState.value = LoadingState<List<ReplyInfo>?>.loading();
    // `super.queryData` 跳过 ReplyFoldMixin 的刷新钩子（同一份列表无需重置
    // 折叠状态），isRefresh=true 让基类替换已加载内容。
    await super.queryData(true);
    await _handlePendingRestart();
  }
}
