/// The input a policy pass evaluates against.
///
/// A request bundles the [GuardContent] with the [OperatorRunContext] the
/// operators will receive, so the engine never has to synthesise a run context
/// (and so a caller cannot accidentally evaluate against a different account or
/// list generation than it dispatched with). Both parts are the same objects the
/// decision cache and the write-back guard use, which is what keeps a policy
/// verdict attributable to one account, one rule version and one list revision
/// (plan-core sections 8.1, 9).
library;

import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';

/// Content plus the run context a policy pass is executed under.
final class PolicyRequest {
  const PolicyRequest({required this.content, required this.runContext});

  final GuardContent content;

  /// Account, rule version and generation every operator dispatched by this pass
  /// receives. A stale pass is expected to be discarded by the caller through
  /// [OperatorRunContext.generation], not by the engine.
  final OperatorRunContext runContext;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PolicyRequest &&
          content == other.content &&
          runContext == other.runContext;

  @override
  int get hashCode => Object.hash(content, runContext);

  @override
  String toString() => 'PolicyRequest($content, $runContext)';
}
