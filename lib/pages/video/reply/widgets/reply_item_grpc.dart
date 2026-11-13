import 'dart:math';

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/utils/image_block_service.dart';
import 'package:PiliPlus/common/widgets/dialog/report.dart';
import 'package:PiliPlus/common/widgets/emote_tooltip.dart';
import 'package:PiliPlus/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/image_grid/image_grid_view.dart';
import 'package:PiliPlus/common/widgets/pendant_avatar.dart';
import 'package:PiliPlus/common/widgets/selection_text.dart';
import 'package:PiliPlus/common/widgets/text_more/text_more.dart';
import 'package:PiliPlus/common/widgets/translucent_row.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show
        ReplyInfo,
        ReplyControl,
        Content,
        Picture,
        Url,
        ReplyControl_VoteOption,
        Emote;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/pages/video/reply_reply/tree.dart' show ReasonType;
import 'package:PiliPlus/pages/video/reply/widgets/reply_threaded_indent_box.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/dynamics/widgets/vote.dart';
import 'package:PiliPlus/pages/member/widget/medal_widget.dart';
import 'package:PiliPlus/pages/save_panel/view.dart';
import 'package:PiliPlus/services/content_guard/presenter/presenter.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/widgets/zan_grpc.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/request_identity_adapter.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/selectable_region_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/url_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:cached_network_image_ce/cached_network_image.dart'
    hide CacheManager;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
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

/// Placeholder shown instead of a comment body ContentGuard withheld.
///
/// It keeps the row's slot: the row is never removed from the list, only replaced,
/// so the scroll offset and every anchor computed from the list survive. The reason
/// is a machine code mapped to a short label — never the comment text, which the
/// decision layer never carries anyway.
class ContentGuardReplyBanner extends StatelessWidget {
  const ContentGuardReplyBanner({
    super.key,
    required this.presentation,
    this.onExpand,
  });

  final ReplyPresentation presentation;

  /// Expands the row into its body. Null when the restriction is not liftable,
  /// in which case no action is offered rather than a dead one.
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.disabledColor;
    final canExpand = onExpand != null && presentation.canExpand;
    final label = presentation.isHidden ? '此评论已被屏蔽' : '此评论已被折叠';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      child: Row(
        children: [
          Icon(
            presentation.isHidden
                ? Icons.visibility_off_outlined
                : Icons.unfold_less,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
          if (canExpand)
            GestureDetector(
              onTap: onExpand,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '查看评论',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown while ContentGuard has not decided about this row yet.
///
/// It is a placeholder, not a pass: the row exists so the list keeps its slots,
/// and the user sees that nothing has been settled rather than an apparently
/// unconditional comment. It is deliberately not a spinner in the middle of the
/// row — a blocked layout shift on every refresh is worse than a quiet line — but
/// the label and the icon make the undecided state explicit.
class ContentGuardPendingNotice extends StatelessWidget {
  const ContentGuardPendingNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.hourglass_empty, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '内容审核中，结果未定',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown above the body of a row ContentGuard could not settle.
///
/// [PresenterState.uncertain] keeps the body — the comment is not withheld — and
/// adds this notice so an unsettled verdict never reads as a quiet pass. The
/// action re-runs nothing itself: it hands control back to the page, which owns
/// the decision pass.
class ContentGuardUncertainNotice extends StatelessWidget {
  const ContentGuardUncertainNotice({super.key, this.onRetry});

  /// Re-runs the decision pass for this row. Null when the page wired no retry,
  /// in which case no action is offered rather than a dead one.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(45, 6, 6, 0),
      child: Row(
        children: [
          Icon(Icons.report_gmailerrorred_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '内容未能确认，已按未判定展示',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
          if (onRetry != null)
            GestureDetector(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '重试',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown in place of comment pictures ContentGuard masked.
///
/// A masked row keeps its body — only the named media identities are withheld — so
/// this stands where the grid would have been instead of replacing the whole row.
class ContentGuardMediaMask extends StatelessWidget {
  const ContentGuardMediaMask({
    super.key,
    required this.colorScheme,
    this.label = '图片已被内容过滤隐藏',
  });

  final ColorScheme colorScheme;

  /// What was withheld. The mask is also used for an avatar, where naming pictures
  /// would be wrong: the reader must be told which media is gone, not merely that
  /// something is.
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: colorScheme.onInverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            size: 28,
            color: colorScheme.outline,
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// Stands in for a comment avatar ContentGuard masked.
///
/// Deliberately the size of the avatar it replaces (34 px, the same value
/// [ReplyItemGrpc] hands [PendantAvatar]) so the header keeps its layout: the
/// nickname, badges, time and body stay exactly where they were. Only the avatar is
/// withheld — an avatar decision says nothing about the comment text, which has
/// its own decision.
class ContentGuardAvatarMask extends StatelessWidget {
  const ContentGuardAvatarMask({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '头像已被内容过滤隐藏',
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colorScheme.onInverseSurface,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.person_off_outlined,
          size: 18,
          color: colorScheme.outline,
        ),
      ),
    );
  }
}

/// The opaque revision of one reply payload ContentGuard judged.
///
/// The reply model carries no server-side version, so the only way to tie a
/// verdict to the text it actually saw is to derive a value from the facts a
/// decision depends on: the comment id, its author, its creation time, its
/// message and the URLs of its pictures. Any edit that changes the message or the
/// media changes this value, which is what makes a verdict computed for the
/// previous revision refused instead of relabelled — the bridge compares this
/// string for equality and never parses it.
///
/// Counter fields (likes, reply counts) are deliberately excluded UNLESS a
/// filter reads them: the @-filter's like exemption does read the like count, and
/// [replyGuardVersionOfReply] folds it in for exactly that reason.
///
/// The derivation itself lives in [replyGuardVersionOfReply], over the SAME
/// [ReplyGuardPolicyFacts] the controller that registered the row used. Reading
/// the settings here instead would be a second route into the version: a settings
/// change landing between the controller's read and the widget's would change one
/// side only, and every row would read as pending forever.
String guardContentVersionOf(
  ReplyInfo reply,
  ReplyGuardPolicyFacts facts,
) => replyGuardVersionOfReply(reply, facts);

/// Media identity keys a comment picture may have been named by.
///
/// A decision stores [MediaRef.stableKey] values, and a picture reaches the row as
/// a URL only. The decision layer's platform id for a picture is not recoverable
/// from the URL in general, so every spelling a page-side adapter can plausibly
/// have used is offered and membership decides: the raw URL, the URL with the
/// Bilibili `@...` format suffix and query string stripped, and the bare file name
/// the CDN serves it under.
///
/// The set is intentionally a *candidate* set. Matching on it can only ever
/// confirm a key the decision already carries; it never invents a mask.
Set<String> guardMediaKeysOfContent(String? url) {
  final value = url;
  if (value == null || value.isEmpty) return const <String>{};
  final normalized = ImageBlockService.normalizeUrl(value);
  final keys = <String>{'id:' + value};
  if (normalized.isNotEmpty) {
    keys.add('id:' + normalized);
    final slash = normalized.lastIndexOf('/');
    final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    if (name.isNotEmpty) keys.add('id:' + name);
  }
  return keys;
}

/// Media identity keys this reply's avatar may have been named by.
///
/// An avatar is identified by the author in the decision layer (an avatar seed is
/// the uid) and by its URL in the page, so both are offered plus the normalised
/// URL. Kept separate from [guardMediaKeysOfContent] on purpose: an avatar mask
/// must never be able to match a comment picture, and vice versa.
Set<String> guardMediaKeysOfAvatar(String? faceUrl, {String? authorUid}) {
  final keys = <String>{};
  final uid = authorUid;
  if (uid != null && uid.isNotEmpty) keys.add('id:' + uid);
  final value = faceUrl;
  if (value == null || value.isEmpty) return keys;
  keys.add('id:' + value);
  final normalized = ImageBlockService.normalizeUrl(value);
  if (normalized.isNotEmpty) {
    keys.add('id:' + normalized);
    final slash = normalized.lastIndexOf('/');
    final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    if (name.isNotEmpty) keys.add('id:' + name);
  }
  return keys;
}

/// ContentGuard's verdict for the reply about to be rendered at [index].
///
/// A projection is a snapshot of a list; an index is a position, not an
/// identity. A refresh, a removal, a sort, a pin and a pagination append all
/// leave a row sitting at an index that used to describe another reply, so a
/// slot is accepted only when every part of the row identity still agrees with
/// the reply being rendered:
///
/// * the slot's content id comes from the projection, never from the caller;
/// * the payload revision is [guardContentVersionOf] of the *current* reply, so
///   a verdict computed for an edited comment cannot land on the edit;
/// * the list revision is the projection's own generation, carried into the
///   pending row so a widget can reset the state it bound to the previous one.
///
/// A mismatch yields [ReplyPresentation.pending] rather than null: "no decision
/// for this row" must render as an undecided row, never as a silent pass.
///
/// A null [projection] OR a null [policyFacts] is the unwired case and stays
/// null, so every page that has not opted in renders exactly what it rendered
/// before. The two arrive together from the same controller, which is the only
/// owner of both the list revision and the policy revision.
ReplyPresentation? guardPresentationFor({
  required ReplyGuardProjection? projection,
  required ReplyGuardPolicyFacts? policyFacts,
  required int index,
  required ReplyInfo reply,
}) {
  if (projection == null || policyFacts == null) return null;
  final contentId = reply.id.toString();
  final contentVersion = guardContentVersionOf(reply, policyFacts);
  ReplyPresentation pending() => ReplyPresentation.pending(
    contentId: contentId,
    contentVersion: contentVersion,
    generation: projection.generation,
  );
  if (index < 0 || index >= projection.contentIds.length) return pending();
  if (projection.contentIds[index] != contentId) return pending();
  final presentation = projection.forContentId(contentId);
  if (presentation == null) return pending();
  if (presentation.contentId != contentId ||
      presentation.contentVersion != contentVersion ||
      presentation.generation != projection.generation) {
    return pending();
  }
  return presentation;
}

class ReplyItemGrpc extends StatefulWidget {
  const ReplyItemGrpc({
    super.key,
    required this.replyItem,
    required this.replyLevel,
    this.replyReply,
    this.needDivider = true,
    this.isOfficialFolded = false,
    this.onReply,
    this.onDelete,
    this.upMid,
    this.showDialogue,
    this.dialogueCallback,
    this.getReplyChain,
    this.getTag,
    this.onViewImage,
    this.onCheckReply,
    this.onToggleTop,
    this.jumpToDialogue,
    this.translatedText,
    this.isTranslating = false,
    this.onTranslate,
    this.forceShowOriginalContent = false,
    this.depth,
    this.reason,
    this.collapsed,
    this.toggleCollapse,
    this.onScrollLeft,
    this.contentGuardPresentation,
    this.onContentGuardRetry,
  });
  final ReplyInfo replyItem;
  final int replyLevel;
  final Function(ReplyInfo replyItem, int? rpid)? replyReply;
  final bool isOfficialFolded;
  final bool needDivider;
  final ValueChanged<ReplyInfo>? onReply;
  final Function(ReplyInfo replyItem, int? subIndex)? onDelete;
  final Int64? upMid;
  final VoidCallback? showDialogue;

  /// 上游 2.2.0 的对话入口：level 2 打开对话面板，level 3 跳转父评论。
  /// fork 的 showDialogue/jumpToDialogue 保持可用；两者皆空时按钮禁用。
  final void Function(ReplyInfo replyItem)? dialogueCallback;

  /// 上游 2.2.0 的「复制整条回复链」取数入口（fork 菜单暂未接线）。
  final Iterable<ReplyInfo> Function()? getReplyChain;
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

  /// When true, always show the original comment content,
  /// skipping blocked/expanded-blocked banners.
  final bool forceShowOriginalContent;

  /// Threaded-reply indent depth (0 = flat list).
  final int? depth;

  /// Why this node was folded/suppressed in threaded mode.
  final ReasonType? reason;

  /// Non-zero when the subtree is collapsed.
  final int? collapsed;

  /// Toggles subtree collapse; null for leaves.
  final VoidCallback? toggleCollapse;

  /// Jumps to the parent reply when the indent line is scrolled left.
  final VoidCallback? onScrollLeft;

  /// ContentGuard's verdict for this row, or null.
  ///
  /// Null means "no filtering": every call site that does not wire ContentGuard
  /// keeps rendering exactly what it rendered before, and the widget performs no
  /// extra lookup. A non-null value can only withhold content — it replaces the
  /// body with a placeholder banner for a collapsed/hidden row or masks the media
  /// identities it names. It never removes the row and never changes the list
  /// length, so pagination, scroll position and the suggestion anchors computed
  /// from the same list stay valid.
  ///
  /// This is deliberately additive rather than a required parameter: seven call
  /// sites construct this widget and none of them should have to change for
  /// ContentGuard to be wired into one of them.
  final ReplyPresentation? contentGuardPresentation;

  /// Re-runs the ContentGuard decision pass for this row.
  ///
  /// Used by the uncertain notice, which is the one guard state where asking again
  /// can legitimately change the answer. Null when the page wired no retry; the
  /// notice then explains the state without offering an action that does nothing.
  final VoidCallback? onContentGuardRetry;

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

  /// Identity of the row the guard UI state below belongs to.
  ///
  /// A [ReplyItemGrpc] instance outlives the reply it draws: list builders reuse
  /// element slots, so the same State renders reply A and then reply B at the same
  /// index after a refresh, a pin, a sort or a pagination append. Every piece of
  /// guard state that the user can change is therefore stamped with the tuple it
  /// was created under — the pid, the payload revision and the list generation —
  /// and dropped the moment that tuple changes. Without the stamp, expanding a
  /// collapsed row would leak the expanded body into whichever reply later lands
  /// in the same slot.
  String? _guardIdentity;

  /// Whether the user expanded this row past its collapsed/hidden banner.
  bool _guardExpanded = false;

  /// The verdict this row renders, resolved for the *current* reply identity.
  ///
  /// [ReplyItemGrpc.contentGuardPresentation] is only trusted while it names this
  /// reply, this payload revision and this list revision; anything else is a
  /// leftover from the previous occupant of the slot and is degraded to pending
  /// by [guardPresentationFor] before it reaches the widget. A null verdict means
  /// nothing is wired at all and every guard branch is skipped.
  ReplyPresentation? get _guard {
    if (widget.forceShowOriginalContent) return null;
    return widget.contentGuardPresentation;
  }

  /// Binds the mutable guard state to [guard]'s identity tuple.
  ///
  /// Called from [build], so the reset happens before any branch reads the state
  /// and always in the same frame the new identity is rendered. Returning from a
  /// reset without a second build is safe: the only field it touches is read
  /// later in this very build.
  void _bindGuardIdentity(ReplyPresentation? guard) {
    final identity = guard == null
        ? null
        : [
            guard.contentId,
            guard.contentVersion,
            guard.generation.toString(),
          ].join('|');
    if (identity == _guardIdentity) return;
    _guardIdentity = identity;
    _guardExpanded = false;
  }

  /// Drops expansion when the verdict turned non-recoverable.
  ///
  /// An expansion is a local read of the row the user already received, so it
  /// survives a re-decision that keeps it liftable. It must not survive one that
  /// does not: a row that became hidden, or a verdict whose restriction can no
  /// longer be lifted, has no body to expand into, and leaving the flag set would
  /// silently re-expand the row if it ever became recoverable again.
  void _syncGuardExpansion(ReplyPresentation? guard) {
    if (!_guardExpanded) return;
    if (guard == null || !guard.canExpand) _guardExpanded = false;
  }

  @override
  void didUpdateWidget(ReplyItemGrpc oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reply itself changed under a stable index — the row reuse case that a
    // keyed identity check inside build cannot cover, because build only runs for
    // the verdict. Manual image loading and temporary unblocks are about the
    // pictures of one reply, so they must go with it.
    if (oldWidget.replyItem.id != widget.replyItem.id) {
      _loadManualImages = false;
      _tempUnblockImageUrls.clear();
      _blockImageVersion++;
    }
  }

  @override
  Widget _buildItem(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final guard = _guard;

    // ContentGuard 占位：先于客户端屏蔽横幅判断，二者语义互不覆盖。
    // 折叠/隐藏的评论保留槽位（绝不从列表移除），否则下方每一行都会位移，
    // 分页、滚动位置与推荐锚点都会错位。
    if (guard != null && guard.isPending) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.isOfficialFolded) _buildOfficialFoldMark(context),
          const ContentGuardPendingNotice(),
        ],
      );
    }

    if (guard != null && guard.showsPlaceholderBanner && !_guardExpanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.isOfficialFolded) _buildOfficialFoldMark(context),
          ContentGuardReplyBanner(
            presentation: guard,
            onExpand: guard.canExpand
                ? () => setState(() => _guardExpanded = true)
                : null,
          ),
        ],
      );
    }

    // 折叠横幅：独立返回值，不需要 InkWell 包装
    if (!widget.forceShowOriginalContent &&
        ReplyGrpc.isClientBlocked(widget.replyItem) &&
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
          (!widget.forceShowOriginalContent &&
              ReplyGrpc.isClientBlocked(widget.replyItem) &&
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
    final itemWidget = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => widget.replyReply?.call(widget.replyItem, null),
        onLongPress: showMore,
        onSecondaryTap: PlatformUtils.isMobile ? null : showMore,
        child: child,
      ),
    );
    if (!widget.isOfficialFolded) return itemWidget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_buildOfficialFoldMark(context), itemWidget],
    );
  }

  /// The "folded by Bilibili itself" mark.
  ///
  /// Extracted so the guard placeholder renders the very same mark instead of a
  /// second, drifting copy; `isOfficialFolded` keeps meaning exactly what it meant
  /// — this row is folded by the platform — and is never set by ContentGuard.
  Widget _buildOfficialFoldMark(BuildContext context) {
    final markColor = Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 6, 13, 0),
      child: Row(
        children: [
          Icon(Icons.unfold_less, size: 16, color: markColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '此评论已被 B 站官方折叠',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: markColor),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Resolve the row identity before anything reads the mutable guard state, so
    // a recycled slot can never render the previous reply's expansion.
    final guard = _guard;
    _bindGuardIdentity(guard);
    _syncGuardExpansion(guard);
    final content = _buildItem(context);
    final depth = widget.depth ?? 0;
    if (depth <= 0) return content;
    return ReplyThreadedIndentBox(
      depth: depth,
      colors: _threadLineColors(ColorScheme.of(context), depth),
      divColor: Theme.of(context).dividerColor.withValues(alpha: 0.15),
      onScrollLeft: widget.onScrollLeft,
      child: content,
    );
  }

  /// Per-level accent colours for the threaded indent lines.
  static List<Color> _threadLineColors(ColorScheme cs, int depth) =>
      List<Color>.generate(
        depth,
        (i) => i.isEven
            ? cs.outlineVariant.withValues(alpha: 0.55)
            : cs.primary.withValues(alpha: 0.35),
        growable: false,
      );

  Widget _buildHeader(BuildContext context, ColorScheme colorScheme) {
    final member = widget.replyItem.member;
    Widget header = GestureDetector(
      onTap: () {
        feedBack();
        Get.toNamed('/member?mid=${widget.replyItem.mid}');
      },
      child: TranslucentRow(
        spacing: 12,
        extraWidth: 46,
        children: [
          // 头像屏蔽只替换头像本身：正文、昵称与徽章保持原样，
          // 因为头像命中与正文命中是两条彼此独立的判定。
          if (_guardMasksAvatar(_guard))
            const ContentGuardAvatarMask()
          else
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
          Flexible(
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Row(
                  spacing: 6,
                  mainAxisSize: .min,
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
                        size: .small,
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                      ),
                  ],
                ),
                Row(
                  mainAxisSize: .min,
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
        // uncertain 保留正文（不隐瞒已收到的内容），但必须显式标注"未判定"，
        // 否则一次未完成的判定会读起来像一次通过。
        if (_guard?.isUncertain ?? false) ...[
          ContentGuardUncertainNotice(onRetry: widget.onContentGuardRetry),
          const SizedBox(height: 6),
        ],
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
              TextMore.rich(
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
                          size: .small,
                          isStack: false,
                          type: .line_primary,
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
        if (widget.replyItem.content.pictures.isNotEmpty ||
            _guard?.isMasked == true) ...[
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

  /// Comment pictures with the ContentGuard-masked ones removed.
  ///
  /// A decision names media by [MediaRef.stableKey] — `fp:<fingerprint>` once the
  /// image pipeline has hashed the picture, `id:<url>` before that — and never by
  /// position, so a mask cannot be resolved by comparing the key against a URL.
  /// The association is resolved here, in order of reliability:
  ///
  /// 1. this row's own picture/video references, recomputed from the current grid,
  ///    which is the exact spelling the decision layer used;
  /// 2. the reply's avatar reference, so an avatar mask never withdraws a picture;
  /// 3. the pHash cache of the picture URL, when the image pipeline has already
  ///    hashed it — that is the only way a fingerprinted key can name a picture
  ///    the row does not carry a fingerprint for.
  ///
  /// Nothing is planned here: a mask that resolves to nothing still yields the
  /// explicit placeholder below, because a silently missing picture is exactly the
  /// outcome the mask exists to prevent.
  List<Picture> _guardVisiblePictures(
    ReplyPresentation? guard,
    List<Picture> pictures,
  ) {
    if (guard == null || !guard.isMasked) return pictures;
    final masked = guard.maskedMediaIds;
    if (masked.isEmpty) return pictures;
    final avatarKeys = guardMediaKeysOfAvatar(
      widget.replyItem.member.face,
      authorUid: widget.replyItem.mid.toString(),
    );
    return pictures
        .where((item) {
          for (final key in guardMediaKeysOfContent(item.imgSrc)) {
            if (masked.contains(key) && !avatarKeys.contains(key)) return false;
          }
          for (final fingerprint
              in ImageBlockService.getCachedHashes(
                    item.imgSrc ?? '',
                  ) ??
                  const <String>[]) {
            if (masked.contains('fp:$fingerprint')) return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  /// Whether ContentGuard masked this row's avatar.
  ///
  /// Avatar masking has to hide the avatar and nothing else: the body of a reply
  /// is judged separately, so an avatar match must not turn the row into a body
  /// placeholder. [guardMediaKeysOfAvatar] answers for a key derived from either
  /// the avatar URL or the author uid, because a platform avatar carries no
  /// fingerprint the decision layer could have named.
  bool _guardMasksAvatar(ReplyPresentation? guard) {
    if (guard == null || !guard.isMasked) return false;
    final masked = guard.maskedMediaIds;
    if (masked.isEmpty) return false;
    for (final key in guardMediaKeysOfAvatar(
      widget.replyItem.member.face,
      authorUid: widget.replyItem.mid.toString(),
    )) {
      if (masked.contains(key)) return true;
    }
    final avatarUrl = widget.replyItem.member.face;
    for (final fingerprint
        in ImageBlockService.getCachedHashes(avatarUrl) ?? const <String>[]) {
      if (masked.contains('fp:$fingerprint')) return true;
    }
    return false;
  }

  Widget _buildCommentImages(BuildContext context, ColorScheme colorScheme) {
    final guard = _guard;
    // Only the media identities the decision names are dropped from the grid: a
    // rule that masks one role must not empty the row. A row with nothing left
    // shows a placeholder instead of an empty gap, so the layout does not collapse
    // and the masked picture is visibly withheld rather than silently missing.
    final pictures = _guardVisiblePictures(
      guard,
      widget.replyItem.content.pictures,
    );
    if (guard != null && guard.isMasked && pictures.isEmpty) {
      // Nothing left to draw: say which media was withheld rather than leaving an
      // empty gap, so a masked picture never reads as a comment that had none.
      final avatarOnly =
          widget.replyItem.content.pictures.isEmpty && _guardMasksAvatar(guard);
      return ContentGuardMediaMask(
        colorScheme: colorScheme,
        label: avatarOnly ? '头像已被内容过滤隐藏' : '图片已被内容过滤隐藏',
      );
    }
    final manualLoad = Pref.manualLoadCommentImage;
    if (!manualLoad || _loadManualImages) {
      return ImageGridView(
        key: ValueKey('img_$_blockImageVersion'),
        picArr: pictures
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
    final count = pictures.length;
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
              onPressed: widget.dialogueCallback == null
                  ? widget.showDialogue
                  : () => widget.dialogueCallback!(widget.replyItem),
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
              onPressed: widget.dialogueCallback == null
                  ? widget.jumpToDialogue
                  : () => widget.dialogueCallback!(widget.replyItem),
              style: buttonStyle,
              child: Text('跳转回复', style: textStyle),
            ),
          ),
        const Spacer(),
        if (widget.onTranslate != null &&
            Pref.enableCommentTranslate &&
            widget.replyItem.replyControl.translationSwitch ==
                .TRANSLATION_SWITCH_SHOW_TRANSLATION) ...[
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
                      // 传模型下标（按子回复对象重新定位），而不是 visibleReplies 的
                      // 渲染下标：横幅模式保留被屏蔽子回复，两者并不相同。
                      onDelete: () => widget.onDelete?.call(
                        widget.replyItem,
                        indexOfIdentity(widget.replyItem.replies, childReply),
                      ),
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
                              alignment: .middle,
                              child: PBadge(
                                text: 'UP',
                                size: .small,
                                isStack: false,
                                fontSize: 9,
                                textScaleFactor: 1,
                              ),
                            ),
                            const TextSpan(text: ' '),
                          ],
                          if (childReply.root == childReply.parent)
                            const TextSpan(text: ': ')
                          else if (childReply.mid != widget.upMid)
                            const TextSpan(text: ' '),
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
        late final topic = matchStr.substring1;
        if (content.emotes.containsKey(matchStr)) {
          // 处理表情
          final emote = content.emotes[matchStr]!;
          final size = emote.size.toInt() * 20.0;
          final url = emote.hasWebpUrl()
              ? emote.webpUrl
              : emote.hasGifUrl()
              ? emote.gifUrl
              : emote.url;
          spanChildren.add(
            WidgetSpan(
              child: emoteTooltipBuilder(
                url: url,
                emote: matchStr,
                triggerMode: .tap,
                jumpUrl: emote.hasJumpUrl() ? emote.jumpUrl : null,
                colorScheme: colorScheme,
                child: NetworkImgLayer(
                  src: url,
                  type: .emote,
                  width: size,
                  height: size,
                ),
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
          if (ownerMid == Int64.ZERO)
            ListTile(
              onTap: () {
                Get.back();
                Pref.setBlackMid(item.mid.toInt());
                onDelete();
                SmartDialog.showToast('屏蔽成功');
                return;
              },
              minLeadingWidth: 0,
              leading: Icon(Icons.error_outline, color: errorColor, size: 19),
              title: Text(
                '屏蔽',
                style: TextStyle(fontSize: 14, color: errorColor),
              ),
            )
          else
            ListTile(
              onTap: () {
                Get.back();

                final oid = item.oid;
                final rpid = item.id;
                final _reportProfile = RequestIdentityAdapter.fromAccount(
                  account: Accounts.reply,
                  userAgent: Accounts.reply.appRequestProfile.userAgent,
                ).profile;

                autoWrapReportDialog(
                  context,
                  onRemove: onDelete,
                  mid: () => item.mid.toInt(),
                  ReportOptions.commentReport,
                  withContent: ReportOptions.withContentReply,
                  contentRequired: ReportOptions.contentRequiredReply,
                  reportUrl:
                      'https://www.bilibili.com/h5/comment/report?oid=$oid&pageType=${item.type}&rpid=$rpid&platform=${_reportProfile.platform}&build=${_reportProfile.build}&${ThemeUtils.themeUrl(colorScheme.isDark)}',
                  oid: oid,
                  replyType: item.type.toInt(),
                  (reasonType, reasonDesc, banUid, deleteComment) async {
                    final res = await ReplyHttp.report(
                      rpid: rpid,
                      oid: oid,
                      reasonType: reasonType,
                      reasonDesc: reasonDesc,
                      banUid: banUid,
                      type: item.type.toInt(),
                      delete: deleteComment,
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
                      await ImageBlockService.addBlockedImage(
                        url,
                        flipEnabled: Pref.imageBlockFlipEnabled,
                        rotateEnabled: Pref.imageBlockRotateEnabled,
                      );
                    }
                  },
                  targetMid: item.member.mid.toInt(),
                  scene: 3,
                );
              },
              minLeadingWidth: 0,
              leading: Icon(Icons.error_outline, color: errorColor, size: 19),
              title: Text('举报', style: style.copyWith(color: errorColor)),
            ),
          if (ownerMid != Int64.ZERO || Accounts.blacklistIsLocal)
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
              final int type = item.type.toInt();
              final String url = switch (type) {
                1 =>
                  'https://www.bilibili.com/video/${IdUtils.av2bv(item.oid.toInt())}/#reply${item.id}',
                12 =>
                  'https://www.bilibili.com/read/cv${item.oid.toInt()}/#reply${item.id}',
                11 || 17 =>
                  'https://www.bilibili.com/opus/${item.oid.toInt()}/#reply${item.id}',
                _ => '${item.oid.toInt()}#reply${item.id}',
              };
              ShareUtils.shareText(url);
            },
            minLeadingWidth: 0,
            leading: const Icon(Icons.share_outlined, size: 19),
            title: Text('分享', style: style),
          ),
          ListTile(
            onTap: () {
              Get.back();
              showDialog(
                context: context,
                builder: (context) => Dialog(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
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
                  await ImageBlockService.addBlockedImage(
                    pictures.first.imgSrc,
                    flipEnabled: Pref.imageBlockFlipEnabled,
                    rotateEnabled: Pref.imageBlockRotateEnabled,
                  );
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
                                        for (
                                          int i = 0;
                                          i < pictures.length;
                                          i++
                                        ) {
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
                  await ImageBlockService.addBlockedImage(
                    pictures[i].imgSrc,
                    flipEnabled: Pref.imageBlockFlipEnabled,
                    rotateEnabled: Pref.imageBlockRotateEnabled,
                  );
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
