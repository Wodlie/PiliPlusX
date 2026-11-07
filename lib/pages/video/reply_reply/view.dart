import 'package:PiliPlus/common/skeleton/video_reply.dart';
import 'package:PiliPlus/common/sliver_single_child_delegate.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/simple_colored_box.dart';
import 'package:PiliPlus/common/widgets/sliver/sliver_pinned_header.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/reply/reply_footer_mixin.dart';
import 'package:PiliPlus/pages/common/slide/common_slide_page.dart';
import 'package:PiliPlus/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:PiliPlus/pages/video/reply_reply/controller.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/extension/widget_ext.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class VideoReplyReplyPanel extends CommonSlidePage {
  const VideoReplyReplyPanel({
    super.key,
    super.enableSlide,
    this.id,
    required this.oid,
    required this.rpid,
    this.dialog,
    this.firstFloor,
    required this.isVideoDetail,
    required this.replyType,
    this.isNested = false,
    this.upMid,
  });
  final int? id;
  final int oid;
  final int rpid;
  final int? dialog;
  final ReplyInfo? firstFloor;
  final bool isVideoDetail;
  final int replyType;
  final bool isNested;
  final Int64? upMid;

  static Future<void>? toReply({
    required int oid,
    required int rootId,
    int? rpId,
    required int type,
    Uri? uri,
  }) {
    return Get.to(
      arguments: {
        'oid': oid,
        'rpid': rootId,
        'id': ?rpId,
        'type': type,
        'enterUri': ?uri?.toString(), // save panel
      },
      () => SimpleScaffold(
        appBar: AppBar(
          title: const Text('评论详情'),
          actions: [
            IconButton(
              tooltip: '前往',
              onPressed: uri == null
                  ? null
                  : () => PiliScheme.routePush(uri, businessId: type),
              icon: const Icon(Icons.open_in_browser),
            ),
          ],
        ),
        body: ViewSafeArea(
          child: VideoReplyReplyPanel(
            enableSlide: false,
            oid: oid,
            rpid: rootId,
            isVideoDetail: false,
            replyType: type,
            firstFloor: null,
            id: rpId,
          ),
        ).constraintWidth(),
      ),
    );
  }

  @override
  State<VideoReplyReplyPanel> createState() => _VideoReplyReplyPanelState();
}

class _VideoReplyReplyPanelState extends State<VideoReplyReplyPanel>
    with SingleTickerProviderStateMixin, CommonSlideMixin, ReplyFooterMixin {
  @override
  late final VideoReplyReplyController controller;
  late final _tag = Utils.makeHeroTag('${widget.rpid}${widget.dialog}');
  @override
  ColorScheme get colorScheme => theme.colorScheme;
  late final bool isDialogue = widget.dialog != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollSontroller = PrimaryScrollController.of(context);
    controller
      ..didChangeDependencies(context)
      ..nestedController = scrollSontroller is ExtendedNestedScrollController
          ? scrollSontroller
          : null;
  }

  @override
  void initState() {
    super.initState();
    controller = Get.put(
      VideoReplyReplyController(
        hasRoot: widget.firstFloor != null,
        id: widget.id,
        oid: widget.oid,
        rpid: widget.rpid,
        dialog: widget.dialog,
        replyType: widget.replyType,
      ),
      tag: _tag,
    );
  }

  @override
  void dispose() {
    Get.delete<VideoReplyReplyController>(tag: _tag);
    super.dispose();
  }

  @override
  Widget buildPage() {
    Widget child() => enableSlide ? slideList() : buildList();
    return SimpleColoredBox(
      color: theme.canvasColor,
      child: MiniScaffold(
        body: widget.isVideoDetail
            ? Column(
                children: [
                  Container(
                    height: 45,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 1,
                          color: theme.dividerColor.withValues(alpha: 0.1),
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.only(left: 12, right: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(isDialogue ? '对话列表' : '评论详情'),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: Get.back,
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: child()),
                ],
              )
            : child(),
      ),
    );
  }

  ReplyInfo? get firstFloor => widget.firstFloor ?? controller.firstFloor.value;

  ScrollController get scrollController =>
      controller.nestedController ?? controller.scrollController;

  @override
  Widget buildList() {
    return refreshIndicator(
      onRefresh: controller.onRefresh,
      isClampingScrollPhysics: widget.isNested,
      child: CustomScrollView(
        key: ValueKey(scrollController.hashCode),
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (!isDialogue) ...[
            if ((widget.firstFloor ?? controller.firstFloor.value)
                case final firstFloor?)
              _header(theme, firstFloor)
            else
              Obx(() {
                // trigger rebuild when translation state changes
                controller.translatedReplies.length;
                final firstFloor = controller.firstFloor.value;
                if (firstFloor == null) {
                  return const SliverToBoxAdapter();
                }
                return _header(theme, firstFloor);
              }),
            _sortWidget(theme.colorScheme),
          ],
          Obx(() {
            // trigger rebuild when translation state changes
            controller.translatedReplies.length;
            return _buildBody(
              theme.colorScheme,
              controller.loadingState.value,
            );
          }),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, ReplyInfo firstFloor) {
    final rpid = firstFloor.id;
    final translated = controller.translatedReplies[rpid];
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: ReplyItemGrpc(
            replyItem: firstFloor,
            replyLevel: 2,
            needDivider: false,
            onReply: (replyItem) => controller.onReply(replyItem, index: -1),
            upMid: widget.upMid ?? controller.upMid,
            onCheckReply: (item) =>
                controller.onCheckReply(item, isManual: true),
            translatedText: translated != null && translated.isNotEmpty
                ? translated
                : null,
            isTranslating: translated != null && translated.isEmpty,
            onTranslate: () => controller.translateReply(firstFloor),
          ),
        ),
        SliverToBoxAdapter(
          child: Divider(
            height: 20,
            color: theme.dividerColor.withValues(alpha: 0.1),
            thickness: 6,
          ),
        ),
      ],
    );
  }

  Widget _sortWidget(ColorScheme colorScheme) {
    return SliverPinnedHeader(
      backgroundColor: colorScheme.surface,
      child: Padding(
        padding: const .fromLTRB(12, 2.5, 6, 2.5),
        child: Row(
          spacing: 6,
          children: [
            Obx(
              () {
                final count = controller.count.value;
                return count != -1
                    ? Text(
                        '相关回复共${NumUtils.numFormat(count)}条',
                        style: const TextStyle(fontSize: 13),
                      )
                    : const SizedBox.shrink();
              },
            ),
            Expanded(
              child: Obx(
                () => LinearProgressIndicator(
                  // ignore: deprecated_member_use
                  year2023: true,
                  borderRadius: const .all(.circular(4)),
                  value: controller.progress.value,
                  stopIndicatorColor: Colors.transparent,
                ),
              ),
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
              label: Obx(
                () => Text(
                  controller.canSort.value
                      ? controller.sortType.value.label
                      : '排序不可用',
                  style: TextStyle(
                    fontSize: 13,
                    color: controller.canSort.value
                        ? colorScheme.secondary
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

  Widget _buildBody(
    ColorScheme colorScheme,
    LoadingState<List<ReplyInfo>?> loadingState,
  ) {
    final jumpIndex = controller.index.value;
    return switch (loadingState) {
      Loading() => const SliverPrototypeExtentList(
        prototypeItem: VideoReplySkeleton(),
        delegate: SliverSingleChildDelegate(
          count: 8,
          child: VideoReplySkeleton(),
        ),
      ),
      Success(:final response!) => SuperSliverList.builder(
        listController: controller.listController,
        itemBuilder: (context, index) {
          if (index == response.length && controller.canShowFoldEntry) {
            final foldText = controller.foldCard.value?.bottomText;
            return InkWell(
              onTap: controller.loadFoldedReplies,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      foldText != null && foldText.isNotEmpty
                          ? foldText
                          : '显示被折叠评论',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.primary,
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
          if (index ==
              response.length + (controller.canShowFoldEntry ? 1 : 0)) {
            controller.onLoadMore();
            return Container(
              height: 125,
              alignment: Alignment.center,
              margin: .only(bottom: MediaQuery.viewPaddingOf(context).bottom),
              child: Text(
                controller.isEnd ? '没有更多了' : '加载中...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.outline,
                ),
              ),
            );
          }
          final child = _replyItem(context, response[index], index);
          if (jumpIndex == index) {
            return controller.colorAnimWrapper(colorScheme, child);
          }
          return child;
        },
        itemCount: response.length + 1 + (controller.canShowFoldEntry ? 1 : 0),
      ),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget _foldedMark(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 6, 13, 0),
      child: Row(
        children: [
          Icon(Icons.unfold_less, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '此评论已被 B 站官方折叠',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }
  Widget _replyItem(BuildContext context, ReplyInfo replyItem, int index) {
    final rpid = replyItem.id;
    final translated = controller.translatedReplies[rpid];
    final item = ReplyItemGrpc(
      replyItem: replyItem,
      replyLevel: isDialogue ? 3 : 2,
      onReply: (replyItem) => controller.onReply(replyItem, index: index),
      onDelete: (item, subIndex) => controller.onRemove(index, item, subIndex),
      upMid: controller.upMid,
      dialogueCallback: isDialogue
          ? _onJumpToParent
          : (replyItem) => _showDialogue(context, replyItem),
      getReplyChain: () => controller.getParentChain(index, firstFloor),
      onCheckReply: (item) => controller.onCheckReply(item, isManual: true),
      translatedText: translated != null && translated.isNotEmpty
          ? translated
          : null,
      isTranslating: translated != null && translated.isEmpty,
      onTranslate: () => controller.translateReply(replyItem),
    );
    if (!controller.foldedIds.contains(replyItem.id.toInt())) return item;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_foldedMark(context), item],
    );
  }

  void _onJumpToParent(ReplyInfo replyItem) {
    if (!controller.setIndexById(replyItem.parent)) {
      SmartDialog.showToast('评论可能已被删除');
    }
  }

  void _showDialogue(BuildContext context, ReplyInfo replyItem) {
    MiniScaffold.of(context).showBottomSheet(
      constraints: const BoxConstraints(),
      (context) => VideoReplyReplyPanel(
        oid: replyItem.oid.toInt(),
        rpid: replyItem.root.toInt(),
        dialog: replyItem.dialog.toInt(),
        replyType: widget.replyType,
        isVideoDetail: true,
        isNested: widget.isNested,
      ),
    );
  }
}

