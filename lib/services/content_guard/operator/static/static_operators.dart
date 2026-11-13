/// ContentGuard static operator barrel.
///
/// Every operator here is a **pure local judge**: it needs no network, no local
/// inference and no storage, and it never acts on content. It reports a
/// FilterResult and nothing else, so a rule engine can run the whole set on the
/// UI isolate, offline, in a deterministic order.
///
/// This barrel deliberately does not export the storage layer or
/// content_guard.dart: importing it must not pull in Hive, Dio or the app.
library;

export 'package:PiliPlus/services/content_guard/operator/static/author_blocklist_operator.dart';
export 'package:PiliPlus/services/content_guard/operator/static/keyword_operator.dart';
export 'package:PiliPlus/services/content_guard/operator/static/mention_quality_operator.dart';
export 'package:PiliPlus/services/content_guard/operator/static/metadata_operator.dart';
export 'package:PiliPlus/services/content_guard/operator/static/regex_operator.dart';
