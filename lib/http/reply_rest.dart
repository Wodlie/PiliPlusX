import 'dart:convert';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_health.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:dio/dio.dart';

/// REST 根评论响应（`/x/v2/reply/main`）。
///
/// 与旧 `ReplyHttp.replyList` 分开：旧函数服务于评论自查，先落到会丢字段的
/// `ReplyData` 模型；根评论回退需要原始 JSON 交给 `ReplyRestAdapter` 映射成
/// 现有 UI 的 protobuf 类型，避免两套评论界面。
abstract final class ReplyRest {
  /// 请求一页根评论。`offset` 为空串表示首屏。
  static Future<
    ({
      Map<String, dynamic>? data,
      int? code,
      String? message,
      bool networkError,
    })
  >
  mainListRaw({
    required Account account,

    // 凭证指纹：匿名请求不需要（不强绑身份），传 null 即不注入。
    AccountHealthIdentity? identity,
    required int oid,
    required int type,
    required int mode,
    required String offset,

    // 定位评论：服务端把「包含该 rpid 的根评论」放到首条。与 gRPC 的
    // `MainListReq.seek_rpid` 对应，语义一致。
    int? seekRpid,
  }) async {
    final res = await Request().get(
      Api.replyMain,
      queryParameters: {
        'oid': oid,
        'type': type,
        // REST 的 mode：2 = 按时间，3 = 按热度。
        'mode': mode,
        // offset 是不透明游标（含引号/反斜线），必须整体 JSON 编码。
        'pagination_str': jsonEncode({'offset': offset}),
        if (seekRpid != null && seekRpid > 0) 'seek_rpid': seekRpid,
      },
      options: Options(
        extra: {
          'account': account,
          if (identity != null) AccountManager.expectedIdentityExtra: identity,
        },
      ),
    );
    final body = res.data;
    if (body is! Map) {
      return (data: null, code: null, message: null, networkError: true);
    }
    final code = body['code'];
    if (code is! int) {
      return (data: null, code: null, message: null, networkError: true);
    }
    if (code != 0) {
      return (
        data: null,
        code: code,
        message: body['message']?.toString(),
        networkError: false,
      );
    }
    final data = body['data'];
    if (data is! Map) {
      return (data: null, code: code, message: null, networkError: false);
    }
    return (
      data: Map<String, dynamic>.from(data),
      code: code,
      message: null,
      networkError: false,
    );
  }
}
