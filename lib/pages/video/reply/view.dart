import 'package:PiliPlus/common/skeleton/video_reply.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/sliver/sliver_floating_header.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, MainListReply;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/fab_mixin.dart';
import 'package:PiliPlus/pages/common/reply/reply_footer_mixin.dart';
import 'package:PiliPlus/pages/common/reply/reply_guard_suggestion_card.dart';
import 'package:PiliPlus/pages/common/reply/vote/reply_vote_item.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:PiliPlus/services/content_guard/presenter/presenter.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class VideoReplyPanel extends StatefulWidget {
  const VideoReplyPanel({
    super.key,
    this.replyLevel = 1,
    required this.heroTag,
    required this.isNested,
    this.contentGuardProjection,
  });

  final int replyLevel;
  final String heroTag;
  final bool isNested;

  /// ContentGuard's projection of the comment list, or null.
  ///
  /// Null means "no filtering", which is what every existing caller gets: the
  /// panel behaves exactly as before and does no extra lookup per row. When a
  /// projection is supplied it is only read *by index*, never used to change the
  /// item count, so the fold entry, the footer and the vote card keep the exact
  /// slot arithmetic they already have.
  final ReplyGuardProjection? contentGuardProjection;

  @override
  State<VideoReplyPanel> createState() => _VideoReplyPanelState();
}

class _VideoReplyPanelState extends State<VideoReplyPanel>
    with
        AutomaticKeepAliveClientMixin,
        SingleTickerProviderStateMixin,
        BaseFabMixin,
        FabMixin,
        ReplyFooterMixin<VideoReplyPanel, MainListReply> {
  @override
  late ColorScheme colorScheme;
  @override
  late VideoReplyController controller;

  String get heroTag => widget.heroTag;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    controller = Get.find<VideoReplyController>(tag: heroTag);
    if (controller.loadingState.value is Loading) {
      controller.queryData();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    controller.didChangeDependencies(context);
    colorScheme = ColorScheme.of(context);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return fabAnimWrapper(
      child: refreshIndicator(
        onRefresh: controller.onRefresh,
        isClampingScrollPhysics: widget.isNested,
        child: ScaffoldLayout(
          body: CustomScrollView(
            controller: widget.isNested ? null : controller.scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            key: const PageStorageKey(_VideoReplyPanelState),
            slivers: [
              SliverFloatingHeaderWidget(
                backgroundColor: colorScheme.surface,
                child: Padding(
                  padding: const .fromLTRB(12, 2.5, 6, 2.5),
                  child: Obx(() {
                    final sortType = controller.sortType.value;
                    return Row(
                      mainAxisAlignment: .spaceBetween,
                      children: [
                        Text(
                          sortType.desc,
                          style: const TextStyle(fontSize: 13),
                        ),
                        TextButton.icon(
                          style: Style.buttonStyle,
                          onPressed: controller.canSort.value
                              ? controller.queryBySort
                              : null,
                          icon: Icon(
                            Icons.sort,
                            size: 16,
                            color: controller.canSort.value
                                ? colorScheme.secondary
                                : colorScheme.outline,
                          ),
                          label: Text(
                            controller.canSort.value
                                ? sortType.descShort
                                : '排序不可用',
                            style: TextStyle(
                              fontSize: 13,
                              color: controller.canSort.value
                                  ? colorScheme.secondary
                                  : colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ),
              Obx(
                () {
                  // trigger rebuild when translation state changes
                  controller.translatedReplies.length;
                  return _buildBody(
                    controller.loadingState.value,
                  );
                },
              ),
            ],
          ),
          fab: SlideTransition(
            position: fabAnimation,
            child: Padding(
              padding: .only(
                right: kFloatingActionButtonMargin,
                bottom: kFloatingActionButtonMargin + padding.bottom,
              ),
              child: FloatingActionButton(
                heroTag: null,
                onPressed: () {
                  feedBack();
                  controller.onReply(
                    null,
                    oid: controller.videoCtr.aid,
                    replyType: controller.replyType,
                    mentionItem: controller.mentionItem,
                  );
                },
                tooltip: '发表评论',
                child: const Icon(Icons.reply),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(LoadingState<List<ReplyInfo>?> loadingState) {
    // Registers the suggestion map as a dependency of the enclosing `Obx`: an
    // item builder runs during layout, outside that closure, so without this read
    // a card that appears or disappears would only repaint on the next list
    // refresh. Reading its length is enough to subscribe to every change.
    controller.guardSuggestions.length;
    switch (loadingState) {
      case Loading():
        return const SliverPrototypeExtentList(
          prototypeItem: VideoReplySkeleton(),
          delegate: SliverSingleChildDelegate(
            count: 5,
            child: VideoReplySkeleton(),
          ),
        );
      case Success(:final response):
        if (response != null && response.isNotEmpty) {
          final voteCard = controller.voteCard;
          final hasVote = voteCard != null;
          // 折叠入口与普通分页各自占一个 slot：关闭自动加载折叠回复后，
          // 根评论仍能继续分页，不必先点开折叠内容。
          final showFoldEntry = controller.canShowFoldEntry;
          final foldIndex = showFoldEntry ? response.length : -1;
          final footerIndex = response.length + (showFoldEntry ? 1 : 0);
          final count = footerIndex + 1 + (hasVote ? 1 : 0);
          return SliverList.builder(
            itemBuilder: (context, index) {
              if (hasVote) {
                if (index == 0) {
                  return buildVoteCard(context, colorScheme, voteCard);
                } else {
                  index--;
                }
              }
              if (index == foldIndex) {
                return InkWell(
                  onTap: controller.loadFoldedReplies,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            controller.foldText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.keyboard_arrow_right,
                          size: 16,
                          color: colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (index == footerIndex) {
                return _buildReplyFooter(colorScheme);
              }
              final replyItem = response[index];
              final rpid = replyItem.id;
              final translated = controller.translatedReplies[rpid];
              // The projection is read at `index`, but a slot is accepted only
              // when its content id and payload revision still describe the reply
              // being built: a refresh, a removal, a pin, a sort or a pagination
              // append all leave a stale verdict sitting at an index that now means
              // another reply. A mismatch degrades to pending for this row instead
              // of borrowing a neighbour's verdict, and the count above is never
              // derived from the projection, so hidden rows keep their slots.
              final child = ReplyItemGrpc(
                replyItem: replyItem,
                replyLevel: widget.replyLevel,
                contentGuardPresentation: guardPresentationFor(
                  // The controller owns the projection; the widget parameter
                  // stays as an explicit override for a caller that supplies its
                  // own list. All of them are null when ContentGuard is not
                  // active, and then every row renders exactly as before.
                  projection:
                      widget.contentGuardProjection ??
                      controller.contentGuardProjection,
                  // The SAME facts object the controller registered the row
                  // with; a separate read could straddle a settings change and
                  // leave the row pending forever.
                  policyFacts: controller.guardPolicyFacts,
                  index: index,
                  reply: replyItem,
                ),
                replyReply: controller.replyReply,
                onReply: controller.onReply,
                onDelete: (item, subIndex) =>
                    controller.onRemove(index, item, subIndex),
                upMid: controller.upMid,
                getTag: () => heroTag,
                onCheckReply: controller.onCheckReply,
                onToggleTop: (item) => controller.onToggleTop(
                  item,
                  index,
                  controller.videoCtr.aid,
                  controller.effectiveVideoType.replyType,
                ),
                translatedText: translated != null && translated.isNotEmpty
                    ? translated
                    : null,
                isTranslating: translated != null && translated.isEmpty,
                isOfficialFolded: controller.foldedIds.contains(
                  rpid.toInt(),
                ),
                onTranslate: () => controller.translateReply(replyItem),
              );
              if (replyItem.id == controller.targetRootRpId) {
                return controller.colorAnimWrapper(
                  colorScheme,
                  child,
                );
              }
              // The suggestion card hangs UNDER its row, so it never becomes a
              // list item: the fold entry, the footer, the vote card and the
              // projection slot at every index keep their arithmetic.
              return GuardSuggestionSlot(
                child: child,
                anchor: controller.guardSuggestionAnchorAt(index),
                suggestion: controller.guardSuggestionAt(index),
                isBusy: controller.isDecidingSuggestion,
                onAccept: controller.acceptGuardSuggestion,
                onReject: controller.rejectGuardSuggestion,
              );
            },
            itemCount: count,
          );
        }

        final child = emptyWidget();
        if (controller.voteCard case final voteCard?) {
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: buildVoteCard(context, colorScheme, voteCard),
              ),
              child,
            ],
          );
        }
        return child;
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: controller.onReload,
        );
    }
  }

  /// 列表末尾 slot：续页失败时给可操作重试，其余情况照常自动加载。
  Widget _buildReplyFooter(ColorScheme colorScheme) {
    final errMsg = controller.loadMoreError.value;
    if (errMsg != null) {
      return InkWell(
        onTap: controller.onLoadMoreRetry,
        child: Container(
          height: 125,
          alignment: .center,
          margin: .only(bottom: padding.bottom),
          child: Column(
            mainAxisSize: .min,
            children: [
              Text(
                errMsg,
                textAlign: .center,
                style: TextStyle(fontSize: 12, color: colorScheme.error),
              ),
              const SizedBox(height: 6),
              Text(
                '点击重试',
                style: TextStyle(fontSize: 12, color: colorScheme.primary),
              ),
            ],
          ),
        ),
      );
    }
    if (!controller.isEnd) {
      controller.onLoadMore();
    }
    return Container(
      height: 125,
      alignment: .center,
      margin: .only(bottom: padding.bottom),
      child: Text(
        controller.isEnd ? '没有更多了' : '加载中...',
        textAlign: .center,
        style: TextStyle(fontSize: 12, color: colorScheme.outline),
      ),
    );
  }
}
