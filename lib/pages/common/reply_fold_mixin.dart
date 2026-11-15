import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/fold_list_req_ext.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/reply/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply/reply_footer_mixin.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

/// Shared state and pagination for official folded replies.
mixin ReplyFoldMixin<R> on ReplyController<R> implements ReplyFooterController<R> {
  Rxn<FoldCard> get foldCard;

  final foldedIds = <int>{};
  bool foldedLoaded = false;
  int foldRank = 0;
  int _foldGeneration = 0;

  bool get canShowFoldEntry =>
      !Pref.autoShowFoldedReply && foldCard.value != null && !foldedLoaded;

  /// 折叠回复是否还有没拉完的页。
  ///
  /// 上游的 `loadFoldList` 成功后会把 `foldCard` 置空，拿它当「折叠已拉完」的哨兵；
  /// 本 fork 的 [loadFoldedReplies] 必须保留卡片（footer 文案与 foldedIds 标记都要用），
  /// 只能靠 [foldedLoaded] 判断。线程化树是「列表拉完 → 折叠拉完 → buildTree」的三步收尾，
  /// 直接比 `foldCard` 会让第二步永远判不完：300ms 定时器空转，树永远不建
  /// （表现为点线程化按钮后进度条走满、界面没有任何变化）。
  bool get foldPending => foldCard.value != null && !foldedLoaded;

  @override
  String get foldText {
    final text = foldCard.value?.bottomText;
    return (text != null && text.isNotEmpty) ? text : '已为您过滤部分不友善评论';
  }

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    // Use the same acceptance rules as CommonListController before changing state.
    if (isClosed || isLoading || (!isRefresh && isEnd)) return;
    if (isRefresh) resetFoldState();
    final generation = _foldGeneration;
    await super.queryData(isRefresh);
    if (generation != _foldGeneration || isClosed) return;
    // Start only after the normal replies have been committed to loadingState.
    if (Pref.autoShowFoldedReply && loadingState.value.isSuccess) {
      await loadFoldedReplies();
    }
  }

  @override
  Future<void> onRefresh() {
    if (isClosed || isLoading) return Future<void>.value();
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    if (isClosed || isLoading) return Future<void>.value();
    return super.onReload();
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<R> response) {
    handleFoldResponse(response.response, isRefresh);
    return super.customHandleResponse(isRefresh, response);
  }

  /// Select a root-list card without starting network work from a response hook.
  bool handleFoldResponse(Object? reply, bool isRefresh) {
    if (reply is! MainListReply || (!isRefresh && foldCard.value != null)) {
      return false;
    }
    for (final mixedCard in reply.mixedCards) {
      final card = decodeFoldCardFromMixedCard(mixedCard);
      if (card == null) continue;
      foldCard.value = card;
      foldRank = mixedCard.hasDisplayRank() ? mixedCard.displayRank.toInt() : 0;
      return true;
    }
    return false;
  }

  bool applyFoldCardFromDetail(GeneratedMessage reply) {
    if (foldCard.value != null) return false;
    final card = decodeFoldCardFromUnknown(reply);
    if (card == null) return false;
    foldCard.value = card;
    return true;
  }

  void resetFoldState() {
    _foldGeneration++;
    foldedLoaded = false;
    foldedIds.clear();
    foldCard.value = null;
    foldRank = 0;
  }

  /// Upstream loadFoldList equivalent (this fork uses the foldedIds model).
  Future<void> loadFoldList({bool toast = true}) => loadFoldedReplies();

  Future<void> loadFoldedReplies() async {
    final card = foldCard.value;
    if (isClosed || isLoading || card == null || foldedLoaded) return;
    foldedLoaded = true;
    final generation = _foldGeneration;

    var offset = card.foldPagination.offset;
    for (var page = 0; page < 3 && offset.isNotEmpty; page++) {
      final res = await fetchFoldList(offset);
      if (generation != _foldGeneration || isClosed) return;
      if (res case Success(:final response)) {
        if (!insertFoldedReplies(response)) {
          foldedLoaded = false;
          return;
        }
        offset = response.paginationReply.nextOffset;
      } else {
        foldedLoaded = false;
        res.toast();
        return;
      }
    }
  }

  Future<LoadingState<FoldListResp>> fetchFoldList(String offset);

  /// Return true while the target list is available for subsequent fold pages.
  bool insertFoldedReplies(FoldListResp response);

  bool absorbFoldedReplies(
    FoldListResp response,
    void Function(List<ReplyInfo> existing, List<ReplyInfo> added) insert,
  ) {
    final existing = loadingState.value.dataOrNull;
    if (existing == null) return false;
    final seen = existing.map((e) => e.id).toSet();
    final added = response.replies.where((e) => seen.add(e.id)).toList();
    // An empty or duplicate-only page can still have a valid continuation cursor.
    if (added.isNotEmpty) {
      foldedIds.addAll(added.map((e) => e.id.toInt()));
      insert(existing, added);
      loadingState.refresh();
    }
    return true;
  }
}
