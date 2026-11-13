import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';

/// Supplies the like count one content object carries.
///
/// [GuardContent] has no like count on purpose: counters are surface data, not
/// content identity. A caller that holds the reply model passes a resolver that
/// reads its like counter; the default reseeder returns null, which the
/// operator reports honestly instead of guessing zero.
typedef MentionLikeCountResolver = int? Function(GuardContent content);

/// Stable reason codes emitted by [MentionQualityOperator].
abstract final class MentionQualityReasonCodes {
  /// Enough mentions and a short enough body: the @-spam shape.
  static const String matched = 'mention.spam_shape';

  /// The comment carries too few user mentions.
  static const String tooFewMentions = 'mention.too_few_mentions';

  /// Enough mentions, but the body is substantive.
  static const String bodySubstantive = 'mention.body_substantive';

  /// The comment is widely liked, so the like-exemption rule lets it through.
  static const String likeExempt = 'mention.like_exempt';

  /// The like-exemption rule is configured but the like count is unavailable,
  /// so the operator cannot decide whether the content is exempt.
  static const String likeCountUnavailable = 'mention.like_count_unavailable';

  /// The thresholds are configured so that no comment can ever match.
  static const String thresholdsUnavailable = 'mention.thresholds_unavailable';

  /// This content carries no text at all.
  static const String textUnavailable = 'mention.text_unavailable';
}

/// Configuration of a [MentionQualityOperator].
///
/// Rule JSON shape (the authoring contract):
///
///     {
///       "atCountThreshold": 5,
///       "bodyLengthThreshold": 10,
///       "likeExemptThreshold": 50
///     }
///
/// The key names and the default values mirror the settings the app already
/// ships (SettingBoxKey.atFilterAtCountThreshold / atFilterBodyLengthThreshold /
/// atFilterLikeExemptThreshold, rendered by the @-filter settings page), so a
/// rule authored here means exactly what the existing filter means instead of
/// introducing a second, differently calibrated notion of @-spam.
final class MentionQualityConfig {
  const MentionQualityConfig({
    this.atCountThreshold = defaultAtCountThreshold,
    this.bodyLengthThreshold = defaultBodyLengthThreshold,
    this.likeExemptThreshold = 0,
  });

  /// Reads the rule JSON map described on [MentionQualityConfig].
  ///
  /// A wrong-typed value falls back to its default instead of throwing.
  factory MentionQualityConfig.fromJson(Map<String, Object?> json) =>
      MentionQualityConfig(
        atCountThreshold: _readInt(
          json['atCountThreshold'],
          defaultAtCountThreshold,
        ),
        bodyLengthThreshold: _readInt(
          json['bodyLengthThreshold'],
          defaultBodyLengthThreshold,
        ),
        likeExemptThreshold: _readInt(json['likeExemptThreshold'], 0),
      );

  /// Default of Pref.atFilterAtCountThreshold.
  static const int defaultAtCountThreshold = 5;

  /// Default of Pref.atFilterBodyLengthThreshold.
  static const int defaultBodyLengthThreshold = 10;

  /// Default of Pref.atFilterLikeExemptThreshold, used only when the exemption
  /// is switched on. Pass 0 (the default here) to disable the exemption.
  static const int defaultLikeExemptThreshold = 50;

  /// Minimum number of distinct user mentions for this operator to consider a
  /// comment @-spam. Mapped from Pref.atFilterAtCountThreshold.
  final int atCountThreshold;

  /// Maximum effective body length, in runes, for a comment to be considered
  /// substantive-free. Mapped from Pref.atFilterBodyLengthThreshold.
  final int bodyLengthThreshold;

  /// Like count above which an exempt comment is allowed through. Mapped from
  /// Pref.atFilterLikeExemptThreshold.
  ///
  /// 0 or less disables the exemption, which is the shipped guard
  /// (likeExemptThreshold > 0) and keeps this operator usable without a like
  /// counter.
  final int likeExemptThreshold;
}

/// Judges the @-mention shape of a comment: many mentions, almost no body.
///
/// Pure local operator: no network, no inference, no storage, no side effects.
/// It reproduces the app's existing @-filter idea (lib/grpc/reply.dart
/// needRemoveAtGrpc) as a judge, so the same heuristic can feed rules instead of
/// living only in the comment pipeline.
///
/// ## Mention extraction rule
///
/// A mention is an at sign followed by 1-N handle runes, where a handle rune is
/// a letter, a digit, an underscore, a hyphen, or any CJK/kana/hangul ideograph
/// — the same substantive-character set the shipped extractor uses. The at sign
/// is not a mention when the previous rune is itself a word rune, which keeps
/// mail addresses out of the count (the at sign in a local part is preceded by
/// a letter). Distinct handles are counted, exactly like the shipped counter
/// counts distinct atNameToMid keys: one user mentioned five times is one
/// mention, not five.
///
/// ## Effective body
///
/// The body is the text with every matched mention removed, whitespace runs
/// collapsed to one space and then reduced to substantive runes only, so emoji,
/// punctuation and whitespace do not inflate a body. This is the same quantity
/// Pref.atFilterBodyLengthThreshold is compared against.
///
/// ## Decision order
///
/// 1. Too few mentions -> [FilterStatus.notMatched].
/// 2. The like-exemption rule is on and the like count exceeds its threshold ->
///    [FilterStatus.notMatched] with [MentionQualityReasonCodes.likeExempt].
/// 3. Enough mentions and the effective body is at or below the threshold ->
///    [FilterStatus.matched].
/// 4. Otherwise -> [FilterStatus.notMatched].
///
/// The like count is only consulted once the shape rule already matched, so a
/// missing counter never spoils a clean negative; when it is needed but
/// unavailable the verdict is [FilterStatus.unknown], never a pass.
final class MentionQualityOperator implements FilterOperator {
  /// Creates the operator with [config] already installed.
  ///
  /// [likeCountResolver] is what makes the like-exemption rule usable; without
  /// one, leave [MentionQualityConfig.likeExemptThreshold] at 0.
  MentionQualityOperator([
    MentionQualityConfig config = const MentionQualityConfig(),
    MentionLikeCountResolver likeCountResolver = _noLikeCount,
  ]) : _config = config,
       _likeCountResolver = likeCountResolver;

  /// Stable operator id; appears in rule JSON and cache keys.
  static const String operatorId = 'static.mention_quality';

  /// At sign followed by one or more handle runes.
  ///
  /// Deliberately not a regular-expression word boundary: a boundary treats
  /// every CJK ideograph as a word character, and the extractor would then miss
  /// mentions in exactly the language most comments are written in.
  static final RegExp _mentionPattern = RegExp(
    r'@[\w\-\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF]+',
  );

  static final RegExp _whitespace = RegExp(r'\s+');

  MentionQualityConfig _config;
  MentionLikeCountResolver _likeCountResolver;
  OperatorAvailability _availability = const OperatorAvailability(
    state: OperatorInitState.ready,
  );

  /// The configuration currently installed.
  MentionQualityConfig get config => _config;

  /// Installs [config] and, optionally, a new like-count source.
  ///
  /// Configuring is not a content side effect: it only changes what this judge
  /// measures, and it is idempotent.
  void configure(
    MentionQualityConfig config, {
    MentionLikeCountResolver? likeCountResolver,
  }) {
    _config = config;
    if (likeCountResolver != null) _likeCountResolver = likeCountResolver;
  }

  /// Distinct handles mentioned in [text], in first-appearance order.
  ///
  /// Public because rule authoring and the settings preview need exactly the
  /// count this operator decides on.
  static List<String> extractMentionHandles(String text) {
    final handles = <String>[];
    final seen = <String>{};
    for (final match in _mentionPattern.allMatches(text)) {
      final start = match.start;
      if (start > 0 && _isHandleRune(text.codeUnitAt(start - 1))) continue;
      final handle = match.group(0);
      if (handle == null || handle.length < 2) continue;
      if (seen.add(handle)) handles.add(handle);
    }
    return handles;
  }

  /// Effective body length of [text], in runes, as described on
  /// [MentionQualityOperator].
  static int effectiveBodyLength(String text) {
    final stripped = text.replaceAll(_mentionPattern, ' ');
    final normalized = stripped.replaceAll(_whitespace, ' ').trim();
    var length = 0;
    for (final rune in normalized.runes) {
      if (_isSubstantiveRune(rune)) length++;
    }
    return length;
  }

  @override
  String get id => operatorId;

  /// The @-filter idea is a comment heuristic; no other content type has a
  /// mention body to measure.
  @override
  Set<ContentType> get supportedContentTypes => const <ContentType>{
    ContentType.comment,
  };

  /// Mentions are text, never an attached media asset.
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
    ContentInput.text,
  };

  @override
  OperatorAvailability get availability => _availability;

  /// Re-asserts availability for this configuration.
  ///
  /// Nonsensical thresholds (a count below 1) make the operator undecidable
  /// rather than unavailable, and are reported per evaluation.
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
    final config = _config;
    if (config.atCountThreshold < 1 || config.bodyLengthThreshold < 0) {
      return _report(
        FilterStatus.unknown,
        MentionQualityReasonCodes.thresholdsUnavailable,
        'The configured thresholds cannot decide anything.',
      );
    }

    final text = content.text;
    if (text == null || text.isEmpty) {
      return _report(
        FilterStatus.unknown,
        MentionQualityReasonCodes.textUnavailable,
        'This content carries no text.',
      );
    }

    final handles = extractMentionHandles(text);
    final mentionCount = handles.length;
    if (mentionCount < config.atCountThreshold) {
      return _report(
        FilterStatus.notMatched,
        MentionQualityReasonCodes.tooFewMentions,
        'The comment mentions too few users.',
      );
    }

    final likeThreshold = config.likeExemptThreshold;
    if (likeThreshold > 0) {
      final likes = _likeCountResolver(content);
      if (likes != null && likes > likeThreshold) {
        return _report(
          FilterStatus.notMatched,
          MentionQualityReasonCodes.likeExempt,
          'The comment is liked enough to be exempt.',
        );
      }
      if (likes == null) {
        return _report(
          FilterStatus.unknown,
          MentionQualityReasonCodes.likeCountUnavailable,
          'The like count is unavailable, so the exemption cannot be applied.',
        );
      }
    }

    final bodyLength = effectiveBodyLength(text);
    if (bodyLength > config.bodyLengthThreshold) {
      return _report(
        FilterStatus.notMatched,
        MentionQualityReasonCodes.bodySubstantive,
        'The body is substantive, so the mentions are not spam-shaped.',
      );
    }

    return _report(
      FilterStatus.matched,
      MentionQualityReasonCodes.matched,
      'The comment is shaped like @-spam.',
      evidence: <FilterEvidence>[
        // The handles themselves are other users' identities; only the count
        // and the measured body length belong in persisted evidence.
        FilterEvidence(
          kind: EvidenceKind.text,
          field: 'text',
          redactedExcerpt: '@$mentionCount mentions',
        ),
        FilterEvidence(kind: EvidenceKind.metadata, field: 'body_length'),
      ],
      score: 1,
    );
  }

  static bool _isHandleRune(int rune) =>
      (rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A) ||
      rune == 0x5F ||
      rune == 0x2D ||
      (rune >= 0x3040 && rune <= 0x30FF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF) ||
      (rune >= 0xF900 && rune <= 0xFAFF);

  /// Whether [rune] counts as body content rather than decoration.
  ///
  /// Mirrors the substantive-rune predicate the shipped comment filter uses, so
  /// a body made of emoji or punctuation measures as empty in both places.
  static bool _isSubstantiveRune(int rune) {
    if (rune >= 0x30 && rune <= 0x39) return true;
    if (rune >= 0x41 && rune <= 0x5A) return true;
    if (rune >= 0x61 && rune <= 0x7A) return true;
    if (rune >= 0x00C0 && rune <= 0x02AF) return true;
    if (rune >= 0x0370 && rune <= 0x052F) return true;
    if (rune >= 0x0590 && rune <= 0x08FF) return true;
    if (rune >= 0x0900 && rune <= 0x0E7F) return true;
    if (rune >= 0x1100 && rune <= 0x11FF) return true;
    if (rune >= 0x3040 && rune <= 0x30FF) return true;
    if (rune >= 0x3100 && rune <= 0x318F) return true;
    if (rune >= 0x31A0 && rune <= 0x31BF) return true;
    if (rune >= 0x3400 && rune <= 0x4DBF) return true;
    if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    if (rune >= 0xAC00 && rune <= 0xD7AF) return true;
    if (rune >= 0xFF10 && rune <= 0xFF19) return true;
    if (rune >= 0xFF21 && rune <= 0xFF3A) return true;
    if (rune >= 0xFF41 && rune <= 0xFF5A) return true;
    return false;
  }

  static int? _noLikeCount(GuardContent content) => null;

  FilterResult _report(
    FilterStatus status,
    String reasonCode,
    String explanation, {
    List<FilterEvidence> evidence = const <FilterEvidence>[],
    double? score,
  }) => FilterResult(
    operatorId: id,
    status: status,
    reasonCode: reasonCode,
    explanation: explanation,
    evidence: evidence,
    score: score,
  );
}

int _readInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}
