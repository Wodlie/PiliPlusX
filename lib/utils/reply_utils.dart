import 'dart:io' show Platform;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/selection_text.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class ReplyUtils {
  // 评论检查状态
  static const String replyStateNormal = 'normal';
  static const String replyStateShadowBan = 'shadowBan';
  static const String replyStateDeleted = 'deleted';
  static const String replyStateInvisible = 'invisible';
  static const String replyStateUnderReview = 'underReview';
  static const String replyStateSuspectedNoProblem = 'suspectedNoProblem';
  static const String replyStateUnknown = 'unknown';

  /// 该楼回复过多，游客视角无法完整扫描，无法确认评论是否被吞
  static const String replyStateScanLimited = 'scanLimited';
  // sensitive 状态仅定义，不在此实现检测

  static String replyStateDesc(String state, String message) {
    switch (state) {
      case replyStateNormal:
        return '无账号状态下找到了你的评论，评论正常！\n\n你的评论：$message';
      case replyStateShadowBan:
        return '你的评论被shadow ban（仅自己可见）！\n\n你的评论: $message';
      case replyStateDeleted:
        return '你的评论被系统秒删！\n\n你的评论: $message';
      case replyStateInvisible:
        return '你的评论被标记为invisible（前端不可见）！\n\n你的评论: $message';
      case replyStateUnderReview:
        return '你的评论疑似审核中（不在列表中但可通过回复列表获取）！\n\n你的评论: $message';
      case replyStateSuspectedNoProblem:
        return '你的评论疑似正常（申诉提示无可申诉评论）！\n\n你的评论: $message';
      case replyStateScanLimited:
        return '无法确认评论状态（该楼回复过多，游客视角无法完整扫描）！\n\n你的评论: $message';
      case replyStateUnknown:
        return '你的评论状态未知！\n\n你的评论: $message';
      default:
        return message;
    }
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
        //
        root: replyInfo.root.toInt(),
        parent: replyInfo.parent.toInt(),
        ctime: replyInfo.ctime.toInt(),
        pictures: replyInfo.content.pictures
            .map((item) => item.toProto3Json())
            .toList(),
        mid: replyInfo.mid.toInt(),
        //
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

    // CommAntifraud
    if (!isManual) {
      await Future.delayed(const Duration(seconds: 8));
    }
    void showAppealDialog(String sourceUrl) {
      final defaultReason = Pref.defaultAppealReason;
      final reasonController = TextEditingController(
        text: defaultReason.isNotEmpty
            ? defaultReason
            : (message.length > 93 ? message.substring(0, 93) : message),
      );
      ValueNotifier<String?> resultMessage = ValueNotifier(null);

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

    void showReplyCheckResult(String state) {
      final theme = ThemeUtils.theme;
      final displayMessage = replyStateDesc(state, message);
      final actions = [
        if (state != replyStateNormal)
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

    // root reply
    if (root == 0) {
      // no cookie check
      final res = await ReplyHttp.replyList(
        isLogin: false,
        oid: oid,
        nextOffset: '',
        type: type,
        sort: ReplySortType.time.index,
        page: 1,
      );

      if (res case Error(:final errMsg)) {
        SmartDialog.showToast('获取评论主列表时发生错误：$errMsg');
        return;
      } else if (res case Success(:final response)) {
        final index =
            response.replies?.indexWhere((item) => item.rpid == id) ?? -1;
        if (index != -1) {
          // found in main list — check invisible first
          final foundReply = response.replies![index];
          if (foundReply.invisible == true) {
            showReplyCheckResult(replyStateInvisible);
          } else {
            // not invisible in main list — verify via reply/reply without account
            final resVerify = await ReplyHttp.replyReplyList(
              isLogin: false,
              oid: oid,
              root: id,
              pageNum: 1,
              type: type,
              isCheck: true,
            );
            if (resVerify is Error &&
                resVerify.errMsg?.startsWith('12022') == true) {
              // reply/reply fails with 12022 → shadow ban
              showReplyCheckResult(replyStateShadowBan);
            } else {
              // reply/reply succeeds or other error → normal
              showReplyCheckResult(replyStateNormal);
            }
          }
        } else {
          // not found — cookie check
          final res1 = await ReplyHttp.replyReplyList(
            isLogin: true,
            oid: oid,
            root: id,
            pageNum: 1,
            type: type,
            account: Accounts.reply,
          );

          if (res1 is Error) {
            // not found even with account — deleted
            showReplyCheckResult(replyStateDeleted);
          } else {
            // found with account — no cookie replyReplyList check
            final res2 = await ReplyHttp.replyReplyList(
              isLogin: false,
              oid: oid,
              root: id,
              pageNum: 1,
              type: type,
              isCheck: true,
            );

            if (res2 is Error) {
              // check error code
              if (res2.errMsg?.startsWith('12022') == true) {
                showReplyCheckResult(replyStateShadowBan);
              } else {
                SmartDialog.showToast('检查评论时发生错误：${res2.errMsg}');
              }
            } else {
              // no-cookie also found — check invisible on root
              final rootData = res2.data.root;
              if (rootData?.invisible == true) {
                showReplyCheckResult(replyStateInvisible);
              } else if (isManual) {
                showReplyCheckResult(replyStateNormal);
              } else {
                showReplyCheckResult(replyStateUnderReview);
              }
            }
          }
        }
      }
    } else {
      // 楼中楼：先带 Cookie 爬楼定位目标评论所在页及它上方相邻的评论（锚点），
      // 再以游客视角（无 Cookie）扫描该页 ±3 页的小窗口：
      // · 游客能看到目标 → 正常
      // · 游客能看到锚点评论、唯独没有目标 → shadowban（目标被单独隐藏）
      // · 该区域游客完全不可见（回复过多被接口截断）→ 无法确认
      final locate = await _locateSubReply(
        oid: oid,
        root: root,
        type: type,
        targetId: id,
        account: Accounts.reply,
      );
      if (locate.deleted) {
        showReplyCheckResult(replyStateDeleted);
        return;
      }
      if (locate.targetPage == null) {
        // 带 Cookie 爬楼失败或未翻到底，无法定位
        showReplyCheckResult(replyStateScanLimited);
        return;
      }
      final check = await _checkGuestWindow(
        oid: oid,
        root: root,
        type: type,
        targetId: id,
        anchorRpid: locate.anchorRpid,
        targetPage: locate.targetPage!,
      );
      if (check.found) {
        showReplyCheckResult(replyStateNormal);
      } else if (check.anchorFound) {
        // 目标附近的评论游客可见，唯独目标缺失 → shadowban
        showReplyCheckResult(replyStateShadowBan);
      } else {
        // 该区域游客不可见（截断区），或锚点同样缺失，无法确认
        showReplyCheckResult(replyStateScanLimited);
      }
    }
  }

  /// 带 Cookie 爬楼定位楼中楼目标评论。
  ///
  /// 返回目标所在页号、页内目标上方紧邻评论的 rpid（锚点，作为游客视角
  /// 扫描的参照物），以及是否确认“已删除”（完整翻完且未找到）。
  /// 返回 `targetPage == null` 且 `deleted == false` 表示无法定位。
  static Future<({int? targetPage, int? anchorRpid, bool deleted})>
  _locateSubReply({
    required int oid,
    required int root,
    required int type,
    required int targetId,
    required Account account,
    int maxPages = 60,
  }) async {
    int? lastRpidOfPrevPage;
    int scanned = 0;
    int? total;
    for (int page = 1; page <= maxPages; page++) {
      final res = await ReplyHttp.replyReplyList(
        isLogin: true,
        oid: oid,
        root: root,
        pageNum: page,
        type: type,
        isCheck: true,
        account: account,
      );
      if (res is Error) {
        return (targetPage: null, anchorRpid: null, deleted: false);
      }
      final data = res.data;
      // 第一页响应带根评论，其 count 为该楼真实总回复数，用于判断列表是否被截断
      total ??= data.root?.count;
      final replies = data.replies ?? const [];
      if (replies.isEmpty) {
        // 空页 = 列表已结束；若已扫描数小于总回复数，说明被接口截断，无法确认
        return (
          targetPage: null,
          anchorRpid: null,
          deleted: total == null || scanned >= total,
        );
      }
      final index = replies.indexWhere((item) => item.rpid == targetId);
      if (index != -1) {
        final int? anchorRpid;
        if (index > 0) {
          // 目标上方紧邻的评论
          anchorRpid = replies[index - 1].rpid;
        } else if (lastRpidOfPrevPage != null) {
          // 目标位于页首：锚点为上一页最后一条评论
          anchorRpid = lastRpidOfPrevPage;
        } else if (replies.length > 1) {
          // 目标位于第 1 页第 1 位：锚点取其下方的一条评论
          anchorRpid = replies[1].rpid;
        } else {
          anchorRpid = null;
        }
        return (targetPage: page, anchorRpid: anchorRpid, deleted: false);
      }
      lastRpidOfPrevPage = replies.last.rpid;
      scanned += replies.length;
    }
    // 达到页数上限仍未找到：扫描不完整
    return (targetPage: null, anchorRpid: null, deleted: false);
  }

  /// 游客视角（无 Cookie）扫描目标页 ±3 页的小窗口。
  ///
  /// 返回目标评论是否可见、锚点评论是否可见。
  static Future<({bool found, bool anchorFound})> _checkGuestWindow({
    required int oid,
    required int root,
    required int type,
    required int targetId,
    required int targetPage,
    required int? anchorRpid,
  }) async {
    bool found = false;
    bool anchorFound = false;
    for (int page = targetPage - 3; page <= targetPage + 3; page++) {
      if (page < 1) continue;
      var res = await ReplyHttp.replyReplyList(
        isLogin: false,
        oid: oid,
        root: root,
        pageNum: page,
        type: type,
        isCheck: true,
      );
      // 单页出错（如风控限流）时重试一次
      if (res is Error) {
        await Future.delayed(const Duration(seconds: 1));
        res = await ReplyHttp.replyReplyList(
          isLogin: false,
          oid: oid,
          root: root,
          pageNum: page,
          type: type,
          isCheck: true,
        );
      }
      if (res is Error) {
        continue;
      }
      final replies = res.data.replies ?? const [];
      if (replies.isEmpty) {
        continue;
      }
      if (!found && replies.any((item) => item.rpid == targetId)) {
        found = true;
      }
      if (anchorRpid != null &&
          !anchorFound &&
          replies.any((item) => item.rpid == anchorRpid)) {
        anchorFound = true;
      }
      // 降低连续请求触发风控的概率
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return (found: found, anchorFound: anchorFound);
  }
}
