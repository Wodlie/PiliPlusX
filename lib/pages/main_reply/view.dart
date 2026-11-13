import 'package:PiliPlus/common/skeleton/video_reply.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/sliver/sliver_floating_header.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, MainListReply;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/fab_mixin.dart';
import 'package:PiliPlus/pages/common/reply/reply_footer_mixin.dart';
import 'package:PiliPlus/pages/common/reply/reply_guard_suggestion_card.dart';
import 'package:PiliPlus/pages/main_reply/controller.dart';
import 'package:PiliPlus/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:PiliPlus/pages/video/reply_reply/view.dart';
import 'package:PiliPlus/services/content_guard/presenter/presenter.dart';
import 'package:PiliPlus/utils/extension/widget_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MainReplyPage extends StatefulWidget {
  const MainReplyPage({super.key, this.contentGuardProjection});

  /// ContentGuard's projection of the comment list, or null.
  ///
  /// Null is the existing behaviour: no filtering, no per-row lookup. A supplied
  /// projection is read by index only, so `itemCount: response.length + 1` and the
  /// footer slot keep their current arithmetic.
  final ReplyGuardProjection? contentGuardProjection;

  @override
  State<MainReplyPage> createState() => _MainReplyPageState();

  static void toMainReplyPage({
    required int oid,
    required int replyType,
  }) {
    Get.toNamed(
      '/mainReply',
      arguments: {
        'oid': oid,
        'replyType': replyType,
      },
    );
  }
}

class _MainReplyPageState extends State<MainReplyPage>
    with
        SingleTickerProviderStateMixin,
        BaseFabMixin,
        FabMixin,
        ReplyFooterMixin<MainReplyPage, MainListReply> {
  @override
  final MainReplyController controller = Get.put(
    MainReplyController(),
    tag: Utils.generateRandomString(8),
  );

  @override
  late ColorScheme colorScheme;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    colorScheme = ColorScheme.of(context);
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('查看评论')),
      body: fabAnimWrapper(
        child: refreshIndicator(
          onRefresh: controller.onRefresh,
          child: Padding(
            padding: EdgeInsets.only(
              left: padding.left,
              right: padding.right,
            ),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                buildReplyHeader(),
                Obx(() => _buildBody(controller.loadingState.value)),
              ],
            ),
          ),
        ).constraintWidth(),
      ),
      fab: SlideTransition(
        position: fabAnimation,
        child: Padding(
          padding: .only(
            right: kFloatingActionButtonMargin + padding.right,
            bottom: kFloatingActionButtonMargin + padding.bottom,
          ),
          child: FloatingActionButton(
            heroTag: null,
            onPressed: () {
              try {
                feedBack();
                controller.onReply(
                  null,
                  oid: controller.oid,
                  replyType: controller.replyType,
                );
              } catch (_) {}
            },
            tooltip: '评论',
            child: const Icon(Icons.reply),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(LoadingState<List<ReplyInfo>?> loadingState) {
    // Subscribes the enclosing `Obx` to the suggestion map: item builders run
    // during layout, outside that closure, so a card appearing or disappearing
    // needs this read to repaint without waiting for a list refresh.
    controller.guardSuggestions.length;
    return switch (loadingState) {
      Loading() => const SliverPrototypeExtentList(
        prototypeItem: VideoReplySkeleton(),
        delegate: SliverSingleChildDelegate(
          count: 10,
          child: VideoReplySkeleton(),
        ),
      ),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverList.builder(
                itemCount: response.length + 1,
                itemBuilder: (context, index) {
                  if (index == response.length) {
                    return buildFooter();
                  }

                  final replyItem = response[index];
                  final child = ReplyItemGrpc(
                    replyItem: replyItem,
                    replyLevel: 1,
                    // The footer slot at index == response.length is decided above
                    // and is untouched. For a row, the projection slot is accepted
                    // only while it still names this reply and this payload
                    // revision; otherwise the row renders as pending, never as a
                    // pass and never with another reply's verdict.
                    contentGuardPresentation: guardPresentationFor(
                      // Controller-owned projection and policy facts, with the
                      // widget parameter kept as an explicit override. All null
                      // when inactive.
                      projection:
                          widget.contentGuardProjection ??
                          controller.contentGuardProjection,
                      policyFacts: controller.guardPolicyFacts,
                      index: index,
                      reply: replyItem,
                    ),
                    replyReply: throttleReplyReply,
                    onReply: controller.onReply,
                    onDelete: (item, subIndex) =>
                        controller.onRemove(index, item, subIndex),
                    upMid: controller.upMid,
                    onCheckReply: controller.onCheckReply,
                    onToggleTop: (item) => controller.onToggleTop(
                      item,
                      index,
                      controller.oid,
                      controller.replyType,
                    ),
                  );
                  // Under the row, never its own item: itemCount and the footer
                  // slot keep their arithmetic.
                  return GuardSuggestionSlot(
                    child: child,
                    anchor: controller.guardSuggestionAnchorAt(index),
                    suggestion: controller.guardSuggestionAt(index),
                    isBusy: controller.isDecidingSuggestion,
                    onAccept: controller.acceptGuardSuggestion,
                    onReject: controller.rejectGuardSuggestion,
                  );
                },
              )
            : emptyWidget(),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget buildReplyHeader() {
    final secondary = colorScheme.secondary;
    return SliverFloatingHeaderWidget(
      backgroundColor: colorScheme.surface,
      child: Padding(
        padding: const .fromLTRB(12, 2.5, 6, 2.5),
        child: Row(
          mainAxisAlignment: .spaceBetween,
          children: [
            Obx(
              () {
                final count = controller.count.value;
                return Text(
                  '${count == -1 ? 0 : NumUtils.numFormat(count)}条回复',
                );
              },
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
                    ? secondary
                    : colorScheme.outline,
              ),
              label: Obx(
                () => Text(
                  controller.canSort.value
                      ? controller.sortType.value.descShort
                      : '排序不可用',
                  style: TextStyle(
                    fontSize: 13,
                    color: controller.canSort.value
                        ? secondary
                        : colorScheme.outline,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void throttleReplyReply(ReplyInfo replyItem, int? id) {
    EasyThrottle.throttle(
      'replyReply',
      const Duration(milliseconds: 500),
      () => replyReply(replyItem, id),
    );
  }

  void replyReply(ReplyInfo replyItem, int? id) {
    Get.to(
      SimpleScaffold(
        appBar: AppBar(
          title: const Text('评论详情'),
          shape: Border(
            bottom: BorderSide(
              color: colorScheme.outline.withValues(alpha: 0.1),
            ),
          ),
        ),
        body: ViewSafeArea(
          child: VideoReplyReplyPanel(
            enableSlide: false,
            id: id,
            oid: replyItem.oid.toInt(),
            rpid: replyItem.id.toInt(),
            isVideoDetail: false,
            replyType: controller.replyType,
            firstFloor: replyItem,
            upMid: controller.upMid,
          ),
        ).constraintWidth(),
      ),
      routeName: 'dynamicDetail-Copy',
    );
  }
}
