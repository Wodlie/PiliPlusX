import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';

/// The one contract every ContentGuard operator implements.
///
/// An operator is a *judge*. It reports a [FilterResult] and nothing else: it
/// never collapses, hides, masks, blocks, reports or deletes content, never
/// writes storage and never decides author attribution. Merging verdicts is the
/// decision composer's job (plan-core §1, §2.2, §12).
///
/// Implementations must be side-effect free with respect to the content graph
/// and must respect [OperatorRunContext.generation] when they return late.
abstract interface class FilterOperator {
  /// Stable machine id. Must be constant for the lifetime of the operator and
  /// unique within a registry; it appears in rule JSON and cache keys.
  String get id;

  /// Content categories this operator can judge. An empty set means "no
  /// content type is supported" and the registry will never dispatch it.
  Set<ContentType> get supportedContentTypes;

  /// Media roles this operator consumes.
  ///
  /// An empty set means the operator needs no media at all. A non-empty set
  /// means it requires at least one attached [MediaRef] of one of these roles;
  /// the registry enforces that before dispatch.
  Set<MediaType> get supportedMediaTypes;

  /// Whether evaluation may perform network I/O. Static operators declare
  /// `false` so a scheduler can run them without connectivity.
  bool get needsNetwork;

  /// Whether evaluation needs a local inference runtime. When the build has no
  /// such runtime the operator must report
  /// [OperatorInitState.unavailable] instead of pretending to be ready.
  bool get needsLocalInference;

  /// Whether [evaluateBatch] is meaningfully cheaper than repeated [evaluate].
  bool get batchable;

  /// Inputs this operator reads. A content object that cannot supply one of
  /// these is never dispatched here (see [GuardContent.provides]).
  Set<ContentInput> get requiredInputs;

  /// Current lifecycle state of the operator.
  ///
  /// Evaluated live, not snapshotted at registration: an operator that loses
  /// its model may become [OperatorInitState.unavailable] at any time, and the
  /// UI must be able to show that instead of silently seeing no matches.
  OperatorAvailability get availability;

  /// Prepares the operator. Must be idempotent and must not throw: a failure
  /// is reported by moving [availability] to [OperatorInitState.failed] with a
  /// stable `reasonCode`.
  Future<void> initialize(OperatorInitContext context);

  /// Judges one content object. Must never throw; failures are reported as
  /// [FilterStatus.error] (or [FilterStatus.unknown] when the operator simply
  /// cannot decide).
  Future<FilterResult> evaluate(
    GuardContent content,
    OperatorRunContext context,
  );

  /// Judges several content objects.
  ///
  /// The returned list must be positional: element `i` is the verdict for
  /// `contents[i]`. Implementations that cannot batch should map [evaluate]
  /// over the input; they must still return one verdict per input.
  Future<List<FilterResult>> evaluateBatch(
    List<GuardContent> contents,
    OperatorRunContext context,
  );
}
