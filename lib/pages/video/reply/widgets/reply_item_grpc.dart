import 'dart:math';

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/common/widgets/dialog/report.dart';
import 'package:PiliPlus/common/widgets/extra_hit_test_widget.dart';
import 'package:PiliPlus/common/widgets/flutter/text/text.dart' as custom_text;
import 'package:PiliPlus/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/image_grid/image_grid_view.dart';
import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, ReplyControl, Content, Url, ReplyControl_VoteOption;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/dynamics/widgets/vote.dart';
import 'package:PiliPlus/pages/member/widget/medal_widget.dart';
import 'package:PiliPlus/pages/save_panel/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/widgets/zan_grpc.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/url_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:cached_network_image_ce/cached_network_image.dart'
    hide CacheManager;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:protobuf/protobuf.dart';

class BlockedReplyBanner extends StatelessWidget {
  const BlockedReplyBanner({
    super.key,
    required this.onExpand,
    required this.replyItem,
  });

  final VoidCallback onExpand;
  final ReplyInfo replyItem;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color disabledColor = theme.disabledColor;
    final Color primaryWithOpacity = theme.colorScheme.primary.withOpacity(0.6);
    final briefReason = ReplyGrpc.getBriefBlockReason(replyItem);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.block_outlined, size: 16, color: disabledColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '此评论已被屏蔽（$briefReason）。',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: disabledColor),
            ),
          ),
          GestureDetector(
            onTap: onExpand,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '查看评论',
                style: TextStyle(fontSize: 13, color: primaryWithOpacity),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ReplyItemGrpc extends StatefulWidget {
  const ReplyItemGrpc({
    super.key,
    required this.replyItem,
    required this.replyLevel,
    this.replyReply,
    this.needDivider = true,
    this.onReply,
    this.onDelete,
    this.upMid,
    this.showDialogue,
    this.getTag,
    this.onViewImage,
    this.onCheckReply,
    this.onToggleTop,
    this.jumpToDialogue,
    this.translatedText,
    this.isTranslating = false,
    this.onTranslate,
  });
  final ReplyInfo replyItem;
  final int replyLevel;
  final Function(ReplyInfo replyItem, int? rpid)? replyReply;
  final bool needDivider;
  final ValueChanged<ReplyInfo>? onReply;
  final Function(ReplyInfo replyItem, int? subIndex)? onDelete;
  final Int64? upMid;
  final VoidCallback? showDialogue;
  final Function? getTag;
  final VoidCallback? onViewImage;
  final ValueChanged<ReplyInfo>? onCheckReply;
  final ValueChanged<ReplyInfo>? onToggleTop;
  final VoidCallback? jumpToDialogue;

  /// Translated text for this reply. null/toggle to show original.
  final String? translatedText;

  /// Whether a translation request is in-flight.
  final bool isTranslating;

  /// Called when the translate button is tapped.
  final VoidCallback? onTranslate;

  static final _voteRegExp = RegExp(r"^\{vote:\d+?\}$");
  static final _timeRegExp = RegExp(r'^(?:\d+[:：])?\d+[:：]\d+$');
  static bool enableWordRe = Pref.enableWordRe;
  static int? replyLengthLimit = Pref.replyLengthLimit;

  @override
  State<ReplyItemGrpc> createState() => _ReplyItemGrpcState();
}

class _ReplyItemGrpcState extends State<ReplyItemGrpc> {
  bool _expanded = false;
  bool _loadManualImages = false;
  final Set<String> _tempUnblockImageUrls = {};
  int _blockImageVersion = 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);

    // 折叠横幅：独立返回值，不需要 InkWell 包装
    if (ReplyGrpc.isClientBlocked(widget.replyItem) &&
        Pref.showBlockedReplyBanner &&
        !_expanded) {
      return BlockedReplyBanner(
        onExpand: () => setState(() => _expanded = true),
        replyItem: widget.replyItem,
      );
    }

    void showMore() => showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: min(640, context.mediaQueryShortestSide),
      ),
      builder: (context) {
        return morePanel(
          context: context,
          item: widget.replyItem,
          onDelete: () => widget.onDelete?.call(widget.replyItem, null),
          isSubReply: false,
        );
      },
    );

    Widget child = Padding(
      padding: const .fromLTRB(12, 14, 8, 5),
      child:
          (ReplyGrpc.isClientBlocked(widget.replyItem) &&
              Pref.showBlockedReplyBanner &&
              _expanded)
          ? _buildExpandedBlocked(context, Theme.of(context))
          : _buildContent(context, colorScheme),
    );
    if (widget.needDivider) {
      child = Column(
        mainAxisSize: .min,
        children: [
          child,
          Divider(
            indent: 55,
            endIndent: 15,
            height: 0.3,
            color: colorScheme.outline.withValues(alpha: 0.08),
          ),
        ],
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => widget.replyReply?.call(widget.replyItem, null),
        onLongPress: showMore,
        onSecondaryTap: PlatformUtils.isMobile ? null : showMore,
        child: child,
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colorScheme) {
    final member = widget.replyItem.member;
    Widget header = GestureDetector(
      onTap: () {
        feedBack();
        Get.toNamed('/member?mid=${widget.replyItem.mid}');
      },
      child: ExtraHitTestWidget(
        width: 46,
        child: Row(
          crossAxisAlignment: .center,
          spacing: 12,
          children: [
            PendantAvatar(
              member.face,
              size: 34,
              badgeSize: 14,
              vipStatus: member.vipStatus.toInt(),
              officialType: member.officialVerifyType.toInt(),
              pendantImage: member.hasGarbPendantImage()
                  ? member.garbPendantImage
                  : null,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    spacing: 6,
                    children: [
                      Flexible(
                        child: Text(
                          member.name,
                          maxLines: 1,
                          overflow: .ellipsis,
                          style: TextStyle(
                            color: (member.vipStatus > 0 && member.vipType == 2)
                                ? colorScheme.vipColor
                                : colorScheme.outline,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      BiliUtils.levelPicture(
                        member.level.toInt(),
                        isSeniorMember: member.isSeniorMember == 1,
                        height: 11,
                      ),
                      if (widget.replyItem.mid == widget.upMid)
                        const PBadge(
                          text: 'UP',
                          size: PBadgeSize.small,
                          isStack: false,
                          fontSize: 9,
                        )
                      else if (GlobalData().showMedal &&
                          member.hasFansMedalLevel())
                        MedalWidget(
                          medalName: member.fansMedalName,
                          level: member.fansMedalLevel.toInt(),
                          backgroundColor: DmUtils.decimalToColor(
                            member.fansMedalColor.toInt(),
                          ),
                          nameColor: DmUtils.decimalToColor(
                            member.fansMedalColorName.toInt(),
                          ),
                          padding: const .symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                        ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.replyLevel == 0
                            ? DateFormatUtils.format(
                                widget.replyItem.ctime.toInt(),
                                format: DateFormatUtils.longFormatDs,
                              )
                            : DateFormatUtils.dateFormat(
                                widget.replyItem.ctime.toInt(),
                              ),
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.outline,
                        ),
                      ),
                      if (widget.replyItem.replyControl.hasLocation())
                        Text(
                          ' • ${widget.replyItem.replyControl.location}',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.outline,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (PendantAvatar.showDecorate) {
      final garb = widget.replyItem.memberV2.garb;
      if (garb.hasCardImage()) {
        const double height = 38.0;
        return Stack(
          clipBehavior: .none,
          children: [
            Positioned(
              top: 0,
              right: 0,
              height: height,
              child: CachedNetworkImage(
                height: height,
                memCacheHeight: height.cacheSize(context),
                imageUrl: ImageUtils.safeThumbnailUrl(garb.cardImage),
                placeholder: (_, _) => const SizedBox.shrink(),
              ),
            ),
            if (garb.hasCardNumber())
              Positioned(
                top: 0,
                right: 0,
                height: height,
                child: Center(
                  child: Text(
                    '${garb.fanNumPrefix}\n${garb.cardNumber}',
                    style: TextStyle(
                      fontSize: 8,
                      fontFamily: Assets.digitalNum,
                      color: Utils.parseColor(garb.cardFanColor),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const .only(right: 80),
              child: header,
            ),
          ],
        );
      }
    }
    return header;
  }

  Widget _buildVoteOption(
    ColorScheme colorScheme,
    ReplyControl_VoteOption voteOption,
  ) {
    return Text.rich(
      TextSpan(
        children: [
          switch (voteOption.labelKind) {
            .RED => TextSpan(
              text: '红方  ',
              style: TextStyle(color: colorScheme.vipColor),
            ),
            .BLUE => TextSpan(
              text: '蓝方  ',
              style: TextStyle(color: colorScheme.blue),
            ),
            _ => TextSpan(
              text: '投票  ',
              style: TextStyle(color: colorScheme.outline),
            ),
          },
          TextSpan(text: voteOption.desc),
        ],
      ),
      style: TextStyle(
        height: 1.75,
        fontSize: 12,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme colorScheme) {
    final replyControl = widget.replyItem.replyControl;
    final padding = EdgeInsets.only(
      left: widget.replyLevel == 0 ? 6 : 45,
      right: 6,
    );
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .start,
      children: [
        _buildHeader(context, colorScheme),
        const SizedBox(height: 10),
        if (replyControl.hasVoteOption())
          Padding(
            padding: padding,
            child: _buildVoteOption(colorScheme, replyControl.voteOption),
          ),
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isTranslating) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '翻译中，请稍等…',
                          style: TextStyle(
                            height: 1.6,
                            fontSize: 14,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (widget.translatedText != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.translate,
                        size: 14,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          widget.translatedText!,
                          style: TextStyle(
                            height: 1.75,
                            fontSize: 14,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              custom_text.Text.rich(
                primary: colorScheme.primary,
                style: const TextStyle(height: 1.75, fontSize: 14),
                maxLines: widget.replyLevel == 1
                    ? ReplyItemGrpc.replyLengthLimit
                    : null,
                TextSpan(
                  children: [
                    if (widget.replyItem.replyControl.isUpTop) ...[
                      const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: PBadge(
                          text: 'TOP',
                          size: PBadgeSize.small,
                          isStack: false,
                          type: PBadgeType.line_primary,
                          fontSize: 9,
                          textScaleFactor: 1,
                        ),
                      ),
                      const TextSpan(text: ' '),
                    ],
                    _buildMessage(
                      context,
                      colorScheme,
                      widget.replyItem.content,
                      widget.replyItem.replyControl,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (widget.replyItem.content.pictures.isNotEmpty) ...[
          Padding(
            padding: padding,
            child: _buildCommentImages(context, colorScheme),
          ),
          const SizedBox(height: 4),
        ],
        if (widget.replyLevel != 0) ...[
          const SizedBox(height: 4),
          buttonAction(context, colorScheme, replyControl),
        ],
        if (widget.replyLevel == 1 && widget.replyItem.count > Int64.ZERO) ...[
          Padding(
            padding: const EdgeInsets.only(top: 5, bottom: 12),
            child: replyItemRow(context, colorScheme, widget.replyItem.replies),
          ),
        ],
      ],
    );
  }

  Widget _buildExpandedBlocked(BuildContext context, ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          child: Text(
            '为何屏蔽：${ReplyGrpc.getBlockReason(widget.replyItem)}',
            style: TextStyle(color: theme.disabledColor, fontSize: 12),
          ),
        ),
        _buildContent(context, theme.colorScheme),
      ],
    );
  }

  Widget _buildCommentImages(BuildContext context, ColorScheme colorScheme) {
    final manualLoad = Pref.manualLoadCommentImage;
    if (!manualLoad || _loadManualImages) {
      return ImageGridView(
        key: ValueKey('img_$_blockImageVersion'),
        picArr: widget.replyItem.content.pictures
            .map(
              (item) => ImageModel(
                width: item.imgWidth,
                height: item.imgHeight,
                url: item.imgSrc,
              ),
            )
            .toList(),
        onViewImage: widget.onViewImage,
        tempUnblockedUrls: _tempUnblockImageUrls,
      );
    }
    final count = widget.replyItem.content.pictures.length;
    return GestureDetector(
      onTap: () => setState(() => _loadManualImages = true),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: colorScheme.onInverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_outlined,
              size: 28,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(
              '点击加载图片（共$count张）',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void deactivate() {
    _tempUnblockImageUrls.clear();
    super.deactivate();
  }

  Widget buttonAction(
    BuildContext context,
    ColorScheme colorScheme,
    ReplyControl replyControl,
  ) {
    final textStyle = TextStyle(
      height: 1,
      fontSize: 12,
      fontWeight: .normal,
      color: colorScheme.outline,
    );
    final buttonStyle = TextButton.styleFrom(
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Row(
      children: [
        const SizedBox(width: 36),
        SizedBox(
          height: 32,
          child: TextButton(
            style: buttonStyle,
            onPressed: () {
              feedBack();
              widget.onReply?.call(widget.replyItem);
            },
            child: Row(
              children: [
                Icon(
                  Icons.reply,
                  size: 18,
                  color: colorScheme.outline.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 3),
                Text('回复', style: textStyle),
              ],
            ),
          ),
        ),
        const SizedBox(width: 2),
        if (replyControl.cardLabels.isNotEmpty) ...[
          Text(
            replyControl.cardLabels.map((e) => e.textContent).join('  '),
            style: textStyle.copyWith(color: colorScheme.secondary),
          ),
          const SizedBox(width: 2),
        ],
        if (widget.replyLevel == 2 &&
            widget.needDivider &&
            widget.replyItem.id != widget.replyItem.dialog)
          SizedBox(
            height: 32,
            child: TextButton(
              onPressed: widget.showDialogue,
              style: buttonStyle,
              child: Text('查看对话', style: textStyle),
            ),
          )
        else if (widget.replyLevel == 3 &&
            widget.needDivider &&
            widget.replyItem.parent != widget.replyItem.root)
          SizedBox(
            height: 32,
            child: TextButton(
              onPressed: widget.jumpToDialogue,
              style: buttonStyle,
              child: Text('跳转回复', style: textStyle),
            ),
          ),
        const Spacer(),
        if (widget.onTranslate != null &&
            Pref.enableCommentTranslate &&
            widget.replyItem.replyControl.translationSwitch == 2) ...[
          if (widget.isTranslating)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '翻译中',
                    style: textStyle.copyWith(color: colorScheme.primary),
                  ),
                ],
              ),
            )
          else
            SizedBox(
              height: 32,
              child: TextButton(
                style: buttonStyle,
                onPressed: widget.onTranslate,
                child: Row(
                  children: [
                    Icon(
                      Icons.translate,
                      size: 17,
                      color: widget.translatedText != null
                          ? colorScheme.primary
                          : colorScheme.outline.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      widget.translatedText == null ? '翻译' : '原文',
                      style: widget.translatedText != null
                          ? textStyle.copyWith(color: colorScheme.primary)
                          : textStyle,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 2),
        ],
        ZanButtonGrpc(replyItem: widget.replyItem),
        const SizedBox(width: 5),
      ],
    );
  }

  Widget replyItemRow(
    BuildContext context,
    ColorScheme colorScheme,
    List<ReplyInfo> replies,
  ) {
    final visibleReplies = replies
        .where((r) => !ReplyGrpc.isClientBlocked(r))
        .toList();
    final extraRow = visibleReplies.length < widget.replyItem.count.toInt();
    late final length = visibleReplies.length + (extraRow ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(left: 42, right: 4),
      child: Material(
        color: colorScheme.onInverseSurface,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        clipBehavior: Clip.hardEdge,
        animationDuration: Duration.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (visibleReplies.isNotEmpty)
              ...List.generate(visibleReplies.length, (index) {
                final childReply = visibleReplies[index];
                EdgeInsets padding;
                if (length == 1) {
                  padding = const EdgeInsets.fromLTRB(8, 5, 8, 5);
                } else {
                  if (index == 0) {
                    padding = const EdgeInsets.fromLTRB(8, 8, 8, 4);
                  } else if (index == length - 1) {
                    padding = const EdgeInsets.fromLTRB(8, 4, 8, 8);
                  } else {
                    padding = const EdgeInsets.fromLTRB(8, 4, 8, 4);
                  }
                }
                void showMore() => showModalBottomSheet(
                  context: context,
                  useSafeArea: true,
                  isScrollControlled: true,
                  constraints: BoxConstraints(
                    maxWidth: min(640, context.mediaQueryShortestSide),
                  ),
                  builder: (context) {
                    return morePanel(
                      context: context,
                      item: childReply,
                      onDelete: () =>
                          widget.onDelete?.call(widget.replyItem, index),
                      isSubReply: true,
                    );
                  },
                );
                return InkWell(
                  onTap: () => widget.replyReply?.call(
                    widget.replyItem,
                    childReply.id.toInt(),
                  ),
                  onLongPress: showMore,
                  onSecondaryTap: PlatformUtils.isMobile ? null : showMore,
                  child: Padding(
                    padding: padding,
                    child: Text.rich(
                      style: TextStyle(
                        height: 1.6,
                        fontSize: 14,
                        color: colorScheme.onSurface.withValues(alpha: 0.85),
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                      TextSpan(
                        children: [
                          TextSpan(
                            text: childReply.member.name,
                            style: TextStyle(color: colorScheme.primary),
                            recognizer: NoDeadlineTapGestureRecognizer()
                              ..onTap = () {
                                feedBack();
                                Get.toNamed(
                                  '/member?mid=${childReply.member.mid}',
                                );
                              },
                          ),
                          if (childReply.mid == widget.upMid) ...[
                            const TextSpan(text: ' '),
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: PBadge(
                                text: 'UP',
                                size: PBadgeSize.small,
                                isStack: false,
                                fontSize: 9,
                                textScaleFactor: 1,
                              ),
                            ),
                            const TextSpan(text: ' '),
                          ],
                          TextSpan(
                            text: childReply.root == childReply.parent
                                ? ': '
                                : childReply.mid == widget.upMid
                                ? ''
                                : ' ',
                          ),
                          _buildMessage(
                            context,
                            colorScheme,
                            childReply.content,
                            childReply.replyControl,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            if (extraRow)
              InkWell(
                onTap: () => widget.replyReply?.call(widget.replyItem, null),
                child: Padding(
                  padding: length == 1
                      ? const EdgeInsets.fromLTRB(8, 6, 8, 6)
                      : const EdgeInsets.fromLTRB(8, 5, 8, 8),
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 12),
                      children: [
                        if (widget.replyItem.replyControl.upReply)
                          TextSpan(
                            text: 'UP主等人 ',
                            style: TextStyle(
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        TextSpan(
                          text: '共${widget.replyItem.count}条回复',
                          style: TextStyle(
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  InlineSpan _buildMessage(
    BuildContext context,
    ColorScheme colorScheme,
    Content content,
    ReplyControl replyControl,
  ) {
    final List<InlineSpan> spanChildren = <InlineSpan>[];
    bool hasNote = false;

    final urlKeys = content.urls.keys;
    // 构建正则表达式
    final List<String> specialTokens = [
      ...content.emotes.keys,
      ...content.topics.keys.map((e) => '#$e#'),
      ...content.atNameToMid.keys.map((e) => '@$e'),
      ...urlKeys,
    ];
    String patternStr = [
      ...specialTokens.map(RegExp.escape),
      r'(?:\d+[:：])?\d+[:：]\d+',
      r'\{vote:\d+?\}',
      Constants.urlRegex.pattern,
    ].join('|');
    final RegExp pattern = RegExp(patternStr);

    late List<String> matchedUrls = [];

    void addPlainTextSpan(str) {
      spanChildren.add(TextSpan(text: str));
    }

    void addUrl(String matchStr, Url url, {bool addPlainText = false}) {
      if (url.extra.isWordSearch && !ReplyItemGrpc.enableWordRe) {
        if (addPlainText) {
          addPlainTextSpan(matchStr);
        }
        return;
      }
      final isCv = url.clickReport.startsWith('{"cvid');
      if (isCv) {
        hasNote = true;
      }
      final children = [
        if (!isCv && url.hasPrefixIcon())
          WidgetSpan(
            child: CachedNetworkImage(
              height: 19,
              memCacheHeight: 19.cacheSize(context),
              color: colorScheme.primary,
              imageUrl: ImageUtils.thumbnailUrl(url.prefixIcon),
              placeholder: (_, _) => const SizedBox.shrink(),
            ),
          ),
        TextSpan(
          text: isCv ? '[笔记] ' : url.title,
          style: TextStyle(color: colorScheme.primary),
          recognizer: NoDeadlineTapGestureRecognizer()
            ..onTap = () {
              if (url.appUrlSchema.isEmpty) {
                if (RegExp(
                  r'^(av|bv)',
                  caseSensitive: false,
                ).hasMatch(matchStr)) {
                  UrlUtils.matchUrlPush(matchStr, '');
                } else {
                  RegExpMatch? match = RegExp(
                    r'^cv(\d+)$|/read/cv(\d+)|note-app/view\?cvid=(\d+)',
                    caseSensitive: false,
                  ).firstMatch(matchStr);
                  String? cvid =
                      match?.group(1) ?? match?.group(2) ?? match?.group(3);
                  if (cvid != null) {
                    Get.toNamed(
                      '/articlePage',
                      parameters: {
                        'id': cvid,
                        'type': 'read',
                      },
                    );
                    return;
                  }
                  PageUtils.handleWebview(matchStr);
                }
              } else {
                if (url.extra.isWordSearch) {
                  Get.toNamed(
                    '/searchResult',
                    parameters: {'keyword': url.title},
                  );
                } else {
                  PageUtils.handleWebview(matchStr);
                }
              }
            },
        ),
      ];
      if (isCv) {
        spanChildren.insertAll(0, children);
      } else {
        spanChildren.addAll(children);
      }
    }

    // 分割文本并处理每个部分
    content.message.splitMapJoin(
      pattern,
      onMatch: (Match match) {
        String matchStr = match[0]!;
        late final name = matchStr.substring(1);
        late final topic = matchStr.substring(1, matchStr.length - 1);
        if (content.emotes.containsKey(matchStr)) {
          // 处理表情
          final emote = content.emotes[matchStr]!;
          final size = emote.size.toInt() * 20.0;
          spanChildren.add(
            WidgetSpan(
              child: NetworkImgLayer(
                src: emote.hasWebpUrl()
                    ? emote.webpUrl
                    : emote.hasGifUrl()
                    ? emote.gifUrl
                    : emote.url,
                type: ImageType.emote,
                width: size,
                height: size,
              ),
            ),
          );
        } else if (matchStr.startsWith("@") &&
            content.atNameToMid.containsKey(name)) {
          // 处理@用户
          spanChildren.add(
            TextSpan(
              text: matchStr,
              style: TextStyle(color: colorScheme.primary),
              recognizer: NoDeadlineTapGestureRecognizer()
                ..onTap = () =>
                    Get.toNamed('/member?mid=${content.atNameToMid[name]}'),
            ),
          );
        } else if (ReplyItemGrpc._voteRegExp.hasMatch(matchStr)) {
          spanChildren.add(
            TextSpan(
              text: '投票: ${content.vote.title}',
              style: TextStyle(color: colorScheme.primary),
              recognizer: NoDeadlineTapGestureRecognizer()
                ..onTap = () =>
                    showVoteDialog(context, content.vote.id.toInt()),
            ),
          );
        } else if (ReplyItemGrpc._timeRegExp.hasMatch(matchStr)) {
          matchStr = matchStr.replaceAll('：', ':');
          bool isValid = false;
          try {
            final ctr = Get.find<VideoDetailController>(
              tag: widget.getTag?.call() ?? Get.arguments['heroTag'],
            );
            isValid =
                DurationUtils.parseDuration(matchStr) * 1000 <=
                ctr.data.timeLength!;
          } catch (e) {
            if (kDebugMode) debugPrint('failed to validate: $e');
          }
          spanChildren.add(
            TextSpan(
              text: isValid ? ' $matchStr ' : matchStr,
              style: isValid ? TextStyle(color: colorScheme.primary) : null,
              recognizer: isValid
                  ? (NoDeadlineTapGestureRecognizer()
                      ..onTap = () {
                        // 跳转到指定位置
                        try {
                          SmartDialog.showToast('跳转至：$matchStr');
                          Get.find<VideoDetailController>(
                            tag: Get.arguments['heroTag'],
                          ).plPlayerController.seekTo(
                            Duration(
                              seconds: DurationUtils.parseDuration(matchStr),
                            ),
                            isSeek: false,
                          );
                        } catch (e) {
                          SmartDialog.showToast('跳转失败: $e');
                        }
                      })
                  : null,
            ),
          );
        } else {
          final url = content.urls[matchStr];
          if (url != null && !matchedUrls.contains(matchStr)) {
            addUrl(matchStr, url, addPlainText: true);
            // 只显示一次
            matchedUrls.add(matchStr);
          } else if (matchStr.length > 1 && content.topics[topic] != null) {
            spanChildren.add(
              TextSpan(
                text: matchStr,
                style: TextStyle(color: colorScheme.primary),
                recognizer: NoDeadlineTapGestureRecognizer()
                  ..onTap = () {
                    Get.toNamed(
                      '/searchResult',
                      parameters: {'keyword': topic},
                    );
                  },
              ),
            );
          } else if (Constants.urlRegex.hasMatch(matchStr)) {
            spanChildren.add(
              TextSpan(
                text: matchStr,
                style: TextStyle(color: colorScheme.primary),
                recognizer: NoDeadlineTapGestureRecognizer()
                  ..onTap = () => PageUtils.handleWebview(matchStr),
              ),
            );
          } else {
            addPlainTextSpan(matchStr);
          }
        }
        return '';
      },
      onNonMatch: (String nonMatchStr) {
        addPlainTextSpan(nonMatchStr);
        return nonMatchStr;
      },
    );

    // if (urlKeys.isNotEmpty) {
    //   List<String> unmatchedItems = urlKeys
    //       .where((url) => !matchedUrls.contains(url))
    //       .toList();
    //   if (unmatchedItems.isNotEmpty) {
    //     for (final patternStr in unmatchedItems) {
    //       addUrl(patternStr, content.urls[patternStr]!);
    //     }
    //   }
    // }

    if (!hasNote && replyControl.isNote && replyControl.isNoteV2) {
      final Color color;
      NoDeadlineTapGestureRecognizer? recognizer;

      final hasClickUrl = content.richText.note.hasClickUrl();
      if (hasClickUrl || content.richText.opus.hasOpusId()) {
        color = colorScheme.primary;
        recognizer = NoDeadlineTapGestureRecognizer()
          ..onTap = () => hasClickUrl
              ? PiliScheme.routePushFromUrl(content.richText.note.clickUrl)
              : Get.toNamed(
                  '/articlePage',
                  parameters: {
                    'id': content.richText.opus.opusId.toString(),
                    'type': 'opus',
                  },
                );
      } else {
        color = colorScheme.secondary;
      }
      spanChildren.insert(
        0,
        TextSpan(
          text: '[笔记] ',
          style: TextStyle(color: color),
          recognizer: recognizer,
        ),
      );
    }

    return TextSpan(children: spanChildren);
  }

  Widget morePanel({
    required BuildContext context,
    required ReplyInfo item,
    required VoidCallback onDelete,
    required bool isSubReply,
  }) {
    late String message = item.content.message;
    final ownerMid = Int64(Accounts.reply.mid);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final errorColor = colorScheme.error;
    final style = theme.textTheme.titleSmall!;

    // Determine which pictures are blocked vs unblocked (from cache).
    bool hasBlockedImages = false;
    bool hasUnblockedImages = false;
    if (Pref.enableImageBlock) {
      for (final pic in item.content.pictures) {
        final blocked = ImageBlockService.getCachedBlockResult(pic.imgSrc);
        if (blocked == true) {
          hasBlockedImages = true;
        } else if (blocked == false) {
          hasUnblockedImages = true;
        } else {
          // Cache miss — treat as unblocked (default visible).
          hasUnblockedImages = true;
        }
        if (hasBlockedImages && hasUnblockedImages) break;
      }
    } else {
      hasUnblockedImages = item.content.pictures.isNotEmpty;
    }

    return Padding(
      padding: .only(
        bottom: MediaQuery.viewPaddingOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: Get.back,
            borderRadius: Style.bottomSheetRadius,
            child: SizedBox(
              height: 35,
              child: Center(
                child: Container(
                  width: 32,
                  height: 3,
                  decoration: BoxDecoration(
                    color: colorScheme.outline,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                ),
              ),
            ),
          ),
          if (kDebugMode && GStorage.reply != null) ...[
            ListTile(
              onTap: () {
                Get.back();
                GStorage.reply!.put(
                  item.id.toString(),
                  (item.deepCopy()
                        ..unknownFields.clear()
                        ..replies.clear()
                        ..clearTrackInfo())
                      .writeToBuffer(),
                );
              },
              title: Text(
                'save to local',
                style: style.copyWith(color: colorScheme.primary),
              ),
            ),
            ListTile(
              onTap: () {
                Get.back();
                onDelete();
                GStorage.reply!.delete(item.id.toString());
              },
              title: Text(
                'remove from local',
                style: style.copyWith(color: colorScheme.primary),
              ),
            ),
            ListTile(
              onTap: () {
                Get.back();
                final oid = item.oid.toInt();
                final data =
                    (item.deepCopy()
                          ..unknownFields.clear()
                          ..replies.clear()
                          ..clearTrackInfo())
                        .writeToBuffer();
                GStorage.reply!.putAll({
                  for (var i = oid; i < oid + 1000; i++) i.toString(): data,
                });
              },
              title: Text(
                'save to local (x1000)',
                style: style.copyWith(color: colorScheme.primary),
              ),
            ),
          ],
          if (ownerMid == widget.upMid || ownerMid == item.member.mid)
            ListTile(
              onTap: () async {
                Get.back();
                bool? isDelete = await showDialog<bool>(
                  context: context,
                  builder: (context) {
                    final colorScheme = ColorScheme.of(context);
                    return AlertDialog(
                      title: const Text('删除评论'),
                      content: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: '确定删除这条评论吗？\n\n'),
                            if (ownerMid != item.member.mid.toInt()) ...[
                              TextSpan(
                                text: '@${item.member.name}',
                                style: TextStyle(
                                  color: colorScheme.primary,
                                ),
                              ),
                              const TextSpan(text: ':\n'),
                            ],
                            TextSpan(text: message),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Get.back(result: false),
                          child: Text(
                            '取消',
                            style: TextStyle(
                              color: colorScheme.outline,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Get.back(result: true),
                          child: const Text('确定'),
                        ),
                      ],
                    );
                  },
                );
                if (isDelete == null || !isDelete) {
                  return;
                }
                SmartDialog.showLoading(msg: '删除中...');
                final res = await VideoHttp.replyDel(
                  type: item.type.toInt(),
                  oid: item.oid.toInt(),
                  rpid: item.id.toInt(),
                );
                SmartDialog.dismiss();
                if (res.isSuccess) {
                  SmartDialog.showToast('删除成功');
                  onDelete();
                } else {
                  SmartDialog.showToast('删除失败, $res');
                }
              },
              minLeadingWidth: 0,
              leading: Icon(Icons.delete_outlined, color: errorColor, size: 19),
              title: Text('删除', style: style.copyWith(color: errorColor)),
            ),
          if (ownerMid != Int64.ZERO)
            ListTile(
              onTap: () {
                Get.back();
                autoWrapReportDialog(
                  context,
                  ReportOptions.commentReport,
                  (reasonType, reasonDesc, banUid) async {
                    final res = await ReplyHttp.report(
                      rpid: item.id,
                      oid: item.oid,
                      reasonType: reasonType,
                      reasonDesc: reasonDesc,
                      banUid: banUid,
                    );
                    if (res.isSuccess) {
                      onDelete();
                    }
                    return res;
                  },
                  ban: ownerMid != Int64.ZERO,
                  showImageBlock: item.content.pictures.isNotEmpty,
                  imageUrls: item.content.pictures
                      .map((p) => p.imgSrc)
                      .toList(),
                  onBlockImages: (urls) async {
                    for (final url in urls) {
                      final entry = await ImageBlockService.blockImage(
                        url,
                        flipEnabled: Pref.imageBlockFlipEnabled,
                        rotateEnabled: Pref.imageBlockRotateEnabled,
                      );
                      if (entry != null) {
                        final list = Pref.imageBlockHashList;
                        if (!list.any((e) => e['pHash'] == entry['pHash'])) {
                          list.add(entry);
                          Pref.imageBlockHashList = list;
                          ImageBlockService.invalidateResultCache();
                        }
                      }
                    }
                  },
                );
              },
              minLeadingWidth: 0,
              leading: Icon(Icons.error_outline, color: errorColor, size: 19),
              title: Text('举报', style: style.copyWith(color: errorColor)),
            ),
          if (ownerMid != Int64.ZERO)
            ListTile(
              onTap: () async {
                Get.back();
                bool? isConfirm = await showDialog<bool>(
                  context: context,
                  builder: (context) {
                    final colorScheme = ColorScheme.of(context);
                    return AlertDialog(
                      title: const Text('拉黑评论者'),
                      content: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(
                              text: '确定将该用户加入黑名单？\n\n',
                            ),
                            TextSpan(
                              text: '@${item.member.name}',
                              style: TextStyle(color: colorScheme.primary),
                            ),
                            const TextSpan(text: '\n该评论将被屏蔽，无需再次拉黑'),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Get.back(result: false),
                          child: Text(
                            '取消',
                            style: TextStyle(color: colorScheme.outline),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Get.back(result: true),
                          child: const Text('确定'),
                        ),
                      ],
                    );
                  },
                );
                if (isConfirm != true) return;
                SmartDialog.showLoading(msg: '正在拉黑...');
                final res = await VideoHttp.relationMod(
                  mid: item.member.mid.toInt(),
                  act: 5,
                  reSrc: 11,
                );
                SmartDialog.dismiss();
                if (res.isSuccess) {
                  final mid = item.member.mid.toInt();
                  GlobalData().blackMids.add(mid);
                  Pref.setBlackMid(mid);
                  onDelete();
                  SmartDialog.showToast('已拉黑该用户');
                } else {
                  SmartDialog.showToast('拉黑失败');
                }
              },
              minLeadingWidth: 0,
              leading: Icon(Icons.block, color: errorColor, size: 19),
              title: Text('拉黑评论者', style: style.copyWith(color: errorColor)),
            ),
          if (widget.replyLevel == 1 && !isSubReply && ownerMid == widget.upMid)
            ListTile(
              onTap: () {
                Get.back();
                widget.onToggleTop?.call(item);
              },
              minLeadingWidth: 0,
              leading: const Icon(Icons.vertical_align_top, size: 19),
              title: Text(
                '${widget.replyItem.replyControl.isUpTop ? '取消' : ''}置顶',
                style: style,
              ),
            ),
          ListTile(
            onTap: () {
              Get.back();
              Utils.copyText(message);
            },
            minLeadingWidth: 0,
            leading: const Icon(Icons.copy_all_outlined, size: 19),
            title: Text('复制全部', style: style),
          ),
          ListTile(
            onTap: () {
              Get.back();
              showDialog(
                context: context,
                builder: (context) => Dialog(
                  child: Padding(
                    padding: const .symmetric(horizontal: 20, vertical: 16),
                    child: SelectableText(
                      message,
                      style: const TextStyle(fontSize: 15, height: 1.7),
                    ),
                  ),
                ),
              );
            },
            minLeadingWidth: 0,
            leading: const Icon(Icons.copy_outlined, size: 19),
            title: Text('自由复制', style: style),
          ),
          if (Pref.enableImageBlock && hasUnblockedImages)
            ListTile(
              onTap: () async {
                Get.back();
                final pictures = item.content.pictures;
                if (pictures.length <= 1) {
                  // Single image: block directly.
                  final entry = await ImageBlockService.blockImage(
                    pictures.first.imgSrc,
                    flipEnabled: Pref.imageBlockFlipEnabled,
                    rotateEnabled: Pref.imageBlockRotateEnabled,
                  );
                  if (entry != null) {
                    final list = Pref.imageBlockHashList;
                    if (!list.any((e) => e['pHash'] == entry['pHash'])) {
                      list.add(entry);
                      Pref.imageBlockHashList = list;
                      ImageBlockService.invalidateResultCache();
                    }
                  }
                  if (mounted) setState(() => _blockImageVersion++);
                  SmartDialog.showToast('已屏蔽图片');
                  return;
                }

                // Multiple images: show selection dialog.
                final selected = <int>{};
                for (int i = 0; i < pictures.length; i++) {
                  selected.add(i);
                }

                final result = await showDialog<bool>(
                  context: context,
                  builder: (ctx) {
                    final colorScheme = ColorScheme.of(ctx);
                    return StatefulBuilder(
                      builder: (context, setDialogState) {
                        return AlertDialog(
                          title: const Text('选择要屏蔽的图片'),
                          content: SizedBox(
                            width: double.maxFinite,
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                CheckboxListTile(
                                  value: selected.length == pictures.length,
                                  tristate: false,
                                  onChanged: (v) {
                                    setDialogState(() {
                                      if (v == true) {
                                        for (int i = 0;
                                            i < pictures.length;
                                            i++) {
                                          selected.add(i);
                                        }
                                      } else {
                                        selected.clear();
                                      }
                                    });
                                  },
                                  title: const Text('全选'),
                                ),
                                const Divider(height: 1),
                                for (int i = 0; i < pictures.length; i++)
                                  CheckboxListTile(
                                    value: selected.contains(i),
                                    onChanged: (v) {
                                      setDialogState(() {
                                        if (v == true) {
                                          selected.add(i);
                                        } else {
                                          selected.remove(i);
                                        }
                                      });
                                    },
                                    title: Text('图片 ${i + 1}'),
                                  ),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(
                                '取消',
                                style: TextStyle(
                                  color: colorScheme.outline,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('确定'),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );

                if (result != true || selected.isEmpty) return;

                for (final i in selected) {
                  final entry = await ImageBlockService.blockImage(
                    pictures[i].imgSrc,
                    flipEnabled: Pref.imageBlockFlipEnabled,
                    rotateEnabled: Pref.imageBlockRotateEnabled,
                  );
                  if (entry != null) {
                    final list = Pref.imageBlockHashList;
                    if (!list.any((e) => e['pHash'] == entry['pHash'])) {
                      list.add(entry);
                      Pref.imageBlockHashList = list;
                      ImageBlockService.invalidateResultCache();
                    }
                  }
                }
                if (mounted) setState(() => _blockImageVersion++);
                SmartDialog.showToast(
                  '已屏蔽${selected.length}张图片',
                );
              },
              minLeadingWidth: 0,
              leading: Icon(
                Icons.image_not_supported_outlined,
                color: errorColor,
                size: 19,
              ),
              title: Text('屏蔽图片', style: style.copyWith(color: errorColor)),
            ),
          if (Pref.enableImageBlock && hasBlockedImages)
            ListTile(
              onTap: () {
                Get.back();
                setState(() {
                  _tempUnblockImageUrls.addAll(
                    item.content.pictures.map((p) => p.imgSrc),
                  );
                  _blockImageVersion++;
                });
                SmartDialog.showToast('已临时恢复图片显示');
              },
              minLeadingWidth: 0,
              leading: Icon(
                Icons.image_outlined,
                color: errorColor,
                size: 19,
              ),
              title: Text('恢复图片显示', style: style.copyWith(color: errorColor)),
            ),
          ListTile(
            onTap: () {
              Get.back();
              SavePanel.toSavePanel(upMid: widget.upMid, item: item);
            },
            minLeadingWidth: 0,
            leading: const Icon(Icons.save_alt, size: 19),
            title: Text('保存评论', style: style),
          ),
          if (kDebugMode || item.mid == ownerMid)
            ListTile(
              onTap: () {
                Get.back();
                widget.onCheckReply?.call(item);
              },
              minLeadingWidth: 0,
              leading: const Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(Icons.shield_outlined, size: 19),
                  Icon(Icons.reply, size: 12),
                ],
              ),
              title: Text('检查评论', style: style),
            ),
        ],
      ),
    );
  }
}
