import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply;
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pbenum.dart'
    show Mode;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply_rest.dart';
import 'package:PiliPlus/http/reply_rest_adapter.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:fixnum/fixnum.dart';

/// 一次「定位评论」查询走的是哪条通道（结论文案与排查都要用到）。
enum ReplySeekBackend { grpc, rest }

/// 定位查询的结果：成功时统一成 [MainListReply]，调用方不必区分通道。
sealed class ReplySeekResult {
  const ReplySeekResult();
}

final class ReplySeekPage extends ReplySeekResult {
  const ReplySeekPage(this.page, this.backend);

  final MainListReply page;
  final ReplySeekBackend backend;
}

final class ReplySeekError extends ReplySeekResult {
  const ReplySeekError(this.reason, {this.code});

  final String reason;

  /// 服务端错误码（Bili 业务码或 gRPC 透传的码）。
  final int? code;
}

/// 评论自查的定位通道：**一次点查询**拿到「包含目标回复的根评论」。
///
/// 语义与 REST 的 `/x/v2/reply/main?seek_rpid=` 完全一致（实测见
/// `.ai/tmp-grpc-seek/FINDINGS.md`）：把**目标回复自己的 rpid** 传进去，
/// 服务端把包含它的根评论放到首条，并把该回复放进根评论的 `replies` 预览域。
///
/// 设计约束：
/// - 只**读**已发布的账号健康状态（[healthOf]，由调用方注入），绝不在此发起
///   token 校验，也不切换账号；
/// - gRPC 鉴权被拒时降级一次 REST（Cookie 通道），降级失败才报错；
/// - 匿名通道走 REST：[NoAccount] 会被账号拦截器归一成匿名身份并注入匿名
///   jar 里的 buvid3，等价于真实游客请求。
final class ReplySeek {
  const ReplySeek({required this.healthOf});

  /// 健康状态的**只读**读取器（通常是 `AccountService.healthFor`）。
  final AccountHealth Function(Account account) healthOf;

  /// 带账号视角：健康状态允许时走 gRPC，否则直接走 REST（Cookie 仍有效）。
  Future<ReplySeekResult> asSelf({
    required Account account,
    required int oid,
    required int type,
    required int rpid,
    required Mode mode,
  }) async {
    if (healthOf(account).canUseReplyGrpc) {
      final identity = AccountHealthIdentity.capture(account);
      final res = await ReplyGrpc.mainList(
        oid: oid,
        type: type,
        seekRpid: Int64(rpid),
        mode: mode,
        cursorNext: null,
        offset: null,
        account: account,
        expectedIdentity: identity,
        // 屏蔽规则只服务于列表展示：自查必须看到原始条目，否则被本地过滤
        // 掉的回复会变成「查不到」。
        filter: false,
        // 定位查询只取锚点页，不自动追页。
        autoPaginate: false,
      );
      if (res case Success(:final response)) {
        return ReplySeekPage(response, ReplySeekBackend.grpc);
      }
      if (res case Error(:final errMsg, :final code)) {
        // 只有「认证被拒」才值得换通道重试；服务端明确报错就如实上报。
        if (code != -101) {
          return ReplySeekError(errMsg ?? 'gRPC 定位失败', code: code);
        }
      }
    }
    return _rest(
      account: account,
      identity: AccountHealthIdentity.capture(account),
      oid: oid,
      type: type,
      rpid: rpid,
      mode: mode,
    );
  }

  /// 游客视角：REST 匿名请求。
  Future<ReplySeekResult> asGuest({
    required int oid,
    required int type,
    required int rpid,
    required Mode mode,
  }) {
    return _rest(
      account: const NoAccount(),
      identity: null,
      oid: oid,
      type: type,
      rpid: rpid,
      mode: mode,
    );
  }

  Future<ReplySeekResult> _rest({
    required Account account,
    required AccountHealthIdentity? identity,
    required int oid,
    required int type,
    required int rpid,
    required Mode mode,
  }) async {
    final res = await ReplyRest.mainListRaw(
      account: account,
      identity: identity,
      oid: oid,
      type: type,
      // REST 的 mode：2 = 按时间，3 = 按热度（与 gRPC 枚举一一对应）。
      mode: mode == Mode.MAIN_LIST_TIME ? 2 : 3,
      offset: '',
      seekRpid: rpid,
    );
    if (res.networkError) {
      return const ReplySeekError('网络错误');
    }
    final data = res.data;
    if (data == null) {
      return ReplySeekError(res.message ?? '定位失败', code: res.code);
    }
    try {
      return ReplySeekPage(
        ReplyRestAdapter.mainList(data, oid: oid, type: type, mode: mode),
        ReplySeekBackend.rest,
      );
    } catch (e) {
      return ReplySeekError('解析定位响应失败：$e');
    }
  }
}
