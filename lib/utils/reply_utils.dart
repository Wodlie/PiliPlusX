import 'dart:io' show Platform;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

abstract final class ReplyUtils {
  // 评论检查状态
  static const String replyStateNormal = 'normal';
  static const String replyStateShadowBan = 'shadowBan';
  static const String replyStateDeleted = 'deleted';
  static const String replyStateInvisible = 'invisible';
  static const String replyStateUnderReview = 'underReview';
  static const String replyStateSuspectedNoProblem = 'suspectedNoProblem';
  static const String replyStateUnknown = 'unknown';
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
          content: SelectableText(displayMessage),
          actions: actions.isEmpty ? null : actions,
        ),
      );
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
                  onPressed: () => Get.back(),
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
                        resultMessage.value =
                            '无可申诉评论，可能评论正常或正在审核中';
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
          // found in main list — check invisible
          final foundReply = response.replies![index];
          showReplyCheckResult(
            foundReply.invisible == true
                ? replyStateInvisible
                : replyStateNormal,
          );
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
      // sub-reply: no cookie paginate
      bool foundNoCookie = false;
      for (int i = 1; ; i++) {
        final res3 = await ReplyHttp.replyReplyList(
          isLogin: false,
          oid: oid,
          root: root,
          pageNum: i,
          type: type,
          isCheck: true,
        );
        if (res3 is Error) {
          break;
        } else {
          final data = res3.data;
          if (data.replies.isNullOrEmpty) {
            break;
          }
          int index = data.replies?.indexWhere((item) => item.rpid == id) ?? -1;
          if (index != -1) {
            showReplyCheckResult(replyStateNormal);
            foundNoCookie = true;
            break;
          }
        }
      }
      if (foundNoCookie) return;

      // sub-reply: has cookie paginate
      bool foundHasCookie = false;
      for (int i = 1; ; i++) {
        final res4 = await ReplyHttp.replyReplyList(
          isLogin: true,
          oid: oid,
          root: root,
          pageNum: i,
          type: type,
          isCheck: true,
          account: Accounts.reply,
        );
        if (res4 is Error) {
          break;
        } else {
          final data = res4.data;
          if (data.replies.isNullOrEmpty) {
            break;
          }
          int index = data.replies?.indexWhere((item) => item.rpid == id) ?? -1;
          if (index != -1) {
            showReplyCheckResult(replyStateShadowBan);
            foundHasCookie = true;
            break;
          }
        }
      }
      if (foundHasCookie) return;

      // not found in either
      showReplyCheckResult(replyStateDeleted);
    }
  }
}
