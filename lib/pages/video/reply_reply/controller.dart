import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, DetailListReply, Mode;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/video/reply_new/view.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class VideoReplyReplyController extends ReplyController
    with GetSingleTickerProviderStateMixin {
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
  List<ReplyInfo>? getDataList(response) {
    return dialog != null ? response.replies : response.root.replies;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success response) {
    final data = response.response;

    subjectControl = data.subjectControl;
    upMid ??= data.subjectControl.upMid;
    paginationReply = data.paginationReply;
    isEnd = data.cursor.isEnd;

    // reply2Reply // isDialogue.not
    if (data is DetailListReply) {
      count.value = data.root.count.toInt();
      // 官方折叠卡（mixed_cards[11]）：拿到则记下，开启设置时自动把折叠回复并入列表
      final fold = decodeFoldCardFromUnknown(data);
      if (fold != null && fold.foldPagination.offset.isNotEmpty) {
        foldCard.value = fold;
        if (Pref.autoShowFoldedReply && !foldedLoaded) {
          loadFoldedReplies();
        }
      }
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

  /// 官方折叠卡（来自 DetailListReply.mixed_cards[11]）。
  final Rxn<FoldCard> foldCard = Rxn<FoldCard>();

  /// 由官方折叠渠道取回、已并入列表的评论 id（用于"已被 B 站折叠"标记）。
  final foldedIds = <int>{};

  bool foldedLoaded = false;

  /// 设置关闭时，是否应在列表底部展示「显示被折叠评论 >」入口。
  bool get canShowFoldEntry =>
      !Pref.autoShowFoldedReply && foldCard.value != null && !foldedLoaded;

  /// 用折叠卡里的游标调 Reply/FoldList，把官方折叠的回复并入列表并按当前排序重排。
  Future<void> loadFoldedReplies() async {
    final card = foldCard.value;
    if (card == null || foldedLoaded) return;
    foldedLoaded = true;
    var offset = card.foldPagination.offset;
    for (var page = 0; page < 3 && offset.isNotEmpty; page++) {
      final res = await ReplyGrpc.foldList(
        type: replyType,
        oid: oid,
        offset: offset,
      );
      if (res case Success(:final response)) {
        final existing = loadingState.value.dataOrNull;
        if (existing != null && response.replies.isNotEmpty) {
          final seen = existing.map((e) => e.id).toSet();
          final added = response.replies.where((e) => seen.add(e.id)).toList();
          if (added.isNotEmpty) {
            foldedIds.addAll(added.map((e) => e.id.toInt()));
            existing.addAll(added);
            sortByCurrentOrder(existing);
            loadingState.refresh();
          }
        }
        offset = response.paginationReply.nextOffset;
      } else {
        res.toast();
        break;
      }
    }
  }

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
  Future<LoadingState> customGetData() => dialog != null
      ? ReplyGrpc.dialogList(
          type: replyType,
          oid: oid,
          root: rpid,
          dialog: dialog!,
          offset: paginationReply?.nextOffset,
        )
      : ReplyGrpc.detailList(
          type: replyType,
          oid: oid,
          root: rpid,
          rpid: id ?? 0,
          mode: mode,
          offset: paginationReply?.nextOffset,
        );

  @override
  Future<void> onReload() {
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

