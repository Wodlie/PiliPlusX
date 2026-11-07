import 'dart:async';
import 'dart:collection';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, DetailListReply, DialogListReply;
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/models_new/dynamic/dyn_mention/item.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/common/reply/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply_fold_mixin.dart';
import 'package:PiliPlus/pages/video/reply_new/view.dart';
import 'package:PiliPlus/pages/video/reply_reply/tree.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class VideoReplyReplyController extends ReplyController<DetailListReply>
    with
        GetSingleTickerProviderStateMixin,
        ReplyFoldMixin<DetailListReply>,
        ReplyLocateMixin<DetailListReply> {
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
  @override
  int oid;
  // rpid 请求楼中楼回复
  int rpid;
  @override
  int replyType;

  bool hasRoot = false;
  final firstFloor = Rxn<ReplyInfo>();

  /// 官方折叠卡（来自 `DetailListReply.mixed_cards[11]`）。
  /// 状态与拉取流程在 [ReplyFoldMixin]，这里只持有实例。
  @override
  final foldCard = Rxn<FoldCard>();

  final index = RxnInt();

  final listController = ListController();

  late final horizontalPreview = Pref.horizontalPreview;

  @override
  dynamic get sourceId => replyType == 1 ? IdUtils.av2bv(oid) : oid;

  @override
  ReplySortType get prefSortType => Pref.reply2SortType;

  late final removedReply = HashMap<Int64, ReplyInfo>();

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<ReplyInfo>? getDataList(DetailListReply response) {
    return response.root.replies;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<DetailListReply> response) {
    final data = response.response;

    if (isRefresh) {
      handleSubjectControl(data.subjectControl);
    }

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

    handlePagination(
      cursor: data.cursor,
      offset: data.paginationReply.nextOffset,
    );

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
      ReplyGrpc.foldListForMixin(type: replyType, oid: oid, offset: offset);

  /// 与当前排序口径保持一致：热度按点赞倒序，时间按发布时间升序。
  void sortByCurrentOrder(List<ReplyInfo> list) {
    if (sortType.value == ReplySortType.hot) {
      list.sort((a, b) => b.like.compareTo(a.like));
    } else {
      list.sort((a, b) => a.ctime.compareTo(b.ctime));
    }
  }

  Iterable<ReplyInfo> getParentChain(int index, ReplyInfo? firstFloor) {
    final data = loadingState.value.data!;
    final item = data[index];
    final replies = [item];
    for (var i = index - 1, parent = item.parent; i >= 0; i--) {
      final item = data[i];
      if (item.id == parent) {
        replies.add(item);
        parent = item.parent;
      }
    }
    if (firstFloor != null && firstFloor.id != replies.last.id) {
      replies.add(firstFloor);
    }
    return replies.reversed;
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
      colorAnimController.forward(from: 0);
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
        offset: nextOffset,
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
      offset: nextOffset,
      removed: removedReply,
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

  Future<ReplyInfo?> _sendReply(ReplyInfo replyItem) async {
    final (bool inputDisable, String? hint) = replyHint;
    if (inputDisable) return null;

    final oid = replyItem.oid.toInt();
    final root = replyItem.id.toInt();
    final key = oid + root;

    final replyInfo = await Get.key.currentState!.push(
      PublishRoute<ReplyInfo>(
        pageBuilder: (context, _, _) {
          return ReplyPage(
            hint: hint,
            oid: oid,
            root: root,
            parent: root,
            replyType: replyType,
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
    );

    if (replyInfo != null) {
      savedReplies.remove(key);
      count.value += 1;
      if (enableCommAntifraud) {
        onCheckReply(replyInfo, isManual: false);
      }
    }
    return replyInfo;
  }

  @override
  Future<void> onReply(
    covariant ReplyInfo replyItem, {
    int? oid,
    int? replyType,
    covariant int index = -1,
    MentionItem? mentionItem,
  }) async {
    assert(index != -1 || replyItem.root == replyItem.id);

    if (await _sendReply(replyItem) case final replyInfo?) {
      loadingState
        ..value.dataOrNull?.insert(index + 1, replyInfo)
        ..refresh();
    }
  }

  Timer? _replyTimer;
  Future<void>? _inflightReply;
  final progress = RxDouble(0);

  bool get inFetchReply => _replyTimer != null || _inflightReply != null;

  void _cancelReplyTimer() {
    _replyTimer?.cancel();
    _replyTimer = null;
  }

  void nextReplyRound() {
    _replyTimer = null;
    _inflightReply = _fetchNextReply();
  }

  void _createReplyTimer() {
    _replyTimer = Timer(const Duration(milliseconds: 300), nextReplyRound);
  }

  Future<void> _fetchNextReply() async {
    try {
      if (isEnd && foldCard != null) {
        await loadFoldList(toast: false);
      } else {
        await queryData(false);
      }
    } finally {
      _inflightReply = null;
    }
    if (!isClosed) {
      if (isEnd && foldCard == null) {
        buildTree();
      } else {
        _createReplyTimer();
      }
    }
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    await super.queryData(isRefresh);
    if (isEnd) {
      progress.value = 1;
    } else if (count.rawValue > 0) {
      progress.value =
          (loadingState.rawValue.dataOrNull?.length ?? 0) / count.rawValue;
    }
  }

  @override
  Future<void> onLoadMore() {
    if (_replyTimer != null) {
      assert(_inflightReply == null);
      _cancelReplyTimer();
      return _inflightReply = _fetchNextReply();
    } else if (_inflightReply case final future?) {
      return future;
    }
    return super.onLoadMore();
  }

  @override
  void queryBySort() {
    if (replyTree.rawValue != null) return;
    super.queryBySort();
  }

  @override
  Future<void> onRefresh() async {
    if (replyTree.rawValue != null) return Future.syncValue(null);
    if (_inflightReply != null) await _inflightReply;
    _cancelReplyTimer();
    return super.onRefresh();
  }

  @override
  void onClose() {
    _cancelReplyTimer();
    super.onClose();
  }

  final replyTree = Rxn<ReplyTree>();

  void buildTree() {
    final data = loadingState.rawValue.data!;
    final seen = HashSet<Int64>();
    data.retainWhere((i) => seen.add(i.id));
    replyTree.value = ReplyTree.build(
      data: data,
      seen: seen,
      rootId: firstFloor.rawValue?.id ?? data.first.root,
      removed: removedReply,
      foldDepth: Pref.foldDepth,
    );
  }

  void toggleCollapseTree(int index) {
    replyTree
      ..rawValue!.toggleCollapse(index)
      ..refresh();
  }

  bool setIndexByTreeNode(int end, ReplyTreeNode? node) {
    if (node != null) {
      final index = replyTree.rawValue!.reverseIdentityIndexOf(node, end);
      if (index != -1) {
        this.index.value = index;
        jumpToItem(index);
        return true;
      }
    }
    return false;
  }

  Future<void> onReplyByTreeNode(int index, ReplyInfo replyItem) async {
    if (await _sendReply(replyItem) case final replyInfo?) {
      replyTree
        ..rawValue!.appendLeaf(replyInfo, index)
        ..refresh();

      final data = loadingState.rawValue.dataOrNull;
      if (data != null) {
        final index = data.reverseIdentityIndexOf(replyItem);
        data.insert(index + 1, replyInfo);
      }
    }
  }

  void onRemoveByTreeNode(int index, ReplyInfo replyItem) {
    replyTree
      ..rawValue!.remove(index)
      ..refresh();

    final data = loadingState.rawValue.dataOrNull;
    if (data != null) {
      final index = data.reverseIdentityIndexOf(replyItem);
      onRemove(index, replyItem, null);
    }
  }
}
