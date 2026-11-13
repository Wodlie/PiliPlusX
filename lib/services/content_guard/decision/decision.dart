/// ContentGuard decision layer: precedence, composition and cache identity.
///
/// Pure Dart. Importing this barrel gives a consumer the precedence ladder, the
/// composer contract and its default implementation, and the cache key/state
/// vocabulary — and nothing that can reach the transport, storage, the account
/// state or the UI.
library;

export 'package:PiliPlus/services/content_guard/decision/decision_cache_key.dart';
export 'package:PiliPlus/services/content_guard/decision/decision_composer.dart';
export 'package:PiliPlus/services/content_guard/decision/decision_precedence.dart';
