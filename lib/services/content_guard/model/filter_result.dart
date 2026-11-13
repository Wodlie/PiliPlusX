import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';

/// Outcome of one operator evaluating one piece of content.
///
/// The four values are deliberately distinct and must not collapse:
///
/// * [matched]    — the operator positively identified the condition.
/// * [notMatched] — the operator positively evaluated and found nothing.
/// * [unknown]    — capability missing, input insufficient, or the model could
///                  not decide. **Not** a pass.
/// * [error]      — execution, parsing or timeout failure. **Not** a pass.
///
/// Only [notMatched] may be cached as a negative result. Caching [unknown] or
/// [error] as [notMatched] would turn a broken operator into a silent allow
/// (plan-core §2.3, §8.2).
enum FilterStatus { matched, notMatched, unknown, error }

/// The single verdict shape every operator returns. Operators never collapse,
/// hide, block, report or delete content themselves — they only judge
/// (plan-core §12).
final class FilterResult {
  const FilterResult({
    required this.operatorId,
    required this.status,
    required this.reasonCode,
    required this.explanation,
    required this.evidence,
    this.score,
    this.errorCode,
    this.retryable = false,
    this.attributeViolation = false,
  });

  /// The operator that produced this verdict; must equal `FilterOperator.id`.
  final String operatorId;

  final FilterStatus status;

  /// Stable machine value used by rules, cache keys and the UI. Never
  /// localised and never parsed out of [explanation].
  final String reasonCode;

  /// Human-facing text. Display only.
  final String? explanation;

  /// Redacted support for the verdict. Empty for a clean [notMatched].
  final List<FilterEvidence> evidence;

  /// Operator-owned confidence/score. **Not** a probability by default: it has
  /// no shared scale across operators (plan-core §2.2, semantic operators).
  final double? score;

  /// Stable failure classifier, required when [status] is [FilterStatus.error].
  final String? errorCode;

  /// Whether re-running the same evaluation could plausibly succeed
  /// (timeout, transient transport failure) as opposed to a deterministic
  /// failure (unparsable response, missing capability).
  final bool retryable;

  /// Whether this verdict may be attributed to the author and feed the
  /// violation ledger. Defaults to **false**: a QR/avatar/media match is never
  /// an author violation on its own (plan-core §6.2).
  final bool attributeViolation;

  /// Whether this verdict represents a positive identification.
  bool get isMatch => status == FilterStatus.matched;

  /// Whether this verdict is safe to cache as a negative.
  bool get isNegative => status == FilterStatus.notMatched;

  /// Whether the outcome is unresolved and therefore never a pass.
  bool get isUnresolved =>
      status == FilterStatus.unknown || status == FilterStatus.error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FilterResult &&
          operatorId == other.operatorId &&
          status == other.status &&
          reasonCode == other.reasonCode &&
          explanation == other.explanation &&
          score == other.score &&
          errorCode == other.errorCode &&
          retryable == other.retryable &&
          attributeViolation == other.attributeViolation &&
          _listEquals(evidence, other.evidence);

  @override
  int get hashCode => Object.hash(
    operatorId,
    status,
    reasonCode,
    explanation,
    score,
    errorCode,
    retryable,
    attributeViolation,
    Object.hashAll(evidence),
  );

  @override
  String toString() =>
      'FilterResult($operatorId: ${status.name}, reason: $reasonCode, '
      'score: $score, error: $errorCode, retryable: $retryable, '
      'attributeViolation: $attributeViolation)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
