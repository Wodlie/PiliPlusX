import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show FoldCard, MainListReply, MixedCard, ReplyInfo;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/reply/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply/reply_footer_mixin.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

mixin BaseReplyFoldMixin<R> on ReplyController<R>
    implements ReplyFooterController<R> {
  FoldCard? foldCard;

  @override
  String? get foldText => foldCard?.bottomText;

  void getFoldCard(List<MixedCard> mixedCards) {
    if (mixedCards.isNotEmpty) {
      foldCard = mixedCards.firstWhereOrNull((e) => e.type == .FOLD)?.fold;
    }
  }

  Future<void> loadFoldList({bool toast = true}) async {
    if (isLoading) return;
    isLoading = true;
    try {
      final res = await ReplyGrpc.foldList(
        oid: oid,
        type: replyType,
        pagination: foldCard!.foldPagination,
        // Nested lists carry no guard lease in this slice, so the transport
        // keeps its default and these rows are removed as before.
        retainBlockedReplies: false,
      );
      if (isClosed) return;
      if (res case Success(:final response)) {
        foldCard = null;
        count.value += response.replies.length;
        loadingState
          ..value.data!.addAll(response.replies)
          ..refresh();
        if (toast && response.hasTitle()) {
          SmartDialog.showToast(response.title);
        }
      } else {
        res.toast();
      }
    } catch (e) {
      if (kDebugMode) rethrow;
      SmartDialog.showToast(e.toString());
    } finally {
      isLoading = false;
    }
  }

  @override
  Future<void> onRefresh() {
    foldCard = null;
    return super.onRefresh();
  }
}

mixin ReplyFoldMixin on BaseReplyFoldMixin<MainListReply> {
  @override
  List<ReplyInfo>? getDataList(MainListReply response) {
    getFoldCard(response.mixedCards);
    return response.replies;
  }
}
