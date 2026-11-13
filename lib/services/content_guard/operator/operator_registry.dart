import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';

/// The single registry of operators known to this ContentGuard instance.
///
/// Two behaviours are contractual:
///
/// 1. **Lookup is exact.** [find] returns `null` for an unknown id; nothing is
///    ever substituted, so a rule referencing an unknown operator is a visible
///    validation failure rather than a silent allow.
/// 2. **Unavailability is reported, not omitted.** [availableFor] returns only
///    dispatchable operators, and everything registered-but-not-dispatchable is
///    returned by [unavailableFor] / [availabilitySnapshot] so the UI can say
///    which capability is missing (plan-core §2.2, §10, §12).
final class OperatorRegistry {
  /// Registration order is preserved, so a bootstrap that registers cheap
  /// static operators first also gets a cheap-first dispatch order.
  final Map<String, FilterOperator> _operators = <String, FilterOperator>{};

  /// Registered operators in registration order.
  List<FilterOperator> get operators =>
      List<FilterOperator>.unmodifiable(_operators.values);

  int get length => _operators.length;

  bool get isEmpty => _operators.isEmpty;

  bool get isNotEmpty => _operators.isNotEmpty;

  /// Whether an operator with [id] is registered.
  bool contains(String id) => _operators.containsKey(id);

  /// Adds [operator].
  ///
  /// Throws [ArgumentError] when [FilterOperator.id] is blank or already
  /// registered. A silent replacement would let two different implementations
  /// answer to one rule id depending on bootstrap order.
  void register(FilterOperator operator) {
    final id = operator.id;
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'operator.id', 'must not be empty');
    }
    if (_operators.containsKey(id)) {
      throw ArgumentError.value(id, 'operator.id', 'already registered');
    }
    _operators[id] = operator;
  }

  /// Adds [operator], replacing any registered operator with the same id.
  ///
  /// Returns the replaced operator, or `null` when [operator] was new. Use it
  /// for hot-reload style rewiring; ordinary bootstrap must use [register].
  FilterOperator? replace(FilterOperator operator) {
    if (operator.id.isEmpty) {
      throw ArgumentError.value(
        operator.id,
        'operator.id',
        'must not be empty',
      );
    }
    final previous = _operators[operator.id];
    _operators[operator.id] = operator;
    return previous;
  }

  /// Removes the operator with [id]; returns whether one was removed.
  bool unregister(String id) => _operators.remove(id) != null;

  /// The operator registered under [id], or `null` when there is none.
  FilterOperator? find(String id) => _operators[id];

  /// Operators that may be dispatched for [content], in registration order.
  ///
  /// Dispatchable means, in this order: the operator is
  /// [OperatorAvailability.isReady], it supports [GuardContent.contentType],
  /// every declared [FilterOperator.requiredInputs] entry is provided by the
  /// content, and — when it declares media roles — at least one attached media
  /// reference has one of those roles.
  List<FilterOperator> availableFor(GuardContent content) => [
    for (final operator in _operators.values)
      if (_isDispatchable(operator, content)) operator,
  ];

  /// Operators that declare support for [content] but cannot be dispatched
  /// right now, in registration order.
  ///
  /// This is the "report, don't omit" half of the contract: an operator whose
  /// model failed to load is returned here with
  /// [OperatorAvailability.isUnavailable] set, never dropped from the registry.
  List<FilterOperator> unavailableFor(GuardContent content) => [
    for (final operator in _operators.values)
      if (_declaresSupport(operator, content) &&
          !_isDispatchable(operator, content))
        operator,
  ];

  /// All registered operators whose availability state is [state].
  List<FilterOperator> byState(OperatorInitState state) => [
    for (final operator in _operators.values)
      if (operator.availability.state == state) operator,
  ];

  /// Every operator that is not currently dispatchable, in registration order.
  ///
  /// Returned regardless of content, for capability banners and settings pages.
  List<FilterOperator> get unavailableOperators => [
    for (final operator in _operators.values)
      if (!operator.availability.isReady) operator,
  ];

  /// Snapshot of `operatorId -> availability` for every registered operator.
  Map<String, OperatorAvailability> availabilitySnapshot() => {
    for (final operator in _operators.values)
      operator.id: operator.availability,
  };

  /// Initialises every registered operator once.
  ///
  /// [FilterOperator.initialize] is contractually non-throwing and idempotent,
  /// so a failing operator is reported through its availability instead of
  /// aborting the whole bootstrap.
  Future<void> initializeAll(OperatorInitContext context) async {
    for (final operator in _operators.values) {
      await operator.initialize(context);
    }
  }

  bool _declaresSupport(FilterOperator operator, GuardContent content) =>
      operator.supportedContentTypes.contains(content.contentType);

  bool _isDispatchable(FilterOperator operator, GuardContent content) {
    if (!operator.availability.isReady) return false;
    if (!_declaresSupport(operator, content)) return false;
    for (final input in operator.requiredInputs) {
      if (!content.provides(input)) return false;
    }
    final mediaTypes = operator.supportedMediaTypes;
    if (mediaTypes.isEmpty) return true;
    for (final media in content.media) {
      if (mediaTypes.contains(media.type)) return true;
    }
    return false;
  }
}
