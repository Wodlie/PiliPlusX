/// 评论自查的纯判定层：把「游客视角」与「账号视角」各一次 seek 的观测，
/// 映射成检查结论。
///
// 为什么需要它：seek 用不存在的 rpid 时服务端**静默回落首页**且返回成功
// （实测见 .ai/tmp-grpc-seek/FINDINGS.md），所以「查不到」必须先区分
// 「锚点未命中」与「锚点命中但目标不在预览域」，前者不能推出任何结论。

/// 单个视角的 seek 观测结果。
enum ReplySeat {
  /// 锚点命中，且目标可见（一级评论看自身；楼中楼看根评论的预览域）。
  present,

  /// 锚点命中、目标在预览域，但条目被标记 invisible。
  invisible,

  /// 锚点命中，但目标不在预览域。
  absent,

  /// 请求成功却没有锚定到期望的根评论（seek 被忽略 / 回落首页）。
  seatMiss,

  /// 请求失败（网络、限流、鉴权被拒且降级也失败）。
  failed,
}

/// 两个视角都「看不见」时，根评论探活的结果。
enum ReplyRootProbe {
  /// 根评论已不可用（12022 / 12006）：评论确实没了。
  unavailable,

  /// 根评论存活，但目标对两个视角都不可见。
  alive,

  /// 探活本身失败 —— 不允许据此下任何结论。
  failed,
}

/// 检查结论。刻意不叫「正常/异常」，避免把「看不清」表达成结论。
enum ReplyCheckVerdict {
  /// 游客视角能看到。
  normal,

  /// 游客视角能看到，但条目被标记 invisible。
  invisible,

  /// 游客看不到、账号能看到：仅自己可见。
  shadowBan,

  /// 探活确认根评论/回复已不可用。
  deleted,

  /// 两个视角都看不到，且根评论仍然存活。
  underReview,

  /// seek 没能定位（尚未落库、接口未返回、区域被截断）。
  scanLimited,

  /// 请求失败，无法判定。
  unknown,
}

abstract final class ReplySeekVerdict {
  /// 第一层：不探活即可定论时返回终态；返回 `null` 表示需要 [fromProbe]。
  ///
  /// 判定顺序即优先级：游客可见 > 条目 invisible > 账号可见（仅自己可见）>
  /// 两视角都缺席。任一视角 `failed` 都不下断言。
  static ReplyCheckVerdict? decide({
    required ReplySeat tourist,
    required ReplySeat account,
  }) {
    // 游客能看到 = 公开可见，账号视角的差异不影响这个结论。
    if (tourist == ReplySeat.present) return ReplyCheckVerdict.normal;
    if (tourist == ReplySeat.invisible) return ReplyCheckVerdict.invisible;

    // 游客这边「看不清」：请求失败时不能拿账号视角反推仅自己可见。
    if (tourist == ReplySeat.failed) return ReplyCheckVerdict.unknown;

    if (account == ReplySeat.present) return ReplyCheckVerdict.shadowBan;
    if (account == ReplySeat.invisible) return ReplyCheckVerdict.invisible;
    if (account == ReplySeat.failed) return ReplyCheckVerdict.unknown;

    // 两个视角都是 absent / seatMiss：单次 seek 无法区分。
    return null;
  }

  /// 第二层：两视角都缺席时的终态。
  static ReplyCheckVerdict fromProbe(ReplyRootProbe probe) => switch (probe) {
    ReplyRootProbe.unavailable => ReplyCheckVerdict.deleted,
    ReplyRootProbe.alive => ReplyCheckVerdict.underReview,
    ReplyRootProbe.failed => ReplyCheckVerdict.unknown,
  };

  /// 结论是否「可能只是还没落库」，值得等一会儿再试。
  static bool worthRetry(ReplyCheckVerdict verdict) =>
      verdict == ReplyCheckVerdict.scanLimited ||
      verdict == ReplyCheckVerdict.underReview;
}
