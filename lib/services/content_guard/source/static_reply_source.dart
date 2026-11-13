import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';

/// Existing ReplyGrpc verdict categories, not a second implementation of filters.
enum StaticReplyReason {
  keyword('keyword', '关键词过滤'),
  goods('goods', '带货评论'),
  level('level', '用户等级不足'),
  mentionQuality('mention_quality', '低质量@评论'),
  blacklist('blacklist', '黑名单用户');

  const StaticReplyReason(this.code, this.safeLabel);
  final String code;
  final String safeLabel;
  String get reasonCode => 'static_reply.$code';
  String get operatorId => 'static.reply.$code';
  String get ruleId => 'static.reply.$code.collapse';
}

enum StaticReplyVerdict { clear, blocked, unknown, error }

/// Immutable facts captured from one actual request and one reply revision.
/// No body, URL, regex, raw reason detail or credentials are retained here.
final class StaticReplySnapshot {
  StaticReplySnapshot({
    required this.commentId,
    required this.authorUid,
    required this.contentVersion,
    required this.requestScopeId,
    required this.verdict,
    this.reason,
  }) {
    if ((int.tryParse(commentId) ?? 0) <= 0 ||
        (authorUid != null && (int.tryParse(authorUid!) ?? 0) <= 0) ||
        contentVersion.trim().isEmpty ||
        requestScopeId.trim().isEmpty ||
        (verdict == StaticReplyVerdict.blocked) != (reason != null)) {
      throw ArgumentError('Invalid static reply snapshot facts');
    }
  }

  /// Call ONLY after ReplyGrpc.checkBlockReason has completed successfully.
  /// A null legacy result is clean; missing snapshots remain unknown instead.
  /// Only the fixed reason prefix is mapped; dynamic details are discarded.
  factory StaticReplySnapshot.fromLegacyReason({
    required String commentId,
    required String? authorUid,
    required String contentVersion,
    required String requestScopeId,
    required String? legacyReason,
  }) {
    StaticReplyReason? reason;
    if (legacyReason != null) {
      for (final candidate in StaticReplyReason.values) {
        if (legacyReason == candidate.safeLabel ||
            legacyReason.startsWith('${candidate.safeLabel}：')) {
          reason = candidate;
          break;
        }
      }
    }
    return StaticReplySnapshot(
      commentId: commentId,
      authorUid: authorUid,
      contentVersion: contentVersion,
      requestScopeId: requestScopeId,
      verdict: legacyReason == null
          ? StaticReplyVerdict.clear
          : reason == null
          ? StaticReplyVerdict.unknown
          : StaticReplyVerdict.blocked,
      reason: reason,
    );
  }

  final String commentId;
  final String? authorUid;
  final String contentVersion;
  final String requestScopeId;
  final StaticReplyVerdict verdict;
  final StaticReplyReason? reason;
  String? get reasonCode => reason?.reasonCode;
  String? get safeReasonLabel => reason?.safeLabel;
}

typedef StaticReplySnapshotLookup = StaticReplySnapshot? Function(
  GuardContent content,
);

/// Attribution is independent from visibility. Every category is explicit.
/// Existing blacklist, preference, keyword and low-quality hits default false.
final class StaticReplyAttribution {
  const StaticReplyAttribution({
    this.keyword = false,
    this.goods = true,
    this.level = false,
    this.mentionQuality = false,
    this.blacklist = false,
  });

  final bool keyword;
  final bool goods;
  final bool level;
  final bool mentionQuality;
  final bool blacklist;

  bool counts(StaticReplyReason reason) => switch (reason) {
    StaticReplyReason.keyword => keyword,
    StaticReplyReason.goods => goods,
    StaticReplyReason.level => level,
    StaticReplyReason.mentionQuality => mentionQuality,
    StaticReplyReason.blacklist => blacklist,
  };
}

/// Configuration is immutable and passed to fresh operators per service.
/// Node.config is intentionally empty: service.operatorConfigPlan has no custom
/// adapter. Nonempty node config is rejected by the service, never ignored.
final class StaticReplySource {
  const StaticReplySource({
    required this.lookup,
    this.attribution = const StaticReplyAttribution(),
  });

  final StaticReplySnapshotLookup lookup;
  final StaticReplyAttribution attribution;

  List<FilterOperator> createOperators({bool Function()? isActive}) => [
    for (final reason in StaticReplyReason.values)
      _StaticReplyOperator(
        reason,
        lookup,
        attribution.counts(reason),
        isActive,
      ),
  ];

  /// The public countAsViolation path maps to RuleDefinition.attributeViolation.
  /// Rule IDs are stable so a caller can store and override each rule separately.
  List<RuleDefinition> createRules({
    Map<StaticReplyReason, bool> countAsViolation = const {},
  }) => List<RuleDefinition>.unmodifiable([
    for (final reason in StaticReplyReason.values)
      RuleDefinition(
        schemaVersion: 1,
        id: reason.ruleId,
        when: OperatorNode(operatorId: reason.operatorId),
        then: CollapseAction(reasonCode: reason.reasonCode),
        unknownAction: const ContinueAction(),
        errorAction: const ContinueAction(),
        attributeViolation:
            countAsViolation[reason] ?? attribution.counts(reason),
      ),
  ]);
}

final class _StaticReplyOperator implements FilterOperator {
  _StaticReplyOperator(
    this.reason,
    this.lookup,
    this.countAsViolation,
    this.isActive,
  );
  final StaticReplyReason reason;
  final StaticReplySnapshotLookup lookup;
  final bool countAsViolation;
  final bool Function()? isActive;

  @override
  String get id => reason.operatorId;
  @override
  Set<ContentType> get supportedContentTypes => const {ContentType.comment};
  @override
  Set<MediaType> get supportedMediaTypes => const {};
  @override
  Set<ContentInput> get requiredInputs => const {};
  @override
  bool get needsNetwork => false;
  @override
  bool get needsLocalInference => false;
  @override
  bool get batchable => false;
  @override
  OperatorAvailability availability = OperatorAvailability.uninitialized;

  @override
  Future<void> initialize(OperatorInitContext context) async {
    availability = OperatorAvailability(
      state: context.featureEnabled
          ? OperatorInitState.ready
          : OperatorInitState.disabled,
    );
  }

  FilterResult _result(FilterStatus status, String code) => FilterResult(
    operatorId: id,
    status: status,
    reasonCode: code,
    explanation: status == FilterStatus.matched ? reason.safeLabel : null,
    evidence: status == FilterStatus.matched
        ? [
            FilterEvidence(
              kind: EvidenceKind.metadata,
              field: reason.reasonCode,
            ),
          ]
        : const [],
    errorCode: status == FilterStatus.error ? code : null,
    attributeViolation: status == FilterStatus.matched && countAsViolation,
  );

  @override
  Future<FilterResult> evaluate(
    GuardContent content,
    OperatorRunContext context,
  ) async {
    if (isActive != null && !isActive!()) {
      return _result(FilterStatus.unknown, 'static_reply.owner_inactive');
    }
    if (content.surface != ContentSurface.rootComments ||
        content.contentType != ContentType.comment) {
      return _result(FilterStatus.unknown, 'static_reply.unsupported_surface');
    }
    try {
      final snapshot = lookup(content);
      if (snapshot == null) {
        return _result(FilterStatus.unknown, 'static_reply.missing_snapshot');
      }
      if (snapshot.commentId != content.contentId ||
          snapshot.authorUid != content.authorUid ||
          snapshot.contentVersion != content.contentVersion ||
          snapshot.requestScopeId != content.account.id ||
          context.account != content.account) {
        return _result(FilterStatus.error, 'static_reply.identity_mismatch');
      }
      return switch (snapshot.verdict) {
        StaticReplyVerdict.clear => _result(
          FilterStatus.notMatched,
          'static_reply.clear',
        ),
        StaticReplyVerdict.blocked =>
          snapshot.reason == reason
              ? _result(FilterStatus.matched, reason.reasonCode)
              : _result(FilterStatus.notMatched, 'static_reply.other_reason'),
        StaticReplyVerdict.unknown => _result(
          FilterStatus.unknown,
          'static_reply.unknown',
        ),
        StaticReplyVerdict.error => _result(
          FilterStatus.error,
          'static_reply.error',
        ),
      };
    } on Object {
      return _result(FilterStatus.error, 'static_reply.snapshot_error');
    }
  }

  @override
  Future<List<FilterResult>> evaluateBatch(
    List<GuardContent> contents,
    OperatorRunContext context,
  ) => Future.wait(contents.map((content) => evaluate(content, context)));
}
