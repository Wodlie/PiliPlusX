import 'package:PiliPlus/services/content_guard/content_guard_service.dart';
import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';
import 'package:PiliPlus/services/content_guard/slice/content_guard_pipeline.dart';
import 'package:PiliPlus/services/content_guard/source/static_reply_source.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/suggestion/blacklist_suggestion.dart';
import 'package:PiliPlus/services/content_guard/suggestion/suggestion_policy.dart';

/// One request's configuration, supplied by the owning list controller.
/// AccountScope must come from that page request, including credential rotation.
final class ContentGuardOwnerConfig {
  ContentGuardOwnerConfig({
    required this.store,
    required this.account,
    required this.source,
    required List<RuleDefinition> rules,
    required this.featureEnabled,
    required this.suggestionsEnabled,
    this.suggestionPolicy = const SuggestionPolicy(
      threshold: 3,
      windowDays: 30,
    ),
    this.nowMs,
  }) : rules = List<RuleDefinition>.unmodifiable(rules) {
    if (rules.isEmpty)
      throw ArgumentError('Root comment rules must not be empty');
  }

  final KeyValueStore store;
  final AccountScope account;
  final StaticReplySource source;
  final List<RuleDefinition> rules;
  final bool featureEnabled;
  final bool suggestionsEnabled;
  final SuggestionPolicy suggestionPolicy;
  final int Function()? nowMs;
}

/// A lease is also the page bridge binding: use service.pipeline and generation
/// from this lease together. Never share a lease or owner across list controllers.
final class ContentGuardLease {
  ContentGuardLease._(this._owner, this._epoch, this.service)
    : generation = service.generation;

  final ContentGuardOwner _owner;
  final int _epoch;
  final ContentGuardService service;
  final int generation;

  bool get isCurrent =>
      !_owner._closed &&
      _owner._epoch == _epoch &&
      identical(_owner._lease, this) &&
      service.generation == generation;

  bool get suggestionsEnabled => isCurrent && _owner._suggestionsEnabled;

  bool accepts(PipelineResult result) =>
      isCurrent &&
      !result.isStale &&
      result.generation == generation &&
      result.account == service.account &&
      result.surface == ContentSurface.rootComments;

  /// Reads current durable state so another list's accept/reject suppresses it.
  BlacklistSuggestion? visibleSuggestion(PipelineResult result) {
    if (!suggestionsEnabled || !accepts(result)) return null;
    final candidate = result.authorSuggestion;
    if (candidate == null) return null;
    final shown = service.suggestions.byId(candidate.authorSuggestionId);
    return shown?.isRenderable == true ? shown : null;
  }

  /// Candidate means qualified, not on screen. Promotion is explicit and gated
  /// by the owner preference; durable accepted/rejected records are never reset.
  Future<BlacklistSuggestion?> presentSuggestion(PipelineResult result) async {
    if (!suggestionsEnabled || !accepts(result)) return null;
    final candidate = result.authorSuggestion;
    if (candidate == null) return null;
    await service.suggestions.present(candidate.authorSuggestionId);
    return visibleSuggestion(result);
  }
}

final class _RequestLease {
  bool active = true;
}

/// Pure Dart lifecycle held by exactly one root-comment list controller.
/// This slice supports video/main_reply/common_dyn root lists only.
final class ContentGuardOwner {
  int _epoch = 0;
  bool _closed = false;
  bool _suggestionsEnabled = false;
  ContentGuardLease? _lease;
  _RequestLease? _request;

  ContentGuardLease? get current => _lease?.isCurrent == true ? _lease : null;
  bool get isClosed => _closed;

  /// Invalidates retained bridge references and in-flight pipeline work.
  /// An already-started idempotent ledger write follows the core contract; no
  /// subsequent suggestion reconciliation or result publication may use it.
  void invalidate() {
    _epoch++;
    _request?.active = false;
    _request = null;
    final old = _lease;
    _lease = null;
    if (old != null) old.service.beginGeneration(old.service.generation + 1);
  }

  /// Always creates a fresh service/pipeline, including same-mid credential
  /// rotation. Durable namespace identity remains the service's responsibility.
  /// A stale asynchronous creation returns null and never becomes current.
  Future<ContentGuardLease?> rebuild(ContentGuardOwnerConfig config) async {
    if (_closed) throw StateError('ContentGuard owner is closed');
    invalidate();
    final epoch = _epoch;
    _suggestionsEnabled = config.suggestionsEnabled;
    if (!config.featureEnabled || config.account.isGuest) return null;
    final request = _request = _RequestLease();
    final service = await ContentGuardService.create(
      store: config.store,
      account: config.account,
      rules: config.rules,
      operators: config.source.createOperators(isActive: () => request.active),
      suggestionPolicy: config.suggestionPolicy,
      featureEnabled: config.featureEnabled,
      nowMs: config.nowMs,
    );
    if (_closed || epoch != _epoch) {
      service.beginGeneration(service.generation + 1);
      return null;
    }
    return _lease = ContentGuardLease._(this, epoch, service);
  }

  /// Synchronizes a bridge-driven generation bump without bumping it again.
  /// Call after bridge.beginList(), passing the lease used to bind that bridge.
  /// The exact new pipeline generation is required; old results stay obsolete.
  ContentGuardLease adoptCurrentGeneration(
    ContentGuardLease lease, {
    required int generation,
  }) {
    if (_closed ||
        !identical(_lease, lease) ||
        lease._epoch != _epoch ||
        _request?.active != true) {
      throw StateError('Cannot adopt a retired ContentGuard lease');
    }
    if (generation != lease.service.generation ||
        generation < lease.generation) {
      throw ArgumentError(
        'Generation must equal the current pipeline generation',
      );
    }
    if (generation == lease.generation) return lease;
    _epoch++;
    return _lease = ContentGuardLease._(this, _epoch, lease.service);
  }

  /// Refresh/sort changes keep the assembly and acquire a new generation.
  /// Retire the old bridge, then bind its replacement to this returned lease.
  ContentGuardLease beginGeneration() {
    final old = current;
    if (old == null) throw StateError('ContentGuard owner is inactive');
    _epoch++;
    old.service.beginGeneration(old.service.generation + 1);
    return _lease = ContentGuardLease._(this, _epoch, old.service);
  }

  /// Display preference only: do not clear, reject or overwrite saved decisions.
  void setSuggestionsEnabled(bool enabled) {
    if (_closed) return;
    _suggestionsEnabled = enabled;
  }

  void disable() {
    invalidate();
    _suggestionsEnabled = false;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    disable();
  }

  /// Null means inactive or obsolete, not a clean policy verdict.
  Future<PipelineResult?> evaluate(GuardContent content) async {
    final lease = current;
    if (lease == null) return null;
    if (content.surface != ContentSurface.rootComments ||
        content.contentType != ContentType.comment) {
      throw ArgumentError('This owner supports root comments only');
    }
    final result = await lease.service.evaluate(content);
    return lease.accepts(result) ? result : null;
  }
}
