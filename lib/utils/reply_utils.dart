import 'dart:io' show Platform;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/selection_text.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pbenum.dart'
    show Mode;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/http/reply_seek.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/reply_seek_verdict.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 评论自查：用 `seek_rpid` 点查询分别取「游客视角」与「账号视角」，再交给
/// [ReplySeekVerdict] 判定。
///
/// 取代旧实现（逐页爬 `/x/v2/reply/reply` 定位页号，再用同一页号做游客复核）：
/// 两个身份的分页不同源，「没扫到」与「被隐藏」无法区分，正常评论会被误报。
abstract final class ReplyUtils {
  /// 自动自查（刚发布）的重试轮数：只在「可能还没落库」的结论上重试。
  static const int _maxRounds = 3;

  /// 每轮间隔。首轮也要等，服务端对新评论的收录不是即时的。
  static const Duration _roundDelay = Duration(seconds: 8);

  static ReplySeek _seeker() => ReplySeek(
    healthOf: (account) {
      if (Get.isRegistered<AccountService>()) {
        return Get.find<AccountService>().healthFor(account);
      }
      // 服务未注册（单测/极简环境）时保守走 REST，绝不因此发起网络校验。
      return AccountHealth.initial(account);
    },
  );

  static String verdictDesc(
    ReplyCheckVerdict verdict,
    String message, {
    String? detail,
  }) {
    final suffix = detail == null ? '' : '\n\n$detail';
    final body = switch (verdict) {
      ReplyCheckVerdict.normal => '在游客视角定位到了你的评论，评论正常！',
      ReplyCheckVerdict.invisible => '你的评论被标记为 invisible（前端不可见）！',
      ReplyCheckVerdict.shadowBan => '你的评论被 shadow ban（仅自己可见）！',
      ReplyCheckVerdict.deleted => '你的评论已被删除（根评论已不可用）！',
      ReplyCheckVerdict.underReview => '两个视角都定位不到这条评论，可能是审核中或已被删除（未确认）。',
      ReplyCheckVerdict.scanLimited => '无法确认评论状态：本次定位没有命中这条评论（可能刚发布还没进列表，或该区域接口未返回）。',
      ReplyCheckVerdict.unknown => '检查失败，未能判定评论状态。',
    };
    return '$body$suffix\n\n你的评论：$message';
  }

  static void onCheckReply({
    required ReplyInfo replyInfo,
    required bool biliSendCommAntifraud,
    required sourceId,
    required bool isManual,
  }) {
    try {
      _checkReply(
        oid: replyInfo.oid.toInt(),
        type: replyInfo.type.toInt(),
        id: replyInfo.id.toInt(),
        message: replyInfo.content.message,
        root: replyInfo.root.toInt(),
        parent: replyInfo.parent.toInt(),
        ctime: replyInfo.ctime.toInt(),
        pictures: replyInfo.content.pictures
            .map((item) => item.toProto3Json())
            .toList(),
        mid: replyInfo.mid.toInt(),
        isManual: isManual,
        biliSendCommAntifraud: biliSendCommAntifraud,
        sourceId: sourceId,
      );
    } catch (e) {
      SmartDialog.showToast(e.toString());
    }
  }

  // ref https://github.com/freedom-introvert/biliSendCommAntifraud
  static Future<void> _checkReply({
    required int oid,
    required int type,
    required int id,
    required String message,
    required int root,
    required int parent,
    required int ctime,
    required List pictures,
    required int mid,
    bool isManual = false,
    required bool biliSendCommAntifraud,
    required sourceId,
  }) async {
    // biliSendCommAntifraud
    if (Platform.isAndroid && biliSendCommAntifraud) {
      try {
        final String cookieString = Accounts.reply.cookieJar
            .toJson()
            .entries
            .map((i) => '${i.key}=${i.value}')
            .join(';');
        PiliAndroidHelper.biliSendCommAntifraud(
          0,
          oid,
          type,
          id,
          root,
          parent,
          ctime,
          message,
          pictures,
          sourceId,
          mid,
          cookieString,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('biliSendCommAntifraud: $e');
      }
      return;
    }

    final isRoot = root == 0;
    // 一级评论锚定自己；楼中楼锚定「包含它的根评论」。
    final expectedRoot = isRoot ? id : root;
    final account = Accounts.reply;

    void showAppealDialog(String sourceUrl) {
      final defaultReason = Pref.defaultAppealReason;
      final reasonController = TextEditingController(
        text: defaultReason.isNotEmpty
            ? defaultReason
            : (message.length > 93 ? message.substring(0, 93) : message),
      );
      final resultMessage = ValueNotifier<String?>(null);

      showDialog(
        context: Get.context!,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              constraints: Style.dialogFixedConstraints,
              title: const Text('申诉评论'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '申诉前请不要在此评论区进行敏感词扫描等操作，会污染评论区影响申诉！\n申诉依赖于: https://www.bilibili.com/h5/comment/appeal',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: reasonController,
                      decoration: const InputDecoration(
                        labelText: '申诉理由',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    ValueListenableBuilder<String?>(
                      valueListenable: resultMessage,
                      builder: (context, msg, _) {
                        if (msg == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            msg,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 13,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: Get.back,
                  child: Text(
                    '取消',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final reason = reasonController.text.trim();
                    if (reason.isEmpty) {
                      resultMessage.value = '请输入申诉理由';
                      return;
                    }
                    final result = await ReplyHttp.appealComment(
                      url: sourceUrl,
                      reason: reason,
                    );
                    if (result case Success(:final response)) {
                      Get.back();
                      SmartDialog.showToast(
                        response['successToast'] ?? '申诉提交成功',
                      );
                    } else if (result case Error(:final errMsg, :final code)) {
                      if (code == 12082) {
                        // 申诉结果只是提示，**不写入评论状态**（两条轴分开）。
                        resultMessage.value = '无可申诉评论，可能评论正常或正在审核中';
                      } else {
                        resultMessage.value = errMsg ?? '申诉失败';
                      }
                    }
                  },
                  child: const Text('提交申诉'),
                ),
              ],
            );
          },
        ),
      );
    }

    void retry() =>
        _checkReply(
          oid: oid,
          type: type,
          id: id,
          message: message,
          root: root,
          parent: parent,
          ctime: ctime,
          pictures: pictures,
          mid: mid,
          isManual: true,
          biliSendCommAntifraud: biliSendCommAntifraud,
          sourceId: sourceId,
        );

    void showReplyCheckResult(ReplyCheckVerdict verdict, {String? detail}) {
      final theme = ThemeUtils.theme;
      final displayMessage = verdictDesc(verdict, message, detail: detail);
      // 只有「确实有异常」才值得走申诉；看不清/失败时给重试。
      final appealable = switch (verdict) {
        ReplyCheckVerdict.invisible ||
        ReplyCheckVerdict.shadowBan ||
        ReplyCheckVerdict.deleted ||
        ReplyCheckVerdict.underReview => true,
        _ => false,
      };
      final retryable = ReplySeekVerdict.worthRetry(verdict) ||
          verdict == ReplyCheckVerdict.unknown;
      final actions = [
        if (retryable)
          TextButton(
            onPressed: () {
              Get.back();
              retry();
            },
            child: const Text('重试'),
          ),
        if (appealable)
          TextButton(
            onPressed: () {
              Get.back();
              final sourceUrl = switch (type) {
                1 => 'https://www.bilibili.com/video/${IdUtils.av2bv(oid)}',
                12 => 'https://www.bilibili.com/read/cv$oid',
                17 || 11 => 'https://www.bilibili.com/opus/$oid',
                _ => oid.toString(),
              };
              showAppealDialog(sourceUrl);
            },
            child: const Text('申诉'),
          ),
        if (!isManual)
          TextButton(
            onPressed: Get.back,
            child: Text(
              '关闭',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
      ];
      showDialog(
        context: Get.context!,
        barrierDismissible: isManual,
        builder: (context) => AlertDialog(
          title: const Text('评论检查结果'),
          content: SelectionText(displayMessage),
          actions: actions.isEmpty ? null : actions,
        ),
      );
    }

    // 自动自查可能跑多轮：只在「可能还没落库」的结论上重试。
    final rounds = isManual ? 1 : _maxRounds;
    var verdict = ReplyCheckVerdict.unknown;
    String? detail;
    for (var round = 0; round < rounds; round++) {
      await Future<void>.delayed(_roundDelay);
      // 页面已销毁（用户离开）就不再打扰。
      if (Get.context == null) return;
      final observed = await _observe(
        seeker: _seeker(),
        account: account,
        oid: oid,
        type: type,
        id: id,
        expectedRoot: expectedRoot,
        isRoot: isRoot,
      );
      verdict = observed.verdict;
      detail = observed.detail;
      if (!ReplySeekVerdict.worthRetry(verdict)) break;
    }

    if (Get.context == null) return;
    showReplyCheckResult(
      verdict,
      // 正常时不需要把排查信息糊在脸上。
      detail: verdict == ReplyCheckVerdict.normal ? null : detail,
    );
  }

  /// 采集两个视角的 seek 观测并给出结论。
  static Future<({ReplyCheckVerdict verdict, String? detail})> _observe({
    required ReplySeek seeker,
    required Account account,
    required int oid,
    required int type,
    required int id,
    required int expectedRoot,
    required bool isRoot,
  }) async {
    // 1) 账号视角
    final selfRes = await seeker.asSelf(
      account: account,
      oid: oid,
      type: type,
      rpid: id,
      mode: Mode.MAIN_LIST_TIME,
    );
    final selfSeat = _seatOf(
      selfRes,
      expectedRoot: expectedRoot,
      targetId: id,
      isRoot: isRoot,
    );

    // 2) 游客视角
    final guestRes = await seeker.asGuest(
      oid: oid,
      type: type,
      rpid: id,
      mode: Mode.MAIN_LIST_TIME,
    );
    var guestSeat = _seatOf(
      guestRes,
      expectedRoot: expectedRoot,
      targetId: id,
      isRoot: isRoot,
    );

    // 3) 歧义消解：游客没看到时换热门排序再打一枪（两种排序都会锚定目标）。
    if (guestSeat == ReplySeat.absent || guestSeat == ReplySeat.seatMiss) {
      final again = await seeker.asGuest(
        oid: oid,
        type: type,
        rpid: id,
        mode: Mode.MAIN_LIST_HOT,
      );
      final againSeat = _seatOf(
        again,
        expectedRoot: expectedRoot,
        targetId: id,
        isRoot: isRoot,
      );
      if (againSeat == ReplySeat.present || againSeat == ReplySeat.invisible) {
        guestSeat = againSeat;
      }
    }

    final decided = ReplySeekVerdict.decide(
      tourist: guestSeat,
      account: selfSeat,
    );
    if (decided != null) {
      return (verdict: decided, detail: _describe(selfSeat, guestSeat));
    }

    // 4) 两个视角都缺席：只探活根评论，1 次请求，不翻页。
    final probe = await _probeRoot(
      oid: oid,
      type: type,
      expectedRoot: expectedRoot,
      account: account,
    );
    return (
      verdict: ReplySeekVerdict.fromProbe(probe),
      detail: _describe(selfSeat, guestSeat, probe: probe),
    );
  }

  /// 单次 seek 响应 → 该视角的观测。
  static ReplySeat _seatOf(
    ReplySeekResult result, {
    required int expectedRoot,
    required int targetId,
    required bool isRoot,
  }) => switch (result) {
    ReplySeekError() => ReplySeat.failed,
    ReplySeekPage(page: final page) => _seatOfPage(
      page,
      expectedRoot: expectedRoot,
      targetId: targetId,
      isRoot: isRoot,
    ),
  };

  static ReplySeat _seatOfPage(
    MainListReply page, {
    required int expectedRoot,
    required int targetId,
    required bool isRoot,
  }) {
    // 锚点校验：假 rpid 会被服务端静默回落成首页，不校验就会误判。
    final seat = _anchorOf(page, expectedRoot);
    if (seat == null) return ReplySeat.seatMiss;
    if (isRoot) {
      return _isInvisible(seat) ? ReplySeat.invisible : ReplySeat.present;
    }
    for (final child in seat.replies) {
      if (child.id.toInt() == targetId) {
        return _isInvisible(child) ? ReplySeat.invisible : ReplySeat.present;
      }
    }
    return ReplySeat.absent;
  }

  /// 在一页响应里找「锚定到 [expectedRoot] 的那条评论」。
  ///
  /// REST 适配器会把 UP 置顶项从 `replies` 移到 `upTop`（避免列表重复），
  /// 只认 `replies.first` 会把置顶的锚点误判成「未定位到」。
  /// 这条评论是否被服务端标记为 invisible（前端不可见）。
  ///
  /// 字段在 [ReplyControl] 上而不是 [ReplyInfo] 上：gRPC 的回复模型只有
  /// `ReplyControl.invisible`（`v1.pb.dart` field 16），REST 适配器也把
  /// 同名键并进同一个 control 对象。没有 control 就是"没有这个标记"，
  /// 不能凭空判成不可见——自查宁可回落到 present/absent 由其它判据决定。
  static bool _isInvisible(ReplyInfo reply) =>
      reply.hasReplyControl() && reply.replyControl.invisible;

  static ReplyInfo? _anchorOf(MainListReply page, int expectedRoot) {
    final replies = page.replies;
    if (replies.isNotEmpty && replies.first.id.toInt() == expectedRoot) {
      return replies.first;
    }
    final upTop = page.upTop;
    if (upTop != null && upTop.id.toInt() == expectedRoot) return upTop;
    return null;
  }

  /// 根评论是否还活着：`reply/reply` 第 1 页即可，不翻页、不算页号。
  static Future<ReplyRootProbe> _probeRoot({
    required int oid,
    required int type,
    required int expectedRoot,
    required Account account,
  }) async {
    if (expectedRoot <= 0) return ReplyRootProbe.failed;
    final res = await ReplyHttp.replyReplyList(
      isLogin: true,
      oid: oid,
      root: expectedRoot,
      pageNum: 1,
      type: type,
      isCheck: true,
      account: account,
    );
    switch (res) {
      case Loading():
        // 探活请求不展示加载态，这里只关心「活着 / 没了 / 没探成」。
        return ReplyRootProbe.failed;
      case Success():
        return ReplyRootProbe.alive;
      case Error(:final errMsg):
        // isCheck 把错误码前缀进 message：12022/12006 = 该评论已不可用。
        if (errMsg != null &&
            (errMsg.startsWith('12022') || errMsg.startsWith('12006'))) {
          return ReplyRootProbe.unavailable;
        }
        return ReplyRootProbe.failed;
    }
    return ReplyRootProbe.failed;
  }

  /// 给用户看的排查信息：说清是「哪个视角、哪一步」没看到。
  static String _describe(
    ReplySeat self,
    ReplySeat guest, {
    ReplyRootProbe? probe,
  }) {
    final parts = <String>[
      '账号视角：${_seatText(self)}',
      '游客视角：${_seatText(guest)}',
      if (probe != null) '根评论探活：${_probeText(probe)}',
    ];
    return parts.join('\n');
  }

  static String _seatText(ReplySeat seat) => switch (seat) {
    ReplySeat.present => '可见',
    ReplySeat.invisible => '可见但被标记 invisible',
    ReplySeat.absent => '已定位到该楼，但没有这条评论',
    ReplySeat.seatMiss => '未定位到（接口未返回该楼）',
    ReplySeat.failed => '请求失败',
  };

  static String _probeText(ReplyRootProbe probe) => switch (probe) {
    ReplyRootProbe.unavailable => '根评论已不可用（12022/12006）',
    ReplyRootProbe.alive => '根评论仍在',
    ReplyRootProbe.failed => '探活失败',
  };
}
