import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';

/// Supplies the metadata facts one content object carries.
///
/// The resolver exists because [GuardContent] is deliberately a small value
/// carrier: it has no like count, no duration and no author level, and this
/// operator must not widen core to get them. A caller that already holds those
/// numbers (a reply model, a video detail model) passes a resolver that adds
/// them; [derivedMetadata] is the default and needs nothing but core.
typedef MetadataResolver = Map<String, Object?> Function(GuardContent content);

/// The metadata facts [MetadataOperator] can derive from [GuardContent] alone.
///
/// Keys produced here (all present unless noted):
///
/// | key            | type          | meaning                                    |
/// |----------------|---------------|--------------------------------------------|
/// | text_length    | int           | rune count of text, 0 when absent          |
/// | title_length   | int           | rune count of title, 0 when absent         |
/// | tag_count      | int           | number of tags                             |
/// | media_count    | int           | number of attached media references        |
/// | has_parent     | bool          | whether the content is a nested reply      |
/// | content_type   | String        | [ContentType] wire name                    |
/// | surface        | String        | [ContentSurface] wire name                 |
/// | tags           | List<String>  | the tag list itself                        |
/// | reply_type     | int or absent | platform reply discriminator, when known   |
///
/// Platform numbers a rule usually wants — like_count, duration, level — are
/// **not** derivable here and are absent unless the caller supplies a resolver
/// that adds them under those exact keys.
Map<String, Object?> derivedMetadata(GuardContent content) {
  final metadata = <String, Object?>{
    'text_length': content.text?.runes.length ?? 0,
    'title_length': content.title?.runes.length ?? 0,
    'tag_count': content.tags.length,
    'media_count': content.media.length,
    'has_parent': (content.parentId ?? '').isNotEmpty,
    'content_type': content.contentType.wireName,
    'surface': content.surface.wireName,
    'tags': content.tags,
  };
  final replyType = content.context.replyType;
  if (replyType != null) metadata['reply_type'] = replyType;
  return metadata;
}

/// Stable reason codes emitted by [MetadataOperator].
abstract final class MetadataReasonCodes {
  /// Every (or, in any-mode, at least one) predicate was satisfied.
  static const String matched = 'metadata.matched';

  /// The predicates were all evaluable and none/not all were satisfied.
  static const String notMatched = 'metadata.not_matched';

  /// At least one predicate named a field the resolver does not supply.
  static const String fieldUnavailable = 'metadata.field_unavailable';

  /// A comparison was applied to values it cannot order.
  static const String typeMismatch = 'metadata.type_mismatch';

  /// The rule carries no predicate, so there is nothing to compare.
  static const String noPredicates = 'metadata.no_predicates';
}

/// Stable error codes emitted by [MetadataOperator].
abstract final class MetadataErrorCodes {
  /// A predicate names a comparison operator this operator does not implement.
  static const String unknownComparison = 'metadata.unknown_comparison';

  /// A predicate is missing one of its required keys.
  static const String malformedPredicate = 'metadata.malformed_predicate';
}

/// Comparison operators a [MetadataPredicate] may use. Machine values.
abstract final class MetadataComparisons {
  /// Equal (numeric values compare by value, so 1 equals 1.0).
  static const String equals = 'eq';

  /// Not equal.
  static const String notEquals = 'ne';

  /// Numerically greater.
  static const String greaterThan = 'gt';

  /// Numerically greater or equal.
  static const String greaterOrEqual = 'gte';

  /// Numerically less.
  static const String lessThan = 'lt';

  /// Numerically less or equal.
  static const String lessOrEqual = 'lte';

  /// The resolved value is one of the expected list entries.
  static const String oneOf = 'in';

  /// The resolved value is none of the expected list entries.
  static const String noneOf = 'not_in';

  /// The resolved collection (or string) contains the expected value.
  static const String contains = 'has';

  /// The field is present (true) or absent (false).
  static const String exists = 'exists';

  /// Every comparison name this operator implements.
  static const Set<String> all = <String>{
    equals,
    notEquals,
    greaterThan,
    greaterOrEqual,
    lessThan,
    lessOrEqual,
    oneOf,
    noneOf,
    contains,
    exists,
  };
}

/// One comparison against one metadata field.
///
/// Rule JSON shape (the authoring contract):
///
///     {"field": "like_count", "op": "gte", "value": 1000}
///     {"field": "duration", "op": "lt", "value": 15}
///     {"field": "tags", "op": "has", "value": "\u5e7f\u544a"}
final class MetadataPredicate {
  const MetadataPredicate({
    required this.field,
    required this.op,
    this.value,
  });

  /// Reads one predicate map. Missing keys become empty strings so the
  /// evaluation reports a malformed predicate instead of hiding it.
  factory MetadataPredicate.fromJson(Map<String, Object?> json) =>
      MetadataPredicate(
        field: json['field'] is String ? json['field'] as String : '',
        op: json['op'] is String ? json['op'] as String : '',
        value: json['value'],
      );

  /// Metadata key to read, for example like_count.
  final String field;

  /// One of [MetadataComparisons].
  final String op;

  /// Expected value. A num for the ordering comparisons, a list for in /
  /// not_in, anything for eq / ne / has, a bool for exists.
  final Object? value;
}

/// Configuration of a [MetadataOperator].
///
/// Rule JSON shape (the authoring contract):
///
///     {
///       "predicates": [
///         {"field": "like_count", "op": "gte", "value": 1000},
///         {"field": "has_parent", "op": "eq", "value": false}
///       ],
///       "combine": "all",
///       "attributeViolation": false
///     }
///
/// combine is all (default) or any. A wrong-typed value falls back to its
/// default instead of throwing.
final class MetadataOperatorConfig {
  const MetadataOperatorConfig({
    this.predicates = const <MetadataPredicate>[],
    this.combine = combineAll,
    this.attributeViolation = false,
  });

  /// Reads the rule JSON map described on [MetadataOperatorConfig].
  factory MetadataOperatorConfig.fromJson(Map<String, Object?> json) {
    final predicates = <MetadataPredicate>[];
    final raw = json['predicates'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          predicates.add(
            MetadataPredicate.fromJson(<String, Object?>{
              for (final entry in item.entries)
                entry.key.toString(): entry.value,
            }),
          );
        }
      }
    }
    return MetadataOperatorConfig(
      predicates: predicates,
      combine: json['combine'] == combineAny ? combineAny : combineAll,
      attributeViolation: json['attributeViolation'] == true,
    );
  }

  /// Every predicate must hold (default).
  static const String combineAll = 'all';

  /// At least one predicate must hold.
  static const String combineAny = 'any';

  /// Predicates evaluated in order.
  final List<MetadataPredicate> predicates;

  /// [combineAll] or [combineAny].
  final String combine;

  /// Whether a positive verdict may be attributed to the author. Off by
  /// default: metadata alone rarely proves an author did something wrong.
  final bool attributeViolation;
}

/// Judges content by numeric, boolean and membership predicates over metadata.
///
/// Pure local operator: no network, no inference, no storage, no side effects.
/// This is the generic comparison operator a rule AST CompareNode delegates to;
/// [evaluatePredicate] is the reusable single-comparison entry point for a
/// compiler that wants to fold comparisons itself.
///
/// ## Three-valued logic, not booleans
///
/// A predicate can be satisfied, refuted, or not evaluable (the field is
/// missing, or the values cannot be ordered). Those map onto
/// [FilterStatus.matched], [FilterStatus.notMatched] and [FilterStatus.unknown],
/// and combine like this:
///
/// * all — a refuted predicate decides notMatched immediately; otherwise any
///   unevaluable predicate leaves the verdict unknown; only all-satisfied
///   yields matched.
/// * any — a satisfied predicate decides matched immediately; otherwise any
///   unevaluable predicate leaves the verdict unknown; only all-refuted yields
///   notMatched.
///
/// So an unknown metadata field can never be folded into a pass.
final class MetadataOperator implements FilterOperator {
  /// Creates the operator with [config] already installed.
  ///
  /// [resolver] defaults to [derivedMetadata]. Pass a resolver that adds
  /// like_count, duration, level and the like when the caller holds them.
  MetadataOperator([
    MetadataOperatorConfig config = const MetadataOperatorConfig(),
    MetadataResolver resolver = derivedMetadata,
  ]) : _config = config,
       _resolver = resolver;

  /// Stable operator id; appears in rule JSON and cache keys.
  static const String operatorId = 'static.metadata';

  MetadataOperatorConfig _config;
  MetadataResolver _resolver;
  OperatorAvailability _availability = const OperatorAvailability(
    state: OperatorInitState.ready,
  );

  /// The configuration currently installed.
  MetadataOperatorConfig get config => _config;

  /// The metadata source currently installed.
  MetadataResolver get resolver => _resolver;

  /// Installs [config] and, optionally, a new metadata source.
  ///
  /// Configuring is not a content side effect: it only changes what this judge
  /// compares, and it is idempotent.
  void configure(MetadataOperatorConfig config, {MetadataResolver? resolver}) {
    _config = config;
    if (resolver != null) _resolver = resolver;
  }

  @override
  String get id => operatorId;

  @override
  Set<ContentType> get supportedContentTypes => const <ContentType>{
    ContentType.video,
    ContentType.comment,
    ContentType.article,
    ContentType.dynamic,
    ContentType.searchResult,
  };

  /// Metadata is not media: no attached media reference is required.
  @override
  Set<MediaType> get supportedMediaTypes => const <MediaType>{};

  @override
  bool get needsNetwork => false;

  @override
  bool get needsLocalInference => false;

  @override
  bool get batchable => false;

  @override
  Set<ContentInput> get requiredInputs => const <ContentInput>{
    ContentInput.metadata,
  };

  @override
  OperatorAvailability get availability => _availability;

  /// Re-asserts availability for this configuration.
  ///
  /// A rule without predicates is not an unavailable operator: it is a broken
  /// rule and is reported per evaluation as [FilterStatus.unknown].
  @override
  Future<void> initialize(OperatorInitContext context) async {
    _availability = context.featureEnabled
        ? const OperatorAvailability(state: OperatorInitState.ready)
        : const OperatorAvailability(
            state: OperatorInitState.disabled,
            reasonCode: 'availability.disabled_by_feature_switch',
            message: 'ContentGuard master switch is off.',
          );
  }

  @override
  Future<FilterResult> evaluate(
    GuardContent content,
    OperatorRunContext context,
  ) async => _judge(content);

  @override
  Future<List<FilterResult>> evaluateBatch(
    List<GuardContent> contents,
    OperatorRunContext context,
  ) async => <FilterResult>[for (final item in contents) _judge(item)];

  /// Evaluates one comparison against an already resolved metadata map.
  ///
  /// Exposed so a rule compiler can fold a CompareNode without building a
  /// [GuardContent]; the semantics are exactly the ones [evaluate] uses.
  static FilterStatus evaluatePredicate(
    MetadataPredicate predicate,
    Map<String, Object?> metadata,
  ) => _compare(predicate, metadata).status;

  FilterResult _judge(GuardContent content) {
    final predicates = _config.predicates;
    if (predicates.isEmpty) {
      return _report(
        FilterStatus.unknown,
        MetadataReasonCodes.noPredicates,
        'The rule configures no metadata predicate.',
      );
    }

    final Map<String, Object?> metadata;
    try {
      metadata = _resolver(content);
    } catch (_) {
      return _report(
        FilterStatus.error,
        MetadataReasonCodes.fieldUnavailable,
        'The metadata source failed.',
        errorCode: MetadataErrorCodes.malformedPredicate,
      );
    }

    final isAny = _config.combine == MetadataOperatorConfig.combineAny;
    final satisfied = <MetadataPredicate>[];
    var refuted = 0;
    var unresolved = 0;
    String? unresolvedReason;

    for (final predicate in predicates) {
      final outcome = _compare(predicate, metadata);
      switch (outcome.status) {
        case FilterStatus.matched:
          satisfied.add(predicate);
          if (isAny) break;
        case FilterStatus.notMatched:
          refuted++;
          if (!isAny) break;
        case FilterStatus.error:
          return _report(
            FilterStatus.error,
            outcome.reasonCode,
            outcome.explanation,
            errorCode: outcome.errorCode,
          );
        case FilterStatus.unknown:
          unresolved++;
          unresolvedReason ??= outcome.reasonCode;
      }
    }

    final decided = isAny ? satisfied.isNotEmpty : refuted > 0;
    if (isAny && decided) {
      return _report(
        FilterStatus.matched,
        MetadataReasonCodes.matched,
        'At least one metadata predicate holds.',
        evidence: _evidenceOf(satisfied),
        attributeViolation: _config.attributeViolation,
      );
    }
    if (!isAny && refuted > 0) {
      return _report(
        FilterStatus.notMatched,
        MetadataReasonCodes.notMatched,
        'A metadata predicate does not hold.',
      );
    }
    if (unresolved > 0) {
      return _report(
        FilterStatus.unknown,
        unresolvedReason ?? MetadataReasonCodes.fieldUnavailable,
        'A metadata predicate could not be evaluated.',
      );
    }
    if (isAny) {
      return _report(
        FilterStatus.notMatched,
        MetadataReasonCodes.notMatched,
        'No metadata predicate holds.',
      );
    }
    return _report(
      FilterStatus.matched,
      MetadataReasonCodes.matched,
      'Every metadata predicate holds.',
      evidence: _evidenceOf(satisfied),
      attributeViolation: _config.attributeViolation,
    );
  }

  static List<FilterEvidence> _evidenceOf(List<MetadataPredicate> matched) =>
      <FilterEvidence>[
        for (final predicate in matched)
          FilterEvidence(kind: EvidenceKind.metadata, field: predicate.field),
      ];

  static _ComparisonOutcome _compare(
    MetadataPredicate predicate,
    Map<String, Object?> metadata,
  ) {
    final field = predicate.field;
    final op = predicate.op;
    if (field.isEmpty || op.isEmpty) {
      return const _ComparisonOutcome(
        FilterStatus.error,
        MetadataReasonCodes.noPredicates,
        'The predicate is missing its field or its comparison.',
        MetadataErrorCodes.malformedPredicate,
      );
    }
    if (!MetadataComparisons.all.contains(op)) {
      return _ComparisonOutcome(
        FilterStatus.error,
        MetadataReasonCodes.noPredicates,
        'Unknown comparison "$op".',
        MetadataErrorCodes.unknownComparison,
      );
    }

    final present = metadata.containsKey(field);
    final actual = metadata[field];

    if (op == MetadataComparisons.exists) {
      final expected = predicate.value;
      if (expected is! bool) {
        return const _ComparisonOutcome(
          FilterStatus.error,
          MetadataReasonCodes.typeMismatch,
          'exists needs a boolean value.',
          MetadataErrorCodes.malformedPredicate,
        );
      }
      return _ComparisonOutcome(
        present == expected ? FilterStatus.matched : FilterStatus.notMatched,
        present == expected
            ? MetadataReasonCodes.matched
            : MetadataReasonCodes.notMatched,
        present == expected
            ? 'The field presence matches.'
            : 'The field presence does not match.',
      );
    }

    if (!present) {
      return _ComparisonOutcome(
        FilterStatus.unknown,
        MetadataReasonCodes.fieldUnavailable,
        'The metadata field "$field" is not available.',
      );
    }

    switch (op) {
      case MetadataComparisons.equals:
        return _boolean(actual == predicate.value, 'Equality holds.');
      case MetadataComparisons.notEquals:
        return _boolean(actual != predicate.value, 'Equality does not hold.');
      case MetadataComparisons.contains:
        final container = actual;
        if (container is Iterable<Object?>) {
          final hasValue = container.contains(predicate.value);
          return _boolean(hasValue, 'Membership evaluated.');
        }
        if (container is String && predicate.value is String) {
          final hasValue = container.contains(predicate.value as String);
          return _boolean(hasValue, 'Substring membership evaluated.');
        }
        return _ComparisonOutcome(
          FilterStatus.unknown,
          MetadataReasonCodes.typeMismatch,
          'The metadata field "$field" is not a collection.',
        );
      case MetadataComparisons.oneOf:
      case MetadataComparisons.noneOf:
        final expected = predicate.value;
        if (expected is! Iterable<Object?>) {
          return _ComparisonOutcome(
            FilterStatus.unknown,
            MetadataReasonCodes.typeMismatch,
            'The comparison against "$field" needs a list value.',
          );
        }
        final isMember = expected.contains(actual);
        return _boolean(
          op == MetadataComparisons.oneOf ? isMember : !isMember,
          'List membership evaluated.',
        );
      default:
        final left = _asNum(actual);
        final right = _asNum(predicate.value);
        if (left == null || right == null) {
          return _ComparisonOutcome(
            FilterStatus.unknown,
            MetadataReasonCodes.typeMismatch,
            'The metadata field "$field" is not comparable.',
          );
        }
        final bool holds = switch (op) {
          MetadataComparisons.greaterThan => left > right,
          MetadataComparisons.greaterOrEqual => left >= right,
          MetadataComparisons.lessThan => left < right,
          MetadataComparisons.lessOrEqual => left <= right,
          _ => false,
        };
        return _boolean(holds, 'Numeric comparison evaluated.');
    }
  }

  static _ComparisonOutcome _boolean(bool holds, String explanation) =>
      _ComparisonOutcome(
        holds ? FilterStatus.matched : FilterStatus.notMatched,
        holds ? MetadataReasonCodes.matched : MetadataReasonCodes.notMatched,
        explanation,
      );

  static num? _asNum(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  FilterResult _report(
    FilterStatus status,
    String reasonCode,
    String explanation, {
    List<FilterEvidence> evidence = const <FilterEvidence>[],
    String? errorCode,
    bool attributeViolation = false,
  }) => FilterResult(
    operatorId: id,
    status: status,
    reasonCode: reasonCode,
    explanation: explanation,
    evidence: evidence,
    errorCode: errorCode,
    attributeViolation: attributeViolation,
  );
}

final class _ComparisonOutcome {
  const _ComparisonOutcome(
    this.status,
    this.reasonCode,
    this.explanation, [
    this.errorCode,
  ]);

  final FilterStatus status;
  final String reasonCode;
  final String explanation;
  final String? errorCode;
}
