/// ContentGuard core contracts.
///
/// Pure Dart: value types and interfaces only. No Flutter UI, no widgets, no
/// `BuildContext`, no storage access — anything that needs those belongs to a
/// later work package that consumes this barrel.
library;

export 'package:PiliPlus/services/content_guard/model/account_scope.dart';
export 'package:PiliPlus/services/content_guard/model/content_context.dart';
export 'package:PiliPlus/services/content_guard/model/content_types.dart';
export 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
export 'package:PiliPlus/services/content_guard/model/filter_result.dart';
export 'package:PiliPlus/services/content_guard/model/guard_content.dart';
export 'package:PiliPlus/services/content_guard/model/media_ref.dart';
export 'package:PiliPlus/services/content_guard/model/operator_status.dart';
export 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';
export 'package:PiliPlus/services/content_guard/operator/operator_registry.dart';

// ------------------------------------------------ added: WP-2 static judges
// Pure local FilterOperators (keyword, regex, author blocklist, mention shape,
// metadata comparison). They need no network, no inference and no storage, so
// re-exporting them keeps the barrel free of the storage layer as intended.
export 'package:PiliPlus/services/content_guard/operator/static/static_operators.dart';

// ---------------------------------------------------------------------------
// Added by WP-3: the policy layer (rule data, strict schema, migration, engine).
// ---------------------------------------------------------------------------
export 'package:PiliPlus/services/content_guard/policy/policy.dart';

// ---------------------------------------------------------------------------
// Added by WP-7: the assembled vertical slice.
//
// Only the two assembly-facing entry points are re-exported. The slice imports
// the decision / presenter / violation / suggestion / storage layers to wire
// them together, and re-exporting those here would widen this barrel past the
// "pure core contracts" it is documented as — importing the service is a
// deliberate act, not a side effect of importing the core.
// ---------------------------------------------------------------------------
export 'package:PiliPlus/services/content_guard/content_guard_service.dart'
    show
        CapabilityReasonCodes,
        ConfigDiagnosticReasonCodes,
        ContentGuardBootstrap,
        ContentGuardService,
        OperatorCapability,
        OperatorConfigDiagnostic;
export 'package:PiliPlus/services/content_guard/slice/content_guard_pipeline.dart'
    show ContentGuardPipeline, PipelineResult, RegistryOperatorResolver;
