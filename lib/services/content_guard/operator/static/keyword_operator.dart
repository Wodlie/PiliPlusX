import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';

/// Stable reason codes emitted by [KeywordOperator].
///
/// These are machine values: they appear in rule JSON, cache keys and the
/// violation ledger. Never localise them and never reword them.
abstract final class KeywordReasonCodes {
  /// A configured keyword was found in one of the configured fields.
  static const String matched = 'keyword.matched';

  /// The rule carries no usable keyword, so nothing can be judged.
  static const String noKeywords = 'keyword.no_keywords';

  /// The rule targets fields this content does not carry.
  static const String noTargetField = 'keyword.no_target_field';

  /// Every configured field was available and no keyword was found.
  static const String noMatch = 'keyword.no_match';
}

/// Configuration of a [KeywordOperator].
///
/// Rule JSON shape (the authoring contract):
///
///     {
///       "keywords": ["spam", "\u5e7f\u544a"],
///       "matchWholeWord": true,
///       "caseSensitive": false,
///       "targets": ["text", "title", "tags"]
///     }
///
/// Every key is optional. A wrong-typed value falls back to its default instead
/// of throwing, because one malformed rule must not abort a whole ruleset load;
/// the operator then reports what it can actually decide (see
/// [KeywordReasonCodes.noKeywords]).
final class KeywordOperatorConfig {
  const KeywordOperatorConfig({
    this.keywords = const <String>[],
    this.matchWholeWord = false,
    this.caseSensitive = false,
    this.targets = defaultTargets,
  });

  /// Reads the rule JSON map described on [KeywordOperatorConfig].
  ///
  /// Unknown keys are ignored. A target naming a field this operator cannot
  /// read is dropped; when no usable target remains the defaults apply.
  factory KeywordOperatorConfig.fromJson(Map<String, Object?> json) {
    final targets = <ContentInput>[];
    for (final name in _readStringList(json['targets'])) {
      final input = enumByWireName(ContentInput.values, name);
      if (input != null && supportedTargets.contains(input)) {
        targets.add(input);
      }
    }
    return KeywordOperatorConfig(
      keywords: _readStringList(json['keywords']),
      matchWholeWord: json['matchWholeWord'] == true,
      caseSensitive: json['caseSensitive'] == true,
      targets: targets.isEmpty ? defaultTargets : targets,
    );
  }

  /// Fields searched when a rule does not name its own targets.
  static const List<ContentInput> defaultTargets = <ContentInput>[
    ContentInput.text,
    ContentInput.title,
    ContentInput.tags,
  ];

  /// Fields this operator is able to read at all.
  ///
  /// Anything else is silently dropped by [KeywordOperatorConfig.fromJson]:
  /// keyword matching over media or metadata would be a different operator.
  static const Set<ContentInput> supportedTargets = <ContentInput>{
    ContentInput.text,
    ContentInput.title,
    ContentInput.tags,
  };

  /// Raw keywords, in rule order. Blanks and duplicates are ignored when the
  /// operator evaluates, not here, so the configured list stays inspectable.
  final List<String> keywords;

  /// Whether an occurrence must be bounded by word boundaries on both sides.
  ///
  /// A word boundary is decided from the script of the keyword edge: Latin
  /// letters, digits and underscore join a Latin edge, while CJK/kana/hangul
  /// ideographs do not (those scripts have no inter-word spaces). A CJK keyword
  /// therefore degrades to substring matching under whole-word mode; applying a
  /// boundary rule there is exactly what breaks CJK search.
  final bool matchWholeWord;

  /// Whether the comparison keeps ASCII case. Matching never uses a locale.
  final bool caseSensitive;

  /// Fields searched, in evidence order.
  final List<ContentInput> targets;
}

/// Judges content by searching configured keywords in text, title and tags.
///
/// Pure local operator: no network, no inference, no storage, no side effects.
/// It only reports what it found; hiding, blocking or reporting the content is
/// the decision composer's job.
///
/// ## Matching contract
///
/// * ASCII case is folded with [String.toLowerCase] unless
///   [KeywordOperatorConfig.caseSensitive] is set. No locale is applied, so the
///   result does not depend on the device language.
/// * Substring mode is a plain [String.contains] and therefore works for CJK
///   exactly like for Latin text.
/// * Whole-word mode brackets each occurrence with a boundary test instead of
///   a regular expression. A plain word boundary cannot be used: Dart treats
///   every CJK ideograph as a word character, so it would report "cat" inside
///   "\u770b\u770b\u8fd9\u4e2acat\u5f88\u53ef\u7231" as a non-word (wrong for Chinese prose)
///   and "\u5e7f\u544a" inside "\u514d\u8d39\u5e7f\u544a!" as a non-word (wrong for the
///   keyword itself).
///
///   The boundary is therefore decided by the *edge rune of the keyword*: a
///   Latin, digit or underscore edge is continued only by another Latin-class
///   rune, and a CJK/kana/hangul edge only by another CJK-class rune. So a
///   Latin keyword embedded in Chinese prose counts as a whole word, while a
///   CJK keyword embedded in a longer ideograph run does not.
final class KeywordOperator implements FilterOperator {
  /// Creates the operator with [config] already installed.
  KeywordOperator([
    KeywordOperatorConfig config = const KeywordOperatorConfig(),
  ]) : _config = config {
    _prepare(config);
  }

  /// Stable operator id; appears in rule JSON and cache keys.
  static const String operatorId = 'static.keyword';

  KeywordOperatorConfig _config;
  List<String> _needles = const <String>[];
  OperatorAvailability _availability = const OperatorAvailability(
    state: OperatorInitState.ready,
  );

  /// The configuration currently installed.
  KeywordOperatorConfig get config => _config;

  /// Installs [config]. Configuring is not a content side effect: it only
  /// changes what this judge looks for, and it is idempotent.
  void configure(KeywordOperatorConfig config) {
    _config = config;
    _prepare(config);
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

  /// Keyword matching reads no media, so no media role is required.
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
  /// Keyword matching has no asynchronous prerequisite, so the operator is
  /// ready as soon as it exists; initialisation only honours the master switch.
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
    if (_config.targets.isEmpty) {
      return _report(
        FilterStatus.unknown,
        KeywordReasonCodes.noTargetField,
        'The rule configures no searchable field.',
      );
    }
    if (_needles.isEmpty) {
      return _report(
        FilterStatus.notMatched,
        KeywordReasonCodes.noKeywords,
        'The rule configures no keyword.',
      );
    }

    final hits = <String>[];
    final hitFields = <String>[];
    var sawField = false;
    for (final target in config.targets) {
      final values = _valuesOf(content, target);
      if (values.isEmpty) continue;
      sawField = true;
      for (final value in values) {
        for (final needle in _needles) {
          if (hits.contains(needle)) continue;
          if (!_contains(value, needle, config)) continue;
          hits.add(needle);
          hitFields.add(_fieldName(target));
        }
      }
    }

    if (hits.isEmpty) {
      if (!sawField) {
        return _report(
          FilterStatus.unknown,
          KeywordReasonCodes.noTargetField,
          'This content carries none of the configured fields.',
        );
      }
      return _report(
        FilterStatus.notMatched,
        KeywordReasonCodes.noMatch,
        'No configured keyword was found.',
      );
    }

    final hitCount = hits.length;
    final needleCount = _needles.length;
    return _report(
      FilterStatus.matched,
      KeywordReasonCodes.matched,
      'Matched $hitCount of $needleCount keyword(s).',
      evidence: <FilterEvidence>[
        for (var i = 0; i < hits.length; i++)
          FilterEvidence(
            kind: EvidenceKind.text,
            field: hitFields[i],
            // The configured keyword, never the user text: evidence is
            // persisted with the violation record and must not carry content.
            redactedExcerpt: hits[i],
          ),
      ],
      score: hits.length / _needles.length,
    );
  }

  void _prepare(KeywordOperatorConfig config) {
    final needles = <String>[];
    final seen = <String>{};
    for (final raw in config.keywords) {
      final keyword = raw.trim();
      if (keyword.isEmpty) continue;
      final key = config.caseSensitive ? keyword : keyword.toLowerCase();
      if (!seen.add(key)) continue;
      needles.add(keyword);
    }
    _needles = List<String>.unmodifiable(needles);
  }

  static List<String> _valuesOf(GuardContent content, ContentInput target) {
    switch (target) {
      case ContentInput.text:
        final text = content.text;
        return text == null || text.isEmpty ? const <String>[] : <String>[text];
      case ContentInput.title:
        final title = content.title;
        return title == null || title.isEmpty
            ? const <String>[]
            : <String>[title];
      case ContentInput.tags:
        return content.tags;
      default:
        return const <String>[];
    }
  }

  static String _fieldName(ContentInput target) => switch (target) {
    ContentInput.text => 'text',
    ContentInput.title => 'title',
    ContentInput.tags => 'tags',
    _ => 'unknown',
  };

  static bool _contains(
    String haystack,
    String needle,
    KeywordOperatorConfig config,
  ) {
    final field = config.caseSensitive ? haystack : haystack.toLowerCase();
    final probe = config.caseSensitive ? needle : needle.toLowerCase();
    if (probe.isEmpty) return false;
    if (!config.matchWholeWord) return field.contains(probe);
    // The classes that continue a word are decided per edge of the keyword, so
    // a Latin keyword inside Chinese prose still counts as a whole word.
    final startCjk = _isCjkRune(probe.codeUnitAt(0));
    final endCjk = _isCjkRune(probe.codeUnitAt(probe.length - 1));
    var from = 0;
    while (true) {
      final index = field.indexOf(probe, from);
      if (index < 0) return false;
      final startOk =
          index == 0 || !_continuesWord(field.codeUnitAt(index - 1), startCjk);
      final end = index + probe.length;
      final endOk =
          end >= field.length || !_continuesWord(field.codeUnitAt(end), endCjk);
      if (startOk && endOk) return true;
      // Overlapping occurrences matter: "aa" is a whole word inside "aaa b".
      from = index + 1;
    }
  }

  /// Whether [rune] continues a word whose edge belongs to class [cjk].
  ///
  /// A CJK edge never continues: a script without inter-word spaces has no word
  /// boundary to test, so whole-word mode degrades to substring matching for a
  /// CJK keyword instead of adopting a boundary rule that would never hold. An
  /// ideograph next to a Latin word *is* a boundary, which is what lets a Latin
  /// keyword quoted inside Chinese prose match.
  static bool _continuesWord(int rune, bool cjk) {
    if (cjk) return false;
    return _isWordRune(rune);
  }

  /// Whether [rune] is a CJK/kana/hangul ideograph or fullwidth form.
  ///
  /// These scripts do not separate words with spaces, so a run of them is one
  /// unbroken word and only a different class ends it.
  static bool _isCjkRune(int rune) {
    if (rune >= 0x1100 && rune <= 0x11FF) return true; // hangul jamo
    if (rune >= 0x3040 && rune <= 0x30FF) return true; // kana
    if (rune >= 0x3100 && rune <= 0x318F) return true; // bopomofo
    if (rune >= 0x3400 && rune <= 0x4DBF) return true; // cjk ext a
    if (rune >= 0x4E00 && rune <= 0x9FFF) return true; // cjk
    if (rune >= 0xAC00 && rune <= 0xD7AF) return true; // hangul syllables
    if (rune >= 0xF900 && rune <= 0xFAFF) return true; // cjk compat
    if (rune >= 0xFF10 && rune <= 0xFF19) return true; // fullwidth 0-9
    if (rune >= 0xFF21 && rune <= 0xFF3A) return true; // fullwidth A-Z
    if (rune >= 0xFF41 && rune <= 0xFF5A) return true; // fullwidth a-z
    return false;
  }

  /// Whether [rune] is a non-CJK word character: Latin, digit or underscore.
  static bool _isWordRune(int rune) {
    if (rune == 0x5F) return true; // underscore
    if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
    if (rune >= 0x41 && rune <= 0x5A) return true; // A-Z
    if (rune >= 0x61 && rune <= 0x7A) return true; // a-z
    if (rune >= 0x00C0 && rune <= 0x02AF) return true; // latin extended
    if (rune >= 0x0370 && rune <= 0x052F) return true; // greek, cyrillic
    if (rune >= 0x0590 && rune <= 0x08FF) return true; // hebrew, arabic
    if (rune >= 0x0900 && rune <= 0x0E7F) return true; // indic, thai, lao
    if (rune >= 0xFF10 && rune <= 0xFF19) return true; // fullwidth 0-9
    if (rune >= 0xFF21 && rune <= 0xFF3A) return true; // fullwidth A-Z
    if (rune >= 0xFF41 && rune <= 0xFF5A) return true; // fullwidth a-z
    return false;
  }

  FilterResult _report(
    FilterStatus status,
    String reasonCode,
    String explanation, {
    List<FilterEvidence> evidence = const <FilterEvidence>[],
    double? score,
    String? errorCode,
  }) => FilterResult(
    operatorId: id,
    status: status,
    reasonCode: reasonCode,
    explanation: explanation,
    evidence: evidence,
    score: score,
    errorCode: errorCode,
  );
}

List<String> _readStringList(Object? value) {
  if (value is List) {
    return <String>[
      for (final item in value)
        if (item is String) item,
    ];
  }
  return const <String>[];
}
