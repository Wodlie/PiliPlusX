import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';

/// Stable reason codes emitted by [AuthorBlocklistOperator].
abstract final class AuthorBlocklistReasonCodes {
  /// The content author is on the configured blocklist.
  static const String blocked = 'author.blocked';

  /// The author uid was available and is not on the blocklist.
  static const String notBlocked = 'author.not_blocked';

  /// The configured blocklist is empty, so nothing can be judged.
  static const String noBlockedUids = 'author.no_blocked_uids';

  /// The content carries no author uid, so the operator cannot judge it.
  static const String uidUnavailable = 'author.uid_unavailable';
}

/// Configuration of an [AuthorBlocklistOperator].
///
/// Rule JSON shape (the authoring contract):
///
///     {
///       "uids": ["208259", "354637831"],
///       "attributeViolation": false
///     }
///
/// Both keys are optional. Entries are trimmed, blanks are dropped and
/// duplicates collapse; a wrong-typed value falls back to its default instead
/// of throwing.
final class AuthorBlocklistConfig {
  const AuthorBlocklistConfig({
    this.uids = const <String>[],
    this.attributeViolation = false,
  });

  /// Reads the rule JSON map described on [AuthorBlocklistConfig].
  factory AuthorBlocklistConfig.fromJson(Map<String, Object?> json) =>
      AuthorBlocklistConfig(
        uids: <String>[
          for (final item in _readList(json['uids']))
            if (item is String) item,
        ],
        attributeViolation: json['attributeViolation'] == true,
      );

  /// Author uids considered blocked. Compared verbatim (uid strings are opaque
  /// platform identifiers, not numbers: no padding or case folding is applied).
  final List<String> uids;

  /// Whether a positive hit may be attributed to the author and feed the
  /// violation ledger.
  ///
  /// Off by default. This is the one static operator where an author
  /// blocklist hit *can* be an author property rather than a content property,
  /// but enabling it stays a rule author's explicit decision: the default
  /// verdict must never accuse an account on its own.
  final bool attributeViolation;
}

/// Judges content by the identity of its author.
///
/// Pure local operator: no network, no inference, no storage, no side effects.
/// It answers "is this the account the user blocked", never "is this content
/// bad": everything else about the content is irrelevant here.
///
/// ## The three-way outcome
///
/// * Author uid known and listed -> [FilterStatus.matched].
/// * Author uid known and not listed -> [FilterStatus.notMatched].
/// * Author uid missing, empty or blank -> [FilterStatus.unknown]. A content
///   whose author the caller could not extract is *not* evidence of a clean
///   author, and reporting [FilterStatus.notMatched] would let a broken adapter
///   silently allow every account the user blocked.
///
/// The same distinction applies to an empty blocklist: nothing can be judged, so
/// the verdict is [FilterStatus.unknown] rather than a pass.
final class AuthorBlocklistOperator implements FilterOperator {
  /// Creates the operator with [config] already installed.
  AuthorBlocklistOperator([
    AuthorBlocklistConfig config = const AuthorBlocklistConfig(),
  ]) : _config = config {
    _uids = _normalizeUids(config.uids);
  }

  /// Stable operator id; appears in rule JSON and cache keys.
  static const String operatorId = 'static.author_blocklist';

  AuthorBlocklistConfig _config;
  Set<String> _uids = const <String>{};
  OperatorAvailability _availability = const OperatorAvailability(
    state: OperatorInitState.ready,
  );

  /// The configuration currently installed.
  AuthorBlocklistConfig get config => _config;

  /// Number of distinct uids currently blocked.
  int get blockedUidCount => _uids.length;

  /// Installs [config]. Configuring is not a content side effect: it only
  /// changes which authors this judge recognises, and it is idempotent.
  void configure(AuthorBlocklistConfig config) {
    _config = config;
    _uids = _normalizeUids(config.uids);
  }

  /// Adds [uid] to the blocklist of the running operator.
  ///
  /// Returns whether the set changed. It mutates only this operator's own
  /// configuration; it never blocks anything, anywhere.
  bool addBlockedUid(String uid) {
    final normalized = uid.trim();
    if (normalized.isEmpty || _uids.contains(normalized)) return false;
    _uids = Set<String>.unmodifiable(<String>{..._uids, normalized});
    return true;
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

  /// Author identity is metadata, never an attached media asset.
  @override
  Set<MediaType> get supportedMediaTypes => const <MediaType>{};

  @override
  bool get needsNetwork => false;

  @override
  bool get needsLocalInference => false;

  @override
  bool get batchable => false;

  /// An author decision is impossible without an author uid.
  ///
  /// The registry therefore does not dispatch this operator for content whose
  /// author is unknown; a direct [evaluate] call still answers
  /// [FilterStatus.unknown] instead of guessing.
  @override
  Set<ContentInput> get requiredInputs => const <ContentInput>{
    ContentInput.authorUid,
  };

  @override
  OperatorAvailability get availability => _availability;

  /// Re-asserts availability for this configuration.
  ///
  /// An empty blocklist is not unavailable: the operator is ready, it simply has
  /// nothing to judge and says so per evaluation.
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

  FilterResult _judge(GuardContent content) {
    if (_uids.isEmpty) {
      return _report(
        FilterStatus.unknown,
        AuthorBlocklistReasonCodes.noBlockedUids,
        'The rule configures no blocked author uid.',
      );
    }

    final rawUid = content.authorUid;
    final uid = rawUid?.trim();
    if (uid == null || uid.isEmpty) {
      return _report(
        FilterStatus.unknown,
        AuthorBlocklistReasonCodes.uidUnavailable,
        'This content carries no author uid.',
      );
    }

    if (!_uids.contains(uid)) {
      return _report(
        FilterStatus.notMatched,
        AuthorBlocklistReasonCodes.notBlocked,
        'The author is not on the blocklist.',
      );
    }

    return _report(
      FilterStatus.matched,
      AuthorBlocklistReasonCodes.blocked,
      'The author is on the blocklist.',
      evidence: <FilterEvidence>[
        FilterEvidence(
          kind: EvidenceKind.author,
          field: 'authorUid',
          // The blocked uid is already rule configuration, not harvested user
          // text, so echoing it in evidence leaks nothing new and makes the
          // verdict explainable.
          redactedExcerpt: uid,
        ),
      ],
      score: 1,
      attributeViolation: _config.attributeViolation,
    );
  }

  static Set<String> _normalizeUids(List<String> uids) {
    final normalized = <String>{};
    for (final raw in uids) {
      final uid = raw.trim();
      if (uid.isNotEmpty) normalized.add(uid);
    }
    return Set<String>.unmodifiable(normalized);
  }

  FilterResult _report(
    FilterStatus status,
    String reasonCode,
    String explanation, {
    List<FilterEvidence> evidence = const <FilterEvidence>[],
    double? score,
    bool attributeViolation = false,
  }) => FilterResult(
    operatorId: id,
    status: status,
    reasonCode: reasonCode,
    explanation: explanation,
    evidence: evidence,
    score: score,
    attributeViolation: attributeViolation,
  );
}

List<Object?> _readList(Object? value) =>
    value is List ? List<Object?>.of(value) : const <Object?>[];
