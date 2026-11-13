import 'dart:async';
import 'dart:isolate';

import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/filter_evidence.dart';
import 'package:PiliPlus/services/content_guard/model/filter_result.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/model/operator_status.dart';
import 'package:PiliPlus/services/content_guard/operator/filter_operator.dart';

/// Stable reason codes emitted by [RegexOperator].
///
/// Machine values: they land in rule JSON, cache keys and the violation ledger.
abstract final class RegexReasonCodes {
  /// The configured pattern matched a configured field.
  static const String matched = 'regex.matched';

  /// The pattern compiled and searched every configured field without a hit.
  static const String noMatch = 'regex.no_match';

  /// The rule configures no pattern at all.
  static const String noPattern = 'regex.no_pattern';

  /// The configured pattern was rejected, so no evaluation was possible.
  static const String patternRejected = 'regex.pattern_rejected';

  /// That content carries none of the configured fields.
  static const String noTargetField = 'regex.no_target_field';

  /// A configured field is longer than the operator will search, so the field
  /// was skipped instead of risking a pathological search.
  static const String inputTooLong = 'regex.input_too_long';

  /// The search did not settle inside the configured budget, so the worker
  /// running it was terminated.
  static const String searchTimeout = 'regex.search_timeout';

  /// The caller cancelled the run before a verdict was reached.
  static const String cancelled = 'regex.cancelled';

  /// The matcher could not be executed at all (no isolate available, or the
  /// worker died without answering), so the pattern was never judged.
  static const String matcherUnavailable = 'regex.matcher_unavailable';
}

/// Stable error codes emitted by [RegexOperator].
///
/// Every one of them is reported together with [FilterStatus.error]: a pattern
/// that cannot be compiled is a broken rule, and a broken rule must never
/// collapse into "no match", which would be a silent allow.
abstract final class RegexErrorCodes {
  /// The pattern text is longer than [RegexOperatorConfig.maxPatternLength].
  static const String patternTooLong = 'regex.pattern_too_long';

  /// The engine rejected the pattern.
  static const String patternInvalid = 'regex.pattern_invalid';

  /// The engine rejected the pattern for a reason other than its syntax.
  static const String compileFailed = 'regex.compile_failed';

  /// The pattern contains a nested quantifier that can backtrack
  /// catastrophically, so it was refused instead of executed.
  static const String unsafePattern = 'regex.unsafe_pattern';

  /// The search ran past [RegexOperatorConfig.matchTimeoutMs] and the worker
  /// running it had to be terminated.
  ///
  /// Retryable on purpose: the same rule may still judge a shorter input
  /// successfully, so one timeout is not evidence of a broken rule.
  static const String matchTimeout = 'regex.match_timeout';

  /// The caller cancelled the run, so the worker was terminated before it
  /// reached a verdict.
  static const String cancelled = 'regex.cancelled';

  /// The matcher could not be executed (isolate unavailable, worker died),
  /// so nothing was judged. Retryable for the same reason as [matchTimeout].
  static const String matcherUnavailable = 'regex.matcher_unavailable';
}

/// Configuration of a [RegexOperator].
///
/// Rule JSON shape (the authoring contract):
///
///     {
///       "pattern": "vx[:：]\\s*[a-zA-Z0-9_-]+",
///       "caseSensitive": false,
///       "dotAll": false,
///       "multiLine": false,
///       "unicode": false,
///       "maxInputLength": 4096,
///       "maxPatternLength": 512,
///       "matchTimeoutMs": 250,
///       "targets": ["text", "title", "tags"]
///     }
///
/// Every key is optional. A wrong-typed value falls back to its default instead
/// of throwing: one malformed rule must not abort a whole ruleset load, and the
/// real problem is still reported through the verdict (see [RegexErrorCodes]).
final class RegexOperatorConfig {
  const RegexOperatorConfig({
    this.pattern,
    this.caseSensitive = false,
    this.dotAll = false,
    this.multiLine = false,
    this.unicode = false,
    this.maxInputLength = defaultMaxInputLength,
    this.maxPatternLength = defaultMaxPatternLength,
    this.matchTimeoutMs = defaultMatchTimeoutMs,
    this.targets = defaultTargets,
  });

  /// Reads the rule JSON map described on [RegexOperatorConfig].
  ///
  /// Unknown keys are ignored. A target naming a field this operator cannot
  /// read is dropped; when no usable target remains the defaults apply. A
  /// [matchTimeoutMs] outside [minMatchTimeoutMs]..[maxMatchTimeoutMs] is
  /// clamped into that range rather than trusted.
  factory RegexOperatorConfig.fromJson(Map<String, Object?> json) {
    final targets = <ContentInput>[];
    for (final name in _readStringList(json['targets'])) {
      final input = enumByWireName(ContentInput.values, name);
      if (input != null && supportedTargets.contains(input)) {
        targets.add(input);
      }
    }
    return RegexOperatorConfig(
      pattern: json['pattern'] is String ? json['pattern'] as String : null,
      caseSensitive: json['caseSensitive'] == true,
      dotAll: json['dotAll'] == true,
      multiLine: json['multiLine'] == true,
      unicode: json['unicode'] == true,
      maxInputLength: _readPositiveInt(
        json['maxInputLength'],
        defaultMaxInputLength,
      ),
      maxPatternLength: _readPositiveInt(
        json['maxPatternLength'],
        defaultMaxPatternLength,
      ),
      matchTimeoutMs: clampMatchTimeoutMs(
        _readPositiveInt(json['matchTimeoutMs'], defaultMatchTimeoutMs),
      ),
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
  static const Set<ContentInput> supportedTargets = <ContentInput>{
    ContentInput.text,
    ContentInput.title,
    ContentInput.tags,
  };

  /// Upper bound applied to one input field before any search runs.
  ///
  /// A user-supplied pattern over an unbounded haystack is the cheapest way to
  /// hang the engine, so the guard belongs on the input as much as on the
  /// pattern.
  static const int defaultMaxInputLength = 4096;

  /// Upper bound applied to the pattern text before compilation.
  static const int defaultMaxPatternLength = 512;

  /// Wall-clock budget one evaluation may spend searching, in milliseconds.
  ///
  /// Conservative on purpose: a pattern that cannot judge a capped 4 KiB field
  /// inside this budget is a rule defect, not a slow machine. The budget covers
  /// worker start-up, compilation and every field of one evaluation.
  static const int defaultMatchTimeoutMs = 250;

  /// Smallest accepted budget. Below it the deadline would reject healthy
  /// patterns, turning a working rule into a stream of errors.
  static const int minMatchTimeoutMs = 1;

  /// Largest accepted budget. The isolate deadline is what bounds a
  /// pathological pattern, so this ceiling is what keeps one hostile rule from
  /// parking a worker for a long time.
  static const int maxMatchTimeoutMs = 2000;

  /// Clamps [value] into [minMatchTimeoutMs]..[maxMatchTimeoutMs].
  ///
  /// A non-positive value cannot express a deadline, so it degrades to
  /// [defaultMatchTimeoutMs] instead of producing an instantly expired budget.
  static int clampMatchTimeoutMs(int value) {
    if (value <= 0) return defaultMatchTimeoutMs;
    if (value < minMatchTimeoutMs) return minMatchTimeoutMs;
    if (value > maxMatchTimeoutMs) return maxMatchTimeoutMs;
    return value;
  }

  /// Source pattern, or null when the rule carries none.
  final String? pattern;

  /// Whether the pattern is compiled case-sensitively. Defaults to **false**:
  /// the banned-word filter the app already ships is case-insensitive too.
  final bool caseSensitive;

  /// Whether a dot also matches a newline.
  final bool dotAll;

  /// Whether carets and dollars match at line boundaries.
  final bool multiLine;

  /// Whether the pattern uses Unicode character classes.
  final bool unicode;

  /// Longest field value the operator will search.
  final int maxInputLength;

  /// Longest pattern the operator will compile.
  final int maxPatternLength;

  /// Wall-clock budget for one evaluation, in milliseconds.
  ///
  /// Enforced by terminating the worker isolate that runs the search, never by
  /// a timer alone: a timer cannot preempt a synchronous backtracking loop, but
  /// killing the isolate that runs it can.
  final int matchTimeoutMs;

  /// Fields searched, in evidence order.
  final List<ContentInput> targets;
}

/// Judges content by searching a user-supplied regular expression.
///
/// Pure local operator: no network, no inference, no storage, no side effects.
///
/// ## Why the search does not run on the calling isolate
///
/// A regular expression is user input executed by the engine, and Dart's
/// [RegExp] has no timeout of its own. The pattern '^(a|aa)+$' against 128 'a'
/// characters followed by '!' does not return in any useful time, so calling
/// [RegExp.hasMatch] on the app isolate freezes the application for as long as
/// the engine keeps backtracking — a measured result, not a theory. The
/// operator therefore never calls it on the calling isolate.
///
/// ## How the work is bounded
///
/// 1. **Length caps.** [RegexOperatorConfig.maxPatternLength] and
///    [RegexOperatorConfig.maxInputLength] are enforced before compilation and
///    before each search. Exceeding them never silently passes: a rejected
///    pattern is an error, a skipped field is an unknown.
/// 2. **A throwaway worker and a hard deadline.** Compilation *and* the search
///    of every field happen inside one short-lived isolate. If it has not
///    answered within [RegexOperatorConfig.matchTimeoutMs] the isolate is
///    terminated — [Isolate.kill] preempts it within a few milliseconds — and
///    the verdict is [FilterStatus.error] with [RegexErrorCodes.matchTimeout],
///    marked retryable. The deadline is the authoritative guard.
/// 3. **A cheap refusal on top.** A textual nested-quantifier check still
///    rejects the classic '(a+)+' shape before any worker is spawned. It is a
///    fast path, **not** the safety mechanism: shapes it misses, such as
///    '^(a|aa)+$', are stopped by the deadline.
/// 4. **Skip instead of guess.** A field longer than the cap is not searched
///    and the verdict becomes [FilterStatus.unknown], never
///    [FilterStatus.notMatched].
/// 5. **Cancellation.** An already-cancelled [OperatorRunContext] abandons the
///    run before a worker starts; a cancellation that flips mid-run terminates
///    the worker and reports [RegexErrorCodes.cancelled].
///
/// Every isolate, [ReceivePort] and [Timer] created for one evaluation is
/// released on the success, not-matched, error, timeout **and** cancellation
/// paths, so repeated evaluations do not accumulate workers.
final class RegexOperator implements FilterOperator {
  /// Creates the operator with [config] already installed.
  RegexOperator([RegexOperatorConfig config = const RegexOperatorConfig()])
    : _config = config {
    _prepare(config);
  }

  /// Stable operator id; appears in rule JSON and cache keys.
  static const String operatorId = 'static.regex';

  /// A group that already repeats, repeated again: the classic
  /// catastrophic-backtracking shape such as (a+)+, (a*)* or (a|a?)+.
  ///
  /// Detected textually because the engine exposes no pattern AST. The check is
  /// intentionally conservative — it refuses a few harmless patterns sooner
  /// than spawning a worker for them. Patterns it misses are still bounded by
  /// the worker deadline, so this is a fast path, not the guarantee.
  static final RegExp _nestedQuantifier = RegExp(
    r'\([^()]*[+*][^()]*\)\s*[+*]',
  );

  /// Worker answer codes. A non-negative answer is a matched haystack index;
  /// the negative values are the terminal non-match answers.
  static const int _codeNoMatch = -1;
  static const int _codeCompileFailed = -2;

  /// How often an in-flight run re-reads [OperatorRunContext.isCancelled].
  ///
  /// The token is an opaque getter, so polling is the only generic way to
  /// observe it while the worker runs. The deadline still bounds the total.
  static const Duration _cancelPollInterval = Duration(milliseconds: 25);

  RegexOperatorConfig _config;
  String? _compileErrorCode;

  /// Result of the pre-flight compile, kept for diagnostics only.
  ///
  /// Never consulted by [evaluate]: the worker compiles and searches on its own
  /// isolate, so a stale value here cannot weaken the deadline.
  RegExp? _preflight;

  OperatorAvailability _availability = const OperatorAvailability(
    state: OperatorInitState.ready,
  );

  /// The configuration currently installed.
  RegexOperatorConfig get config => _config;

  /// The pattern compiled by the pre-flight check, or null when the current
  /// config has none or the engine rejected it.
  ///
  /// **Diagnostics only.** Evaluation never uses this instance, and calling
  /// [RegExp.hasMatch] on it runs the engine on the caller's isolate — which is
  /// exactly the freeze this operator avoids everywhere else. Use [evaluate] to
  /// judge content.
  RegExp? get compiled => _preflight;

  /// Installs [config] and recompiles. Configuring is not a content side
  /// effect: it only changes what this judge looks for, and it is idempotent.
  ///
  /// The pre-flight compile is synchronous so an obviously broken rule is
  /// visible before any content arrives. Constructing a [RegExp] is not the
  /// unbounded step — matching is — so the deadline, not this check, is what
  /// bounds a hostile pattern.
  void configure(RegexOperatorConfig config) {
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

  /// Regex search reads no media, so no media role is required.
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
  /// A pattern that fails to compile is **not** an unavailable operator: it is
  /// a broken rule, reported per evaluation as [FilterStatus.error], while the
  /// operator stays ready because it can judge as soon as a valid pattern is
  /// configured.
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
  ) => _evaluate(content, context);

  /// Judges [contents] one after another, preserving positional order.
  ///
  /// Sequential on purpose: [batchable] is false, and running N searches at
  /// once would mean N isolates alive with N independent deadlines instead of
  /// one bounded evaluation at a time.
  @override
  Future<List<FilterResult>> evaluateBatch(
    List<GuardContent> contents,
    OperatorRunContext context,
  ) async {
    final results = <FilterResult>[];
    for (final item in contents) {
      results.add(await _evaluate(item, context));
    }
    return results;
  }

  Future<FilterResult> _evaluate(
    GuardContent content,
    OperatorRunContext context,
  ) async {
    // A broken rule spawns no worker and never collapses into "no match".
    final rejected = _rejection();
    if (rejected != null) return rejected;

    final config = _config;
    if (config.targets.isEmpty) {
      return _report(
        FilterStatus.unknown,
        RegexReasonCodes.noTargetField,
        'The rule configures no searchable field.',
      );
    }

    var sawField = false;
    var sawOversizeField = false;
    final pending = <_SearchTarget>[];
    for (final target in config.targets) {
      final values = _valuesOf(content, target);
      if (values.isEmpty) continue;
      sawField = true;
      for (final value in values) {
        if (value.isEmpty) continue;
        if (value.length > config.maxInputLength) {
          sawOversizeField = true;
          continue;
        }
        pending.add(_SearchTarget(target, value));
      }
    }

    if (!sawField) {
      return _report(
        FilterStatus.unknown,
        RegexReasonCodes.noTargetField,
        'This content carries none of the configured fields.',
      );
    }
    if (pending.isEmpty) {
      // Every usable value was empty; or every field was skipped as oversize,
      // which is an unknown rather than a silent negative.
      return sawOversizeField
          ? _report(
              FilterStatus.unknown,
              RegexReasonCodes.inputTooLong,
              'A configured field exceeds the searchable length.',
            )
          : _report(
              FilterStatus.notMatched,
              RegexReasonCodes.noMatch,
              'The configured pattern did not match.',
            );
    }

    final result = await _search(pending, config, context);
    return switch (result.outcome) {
      _SearchOutcome.matched => _report(
        FilterStatus.matched,
        RegexReasonCodes.matched,
        'The configured pattern matched.',
        evidence: <FilterEvidence>[
          // A regex hit cannot be quoted without leaking the text it matched,
          // so only the field name is recorded.
          FilterEvidence(
            kind: EvidenceKind.text,
            field: _fieldName(result.field!),
          ),
        ],
        score: 1,
      ),
      _SearchOutcome.notMatched =>
        sawOversizeField
            ? _report(
                FilterStatus.unknown,
                RegexReasonCodes.inputTooLong,
                'A configured field exceeds the searchable length.',
              )
            : _report(
                FilterStatus.notMatched,
                RegexReasonCodes.noMatch,
                'The configured pattern did not match.',
              ),
      _SearchOutcome.timedOut => _report(
        FilterStatus.error,
        RegexReasonCodes.searchTimeout,
        'The pattern did not settle within the match budget, so the worker '
        'running it was terminated.',
        errorCode: RegexErrorCodes.matchTimeout,
        retryable: true,
      ),
      _SearchOutcome.cancelled => _report(
        FilterStatus.error,
        RegexReasonCodes.cancelled,
        'The run was cancelled before the pattern produced a verdict.',
        errorCode: RegexErrorCodes.cancelled,
        retryable: true,
      ),
      _SearchOutcome.compileFailed => _report(
        FilterStatus.error,
        RegexReasonCodes.patternRejected,
        'The configured pattern was rejected, so nothing was searched.',
        errorCode: RegexErrorCodes.patternInvalid,
      ),
      _SearchOutcome.matcherUnavailable => _report(
        FilterStatus.error,
        RegexReasonCodes.matcherUnavailable,
        'The pattern could not be executed, so nothing was searched.',
        errorCode: RegexErrorCodes.matcherUnavailable,
        retryable: true,
      ),
    };
  }

  /// Searches [pending] inside one worker and enforces the deadline.
  ///
  /// Owns every resource it creates. The finally block runs on the matched,
  /// not-matched, timeout, cancellation and failure paths alike, which is what
  /// keeps repeated evaluations from leaking isolates or ports. Closing the
  /// reply port first also guarantees no late message can resurrect a verdict
  /// after [settled] has been completed.
  Future<_SearchResult> _search(
    List<_SearchTarget> pending,
    RegexOperatorConfig config,
    OperatorRunContext context,
  ) async {
    // Already cancelled: no isolate is created at all.
    if (context.isCancelled) {
      return const _SearchResult(_SearchOutcome.cancelled);
    }

    final replies = ReceivePort();
    final exits = ReceivePort();
    final settled = Completer<_SearchResult>();

    void settle(_SearchResult result) {
      if (!settled.isCompleted) settled.complete(result);
    }

    final replySubscription = replies.listen((Object? message) {
      if (message is! List || message.isEmpty) return;
      final code = message.first;
      if (code is! int) return;
      if (code >= 0 && code < pending.length) {
        settle(_SearchResult(_SearchOutcome.matched, pending[code].target));
      } else if (code == _codeNoMatch) {
        settle(const _SearchResult(_SearchOutcome.notMatched));
      } else {
        settle(const _SearchResult(_SearchOutcome.compileFailed));
      }
    });
    final exitSubscription = exits.listen((Object? _) {
      // The worker exited without a verdict: what was not judged is an error,
      // never a pass.
      settle(const _SearchResult(_SearchOutcome.matcherUnavailable));
    });

    Isolate? isolate;
    Timer? deadline;
    Timer? cancelPoll;
    try {
      try {
        isolate = await Isolate.spawn<_WorkerJob>(
          _regexWorkerMain,
          _WorkerJob(
            replies.sendPort,
            config.pattern!,
            config.caseSensitive,
            config.multiLine,
            config.unicode,
            config.dotAll,
            <String>[for (final item in pending) item.value],
          ),
          onExit: exits.sendPort,
          debugName: 'ContentGuardRegexWorker',
        );
      } on Object {
        // No isolate on this platform, or the platform refused one: the
        // pattern was never executed, which is an error, never a pass.
        return const _SearchResult(_SearchOutcome.matcherUnavailable);
      }

      deadline = Timer(
        Duration(milliseconds: config.matchTimeoutMs),
        () => settle(const _SearchResult(_SearchOutcome.timedOut)),
      );
      if (context.cancellation != null) {
        cancelPoll = Timer.periodic(_cancelPollInterval, (_) {
          if (context.isCancelled) {
            settle(const _SearchResult(_SearchOutcome.cancelled));
          }
        });
      }

      return await settled.future;
    } finally {
      deadline?.cancel();
      cancelPoll?.cancel();
      await replySubscription.cancel();
      await exitSubscription.cancel();
      replies.close();
      exits.close();
      // Harmless once the worker finished on its own; decisive when the
      // deadline or a cancellation cut a backtracking search short.
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  /// The compile verdict for the current config, or null when it is usable.
  FilterResult? _rejection() {
    final source = _config.pattern;
    if (source == null || source.isEmpty) {
      return _report(
        FilterStatus.error,
        RegexReasonCodes.noPattern,
        'The rule configures no pattern.',
        errorCode: RegexErrorCodes.patternInvalid,
      );
    }
    final compileError = _compileErrorCode;
    if (compileError != null) {
      return _report(
        FilterStatus.error,
        RegexReasonCodes.patternRejected,
        'The configured pattern was rejected, so nothing was searched.',
        errorCode: compileError,
      );
    }
    return null;
  }

  void _prepare(RegexOperatorConfig config) {
    _preflight = null;
    _compileErrorCode = null;
    final source = config.pattern;
    if (source == null || source.isEmpty) return;
    if (source.length > config.maxPatternLength) {
      _compileErrorCode = RegexErrorCodes.patternTooLong;
      return;
    }
    if (_nestedQuantifier.hasMatch(source)) {
      _compileErrorCode = RegexErrorCodes.unsafePattern;
      return;
    }
    try {
      _preflight = RegExp(
        source,
        caseSensitive: config.caseSensitive,
        multiLine: config.multiLine,
        unicode: config.unicode,
        dotAll: config.dotAll,
      );
    } on FormatException {
      _compileErrorCode = RegexErrorCodes.patternInvalid;
    } catch (_) {
      _compileErrorCode = RegexErrorCodes.compileFailed;
    }
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

  FilterResult _report(
    FilterStatus status,
    String reasonCode,
    String explanation, {
    List<FilterEvidence> evidence = const <FilterEvidence>[],
    double? score,
    String? errorCode,
    bool retryable = false,
  }) => FilterResult(
    operatorId: id,
    status: status,
    reasonCode: reasonCode,
    explanation: explanation,
    evidence: evidence,
    score: score,
    errorCode: errorCode,
    retryable: retryable,
  );
}

/// One field value that still has to be searched, with the field it came from.
final class _SearchTarget {
  const _SearchTarget(this.target, this.value);

  final ContentInput target;
  final String value;
}

enum _SearchOutcome {
  matched,
  notMatched,
  timedOut,
  cancelled,
  compileFailed,
  matcherUnavailable,
}

final class _SearchResult {
  const _SearchResult(this.outcome, [this.field]);

  final _SearchOutcome outcome;
  final ContentInput? field;
}

/// Everything the worker isolate needs, as one sendable value.
///
/// The pattern travels as text instead of a compiled [RegExp] because a [RegExp]
/// cannot be sent between isolates; the worker compiles it on its own side,
/// which also puts compilation under the same deadline.
final class _WorkerJob {
  const _WorkerJob(
    this.replies,
    this.pattern,
    this.caseSensitive,
    this.multiLine,
    this.unicode,
    this.dotAll,
    this.haystacks,
  );

  final SendPort replies;
  final String pattern;
  final bool caseSensitive;
  final bool multiLine;
  final bool unicode;
  final bool dotAll;
  final List<String> haystacks;
}

/// Worker entry point. Must stay a top-level function for [Isolate.spawn].
///
/// Answers exactly once: a matched haystack index, [_codeNoMatch], or
/// [_codeCompileFailed]. It cannot answer when the search never terminates,
/// which is precisely why the parent owns the deadline and kills this isolate
/// instead of waiting on it.
void _regexWorkerMain(_WorkerJob job) {
  final RegExp pattern;
  try {
    pattern = RegExp(
      job.pattern,
      caseSensitive: job.caseSensitive,
      multiLine: job.multiLine,
      unicode: job.unicode,
      dotAll: job.dotAll,
    );
  } on Object {
    job.replies.send(const <Object?>[RegexOperator._codeCompileFailed]);
    return;
  }
  final haystacks = job.haystacks;
  for (var i = 0; i < haystacks.length; i++) {
    if (pattern.hasMatch(haystacks[i])) {
      job.replies.send(<Object?>[i]);
      return;
    }
  }
  job.replies.send(const <Object?>[RegexOperator._codeNoMatch]);
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

int _readPositiveInt(Object? value, int fallback) {
  if (value is int && value > 0) return value;
  if (value is num && value > 0) return value.toInt();
  return fallback;
}
