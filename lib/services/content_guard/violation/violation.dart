/// ContentGuard violation accounting and blacklist suggestion (WP-4).
///
/// Pure Dart: no Flutter, no `BuildContext`, no widget or page imports, no
/// bindings. Persistence goes through the existing `KeyValueStore` /
/// `JsonRepository` layer only, so importing this barrel pulls in no Hive box,
/// no transport and no inference runtime.
///
/// Three concerns live here, and they stay apart on purpose:
///
/// * **Accounting** — [ViolationLedger] counts *distinct attributable comments per
///   author*. It is idempotent by key, refuses an attribution without a platform
///   author uid, and never counts a filter hit that was not attributed.
/// * **Evidence without counting** — [AvatarEvidenceIndex] records a recurring
///   avatar once and can never raise a count.
/// * **Suggestion** — [SuggestionAnchoring] decides *where* a card may render (the
///   first node of each consecutive run), [BlacklistSuggestionMachine] decides
///   *whether* it may render, and one author-level state is shared by every anchor
///   so accept/reject broadcasts.
library;

export 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion.dart';
export 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion_machine.dart';
export 'package:PiliPlus/services/content_guard/suggestion/suggestion_anchor.dart';
export 'package:PiliPlus/services/content_guard/suggestion/suggestion_policy.dart';
export 'package:PiliPlus/services/content_guard/violation/avatar_evidence_index.dart';
export 'package:PiliPlus/services/content_guard/violation/violation_ledger.dart';
export 'package:PiliPlus/services/content_guard/violation/violation_record.dart';
export 'package:PiliPlus/services/content_guard/violation/violation_repository.dart';
