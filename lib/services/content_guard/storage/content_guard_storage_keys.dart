/// Namespaced storage keys for every ContentGuard artifact.
///
/// Key shape is `contentGuard.<domain>.<accountScopeId>.<id>`. Call sites never
/// concatenate key strings themselves: every key goes through [entry], and
/// every prefix scan through [prefix] / [idOf], so a typo cannot silently
/// write into another domain or another account.
library;

/// Key builder. Account scope is an opaque digest (see `AccountScope.id`).
abstract final class ContentGuardStorageKeys {
  /// Root namespace; nothing else in the shared box may start with this.
  static const String root = 'contentGuard';

  /// Segment separator.
  static const String separator = '.';

  static const String rules = 'rules';
  static const String operators = 'operators';
  static const String decisions = 'decisions';
  static const String violations = 'violations';
  static const String suggestions = 'suggestions';
  static const String feedback = 'feedback';
  static const String profiles = 'profiles';
  static const String mediaFeatures = 'mediaFeatures';
  static const String models = 'models';
  static const String secrets = 'secrets';

  /// Every domain this layer is allowed to write.
  static const List<String> domains = <String>[
    rules,
    operators,
    decisions,
    violations,
    suggestions,
    feedback,
    profiles,
    mediaFeatures,
    models,
    secrets,
  ];

  /// `contentGuard.<domain>.<accountScopeId>`
  static String domain(String domain, String accountScopeId) {
    _checkSegment(domain, 'domain');
    _checkSegment(accountScopeId, 'accountScopeId');
    return '$root$separator$domain$separator$accountScopeId';
  }

  /// `contentGuard.<domain>.<accountScopeId>.` — the scan prefix for [domain].
  static String prefix(String domain, String accountScopeId) =>
      '${ContentGuardStorageKeys.domain(domain, accountScopeId)}$separator';

  /// `contentGuard.<domain>.<accountScopeId>.<id>`
  static String entry(String domain, String accountScopeId, String id) {
    _checkSegment(id, 'id');
    return '${prefix(domain, accountScopeId)}$id';
  }

  /// Extracts `id` from [key], or `null` when [key] is not inside this scope.
  static String? idOf(String domain, String accountScopeId, String key) {
    final head = prefix(domain, accountScopeId);
    if (!key.startsWith(head)) {
      return null;
    }
    final id = key.substring(head.length);
    return id.isEmpty ? null : id;
  }

  /// Throws [ArgumentError] for anything that would break the key shape.
  static void _checkSegment(String value, String label) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, label, 'must not be empty');
    }
    if (value.contains(separator)) {
      throw ArgumentError.value(
        value,
        label,
        'must not contain the key separator "$separator"',
      );
    }
  }
}
