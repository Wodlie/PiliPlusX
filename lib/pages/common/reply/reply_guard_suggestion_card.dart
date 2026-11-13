/// Suggestion card for one author-level blacklist proposal.
///
/// Rendered at the row the anchor names, never at every row: one author with one
/// candidate gets one card, and the anchor decides which slot shows it.
///
/// The copy states the observed count, the window and what accepting does, so a
/// user cannot mistake a local blacklist entry for a platform action.
library;

import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_anchor.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class GuardSuggestionCard extends StatelessWidget {
  const GuardSuggestionCard({
    super.key,
    required this.anchor,
    required this.suggestion,
    this.isBusy = false,
    this.onAccept,
    this.onReject,
  });

  final SuggestionAnchor anchor;
  final BlacklistSuggestion suggestion;

  /// A decision is in flight: both actions are disabled so a double click
  /// cannot write twice.
  final bool isBusy;

  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    final enabled = !isBusy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(45, 6, 6, 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.onInverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.block, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '该用户在最近 ${suggestion.windowDays} 天内已有 '
                    '${suggestion.violationCount} 条违规评论',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '接受后仅在本机屏蔽该作者，不会在 B 站拉黑。',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: enabled ? onReject : null,
                  child: const Text('不再建议'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  onPressed: enabled ? onAccept : null,
                  child: const Text('本地屏蔽'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One comment row plus the suggestion card that belongs underneath it.
///
/// ## Why the card is a slot below a row, not a list item
///
/// The card belongs to a **row**, not to the list: the spec renders it under the
/// first comment of each contiguous run. Making it an extra list item would shift
/// every index after it — the vote card, the fold entry, the footer, and the
/// [ReplyGuardProjection] slot every row is looked up by. Appending it inside the
/// row keeps `itemCount` and all of that arithmetic untouched.
///
/// ## Why the null case returns the child itself
///
/// Wrapping unconditionally would put a zero-height Column in front of every
/// comment in the list. Returning `child` unchanged means a list with the guard
/// off, or with no renderable suggestion, builds exactly the tree it built before
/// the guard existed.
class GuardSuggestionSlot extends StatelessWidget {
  const GuardSuggestionSlot({
    super.key,
    required this.child,
    required this.anchor,
    required this.suggestion,
    this.isBusy = false,
    this.onAccept,
    this.onReject,
  });

  final Widget child;

  /// Anchor the card acts on, or null when no card renders at this row.
  final SuggestionAnchor? anchor;

  /// Suggestion to render, or null when none does.
  final BlacklistSuggestion? suggestion;

  final bool isBusy;
  final void Function(SuggestionAnchor anchor)? onAccept;
  final void Function(SuggestionAnchor anchor)? onReject;

  @override
  Widget build(BuildContext context) {
    final resolvedAnchor = anchor;
    final resolvedSuggestion = suggestion;
    if (resolvedAnchor == null || resolvedSuggestion == null) return child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        GuardSuggestionCard(
          anchor: resolvedAnchor,
          suggestion: resolvedSuggestion,
          isBusy: isBusy,
          onAccept: onAccept == null ? null : () => onAccept!(resolvedAnchor),
          onReject: onReject == null ? null : () => onReject!(resolvedAnchor),
        ),
      ],
    );
  }
}
