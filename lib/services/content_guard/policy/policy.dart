/// ContentGuard policy layer: rule data, strict parsing, and the engine.
///
/// Pure Dart. A rule is inert JSON — parsed here, never executed — so importing
/// this barrel gives a consumer the whole rule vocabulary, the strict codec, the
/// migration chain, the evaluator and the engine, and nothing that can reach the
/// transport, storage or the UI.
library;

export 'package:PiliPlus/services/content_guard/policy/policy_engine.dart';
export 'package:PiliPlus/services/content_guard/policy/policy_evaluator.dart';
export 'package:PiliPlus/services/content_guard/policy/policy_request.dart';
export 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';
export 'package:PiliPlus/services/content_guard/policy/rule_migration.dart';
export 'package:PiliPlus/services/content_guard/policy/rule_schema.dart';
