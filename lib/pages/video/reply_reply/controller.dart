import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, DetailListReply, DialogListReply, Mode;
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply_fold_mixin.dart';
import 'package:PiliPlus/pages/video/reply_new/view.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class VideoReplyReplyController extends ReplyController<DetailListReply>
    with GetSingleTickerProviderStateMixin, ReplyFoldMixin<DetailListReply> {
  VideoReplyReplyController({
    required this.hasRoot,
    required this.id,
    required this.oid,
    required this.rpid,
    required this.dialog,
    required this.replyType,
  });
  final int? dialog;
  int? id;
  // 视频aid 请求时使用的oid
  int oid;
  // rpid 请求楼中楼回复
  int rpid;
  int replyType;

  bool hasRoot = false;
  final firstFloor = Rxn<ReplyInfo>();

  /// 官方折叠卡（来自 `DetailListReply.mixed_cards[11]`）。
  /// 状态与拉取流程在 [ReplyFoldMixin]，这里只持有实例。
  @override
  final foldCard = Rxn<FoldCard>();

  final index = RxnInt();

  final listController = ListController();

  AnimationController? _controller;
  AnimationController get animController => _controller ??= AnimationController(
    duration: const Duration(milliseconds: 1000),
    vsync: this,
  );

  late final horizontalPreview = Pref.horizontalPreview;

  @override
  dynamic get sourceId => replyType == 1 ? IdUtils.av2bv(oid) : oid;

  @override
  void onInit() {
    super.onInit();
    final cacheSortType = Pref.reply2SortType;
    sortType.value = cacheSortType;
    mode = cacheSortType == .time ? Mode.MAIN_LIST_TIME : Mode.MAIN_LIST_HOT;
    queryData();
  }

  @override
  List<ReplyInfo>? getDataList(DetailListReply response) {
    return response.root.replies;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<DetailListReply> response) {
    final data = response.response;
    // The base response hook accepts MainListReply, not nested reply messages.
    subjectControl = data.subjectControl;
    upMid ??= data.subjectControl.upMid;
    paginationReply = data.paginationReply;
    isEnd = data.cursor.isEnd;

    if (dialog != null) {
      count.value = data.subjectControl.hasCount()
          ? data.subjectControl.count.toInt()
          : -1;
    } else {
      applyFoldCardFromDetail(data);
      count.value = data.root.count.toInt();
      if (isRefresh && !hasRoot) {
        firstFloor.value ??= data.root;
      }
      if (id != null) {
        setIndexById(Int64(id!), data.root.replies);
        id = null;
      }
    }
    return false;
  }

  @override
  void checkIsEnd(int length) {
    // Dialog totals may be absent or describe the whole subject, not this dialog.
    if (dialog == null) super.checkIsEnd(length);
  }

  /// 楼中楼按当前排序口径合入折叠回复（与列表本身的排序口径保持一致）。
  @override
  bool insertFoldedReplies(FoldListResp response) {
    return absorbFoldedReplies(response, (existing, added) {
      existing.addAll(added);
      sortByCurrentOrder(existing);
    });
  }

  /// 楼中楼同样走 `Reply/FoldList`，oid/type 取本页上下文。
  @override
  Future<LoadingState<FoldListResp>> fetchFoldList(String offset) =>
      ReplyGrpc.foldList(type: replyType, oid: oid, offset: offset);

  /// 与当前排序口径保持一致：热度按点赞倒序，时间按发布时间升序。
  void sortByCurrentOrder(List<ReplyInfo> list) {
    if (sortType.value == ReplySortType.hot) {
      list.sort((a, b) => b.like.compareTo(a.like));
    } else {
      list.sort((a, b) => a.ctime.compareTo(b.ctime));
    }
  }

  bool setIndexById(Int64 id64, [List<ReplyInfo>? replies]) {
    final index = (replies ?? loadingState.value.data!).indexWhere(
      (item) => item.id == id64,
    );
    if (index != -1) {
      this.index.value = index;
      jumpToItem(index);
      return true;
    }
    return false;
  }

  ExtendedNestedScrollController? nestedController;

  @pragma('vm:notify-debugger-on-exception')
  void jumpToItem(int index) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      animController.forward(from: 0);
      try {
        // ignore: invalid_use_of_visible_for_testing_member
        final offset = listController.getOffsetToReveal(index, 0.25);
        if (offset.isFinite) {
          if (nestedController case final nestedController?) {
            nestedController.nestedPositions.last.localJumpTo(offset);
          } else {
            scrollController.jumpTo(offset);
          }
        }
      } catch (_) {}
    });
  }

  @override
  Future<LoadingState<DetailListReply>> customGetData() async {
    if (dialog != null) {
      final res = await ReplyGrpc.dialogList(
        type: replyType,
        oid: oid,
        root: rpid,
        dialog: dialog!,
        offset: paginationReply?.nextOffset,
      );
      // `DialogListReply` 与 `DetailListReply` 是两条不同的消息：
      // 这里的列表只消费 cursor / subject_control / pagination / 回复本身，
      // 因此就地归一成 DetailListReply，调用方无需分支。
      return switch (res) {
        Success(:final response) => Success(_asDetailList(response)),
        Error(:final code, :final errMsg) => Error(errMsg, code: code),
        _ => const Error('dialogList: unexpected state'),
      };
    }
    return ReplyGrpc.detailList(
      type: replyType,
      oid: oid,
      root: rpid,
      rpid: id ?? 0,
      mode: mode,
      offset: paginationReply?.nextOffset,
    );
  }

  /// 把对话视图的响应归一为 [DetailListReply]（只搬运本页用到的字段）。
  static DetailListReply _asDetailList(DialogListReply reply) =>
      DetailListReply(
        cursor: reply.cursor,
        subjectControl: reply.subjectControl,
        paginationReply: reply.paginationReply,
        root: ReplyInfo(
          count: reply.subjectControl.count,
          replies: reply.replies,
        ),
      );

  @override
  Future<void> onReload() {
    if (isClosed || isLoading) return Future<void>.value();
    if (loadingState.value.isSuccess) {
      index.value = null;
    }
    return super.onReload();
  }

  @override
  void onReply(
    ReplyInfo? replyItem, {
    int? oid,
    int? replyType,
    int? index,
  }) {
    assert(replyItem != null && index != null);

    final (bool inputDisable, String? hint) = replyHint;
    if (inputDisable) {
      return;
    }

    final oid = replyItem!.oid.toInt();
    final root = replyItem.id.toInt();
    final key = oid + root;

    Get.key.currentState!
        .push(
          PublishRoute(
            pageBuilder: (buildContext, animation, secondaryAnimation) {
              return ReplyPage(
                hint: hint,
                oid: oid,
                root: root,
                parent: root,
                replyType: this.replyType,
                replyItem: replyItem,
                items: savedReplies[key],
                onSave: (reply) {
                  if (reply.isEmpty) {
                    savedReplies.remove(key);
                  } else {
                    savedReplies[key] = reply.toList();
                  }
                },
              );
            },
          ),
        )
        .then((replyInfo) {
          if (replyInfo is ReplyInfo) {
            savedReplies.remove(key);

            count.value += 1;
            loadingState
              ..value.dataOrNull?.insert(index! + 1, replyInfo)
              ..refresh();
            if (enableCommAntifraud) {
              onCheckReply(replyInfo, isManual: false);
            }
          }
        });
  }

  @override
  void onClose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}
