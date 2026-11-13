import 'package:PiliPlus/services/content_guard/model/account_scope.dart';

/// Lifecycle state of one operator.
///
/// [ready] is the only state in which the scheduler may dispatch work to the
/// operator. [unavailable] and [disabled] are legitimate, reportable outcomes —
/// they exist so a build without local inference can say "this capability is
/// not here" instead of silently dropping the operator (plan-core §2.2, §10).
enum OperatorInitState {
  uninitialized,
  initializing,
  ready,
  unavailable,
  disabled,
  failed,
}

/// Initialisation status plus the machine-readable reason for it.
final class OperatorAvailability {
  const OperatorAvailability({
    required this.state,
    this.reasonCode,
    this.message,
  });

  /// The "not initialised yet" value every operator starts from.
  static const OperatorAvailability uninitialized = OperatorAvailability(
    state: OperatorInitState.uninitialized,
  );

  final OperatorInitState state;

  /// Stable machine value (for example `capability.missing_local_inference`).
  /// Never localised and never derived from [message].
  final String? reasonCode;

  /// Human-facing explanation. Display only; no decision may branch on it.
  final String? message;

  /// Whether dispatch is allowed.
  bool get isReady => state == OperatorInitState.ready;

  /// Whether this state must be surfaced to the user as missing capability
  /// rather than treated as a normal "no match".
  bool get isUnavailable =>
      state == OperatorInitState.unavailable ||
      state == OperatorInitState.disabled ||
      state == OperatorInitState.failed;

  /// Whether an initialisation attempt has settled (in either direction).
  bool get isSettled =>
      state != OperatorInitState.uninitialized &&
      state != OperatorInitState.initializing;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OperatorAvailability &&
          state == other.state &&
          reasonCode == other.reasonCode &&
          message == other.message;

  @override
  int get hashCode => Object.hash(state, reasonCode, message);

  @override
  String toString() =>
      'OperatorAvailability(${state.name}, reason: $reasonCode)';
}

/// Inputs an operator receives when it is initialised.
///
/// Deliberately small: it carries the build variant and the master feature
/// switch, and nothing that could authenticate a request. An operator must
/// never load credentials from here — it has no access to them at all.
final class OperatorInitContext {
  const OperatorInitContext({
    required this.buildVariant,
    required this.featureEnabled,
    this.settingsRevision,
  });

  /// Build variant the operator is running in (`standard`, `with_ai`, ...).
  final String buildVariant;

  /// Master switch. When false the operator must become [OperatorInitState.disabled]
  /// and must not create local inference or network work.
  final bool featureEnabled;

  /// Opaque revision of the operator settings the current rules were built
  /// from. Changing it invalidates cached results.
  final String? settingsRevision;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OperatorInitContext &&
          buildVariant == other.buildVariant &&
          featureEnabled == other.featureEnabled &&
          settingsRevision == other.settingsRevision;

  @override
  int get hashCode =>
      Object.hash(buildVariant, featureEnabled, settingsRevision);

  @override
  String toString() =>
      'OperatorInitContext(variant: $buildVariant, enabled: $featureEnabled, '
      'settings: $settingsRevision)';
}

/// Per-run context handed to every evaluation.
///
/// [generation] is the write-back guard: a result computed for an older
/// generation must be discarded by the caller even if it arrives late, so
/// completion order never becomes list order (plan-core §9).
final class OperatorRunContext {
  const OperatorRunContext({
    required this.account,
    required this.ruleVersion,
    required this.generation,
    this.cancellation,
  });

  final AccountScope account;

  /// Version of the rule set the run is evaluated against; part of every
  /// decision cache key.
  final String ruleVersion;

  /// List revision this run belongs to.
  final int generation;

  /// Opaque cancellation signal. Interpretation belongs to the operator
  /// implementation; core treats it as an untyped token.
  final Object? cancellation;

  /// Whether [cancellation] reports an abort.
  bool get isCancelled => switch (cancellation) {
    null => false,
    final AbortSignal signal => signal.isCancelled,
    final bool flag => flag,
    _ => false,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OperatorRunContext &&
          account == other.account &&
          ruleVersion == other.ruleVersion &&
          generation == other.generation &&
          identical(cancellation, other.cancellation);

  @override
  int get hashCode => Object.hash(
    account,
    ruleVersion,
    generation,
    identityHashCode(cancellation),
  );

  @override
  String toString() =>
      'OperatorRunContext($account, rules: $ruleVersion, generation: $generation)';
}

/// Minimal cooperative cancellation token for operator work.
///
/// A structural type on purpose: any subtype (a Future-based token, a UI-scoped
/// flag) is accepted through [OperatorRunContext.cancellation] without core
/// depending on it.
abstract interface class AbortSignal {
  bool get isCancelled;
}
