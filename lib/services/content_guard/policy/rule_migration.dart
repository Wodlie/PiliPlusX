/// Upgrades stored rule documents to [RuleSchema.currentSchemaVersion].
///
/// A stored rule outlives the build that wrote it, so this file has to answer
/// one question honestly: can this build still tell what an old document means?
/// When it cannot, the answer is a typed rejection — never a best-effort
/// coercion and never a silent drop. Concretely:
///
/// * **Newer version** — a document written by a future build is rejected with
///   [RuleSchemaException.unsupportedSchemaVersion]. Applying v1 semantics to a
///   v2 rule would hide or show the wrong content without any visible failure.
/// * **Older version** — the document is upgraded through an explicit, ordered
///   chain of [RuleMigration] steps, and each applied step is recorded in
///   [RuleDefinition.migration] so the UI can explain the change.
/// * **Too old** — a version below [RuleSchema.minimumSchemaVersion] is rejected;
///   there is no step that still knows the difference.
///
/// Migration steps transform JSON, not objects: the same strict decoder then
/// validates the result, so a bad migration fails loudly instead of producing a
/// half-formed rule.
library;

import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_schema.dart';

/// One explicit upgrade step between two adjacent schema versions.
final class RuleMigration {
  const RuleMigration({
    required this.fromVersion,
    required this.toVersion,
    required this.description,
    required this.apply,
  });

  /// Version this step reads.
  final int fromVersion;

  /// Version this step produces. Must be [fromVersion] + 1: chaining is defined
  /// step by step, so a gap cannot be skipped over.
  final int toVersion;

  /// Stable, human-readable summary recorded in [RuleDefinition.migration] when
  /// this step runs. Never localised; the UI translates by code if it wants to.
  final String description;

  /// Rewrites a v[fromVersion] document into a v[toVersion] document.
  ///
  /// Receives an unmodifiable copy and must return a new map. It may throw
  /// [RuleSchemaException] to reject a document it cannot honestly upgrade.
  final Map<String, Object?> Function(Map<String, Object?> document) apply;

  @override
  String toString() =>
      'RuleMigration(v$fromVersion -> v$toVersion: '
      '$description)';
}

/// The migration chain this build ships, plus the entry point that applies it.
final class RuleMigrator {
  /// Builds a migrator over an explicit chain.
  ///
  /// Throws [ArgumentError] when the chain is malformed: a gap between steps, two
  /// steps from one version, or a step that does not advance by exactly one
  /// version would make migration order-dependent and unreproducible.
  RuleMigrator(List<RuleMigration> migrations)
    : _byFromVersion = _index(migrations);

  /// A migrator with no steps: only documents already at the current version
  /// can be read.
  RuleMigrator.empty() : _byFromVersion = const <int, RuleMigration>{};

  /// The chain this build ships.
  ///
  /// Currently one step: v0 documents predate the mandatory
  /// unknown/error actions, and gain an explicit [ContinueAction] for both. The
  /// step is deliberately conservative — it does not invent a disposition, so a
  /// capability-less build still reports the rule as unresolved instead of
  /// silently allowing or hiding (plan-core section 2.3).
  factory RuleMigrator.standard() =>
      RuleMigrator(const <RuleMigration>[_unknownActionDefaults]);

  final Map<int, RuleMigration> _byFromVersion;

  /// Versions that have an upgrade step, ascending.
  List<int> get supportedVersions => _byFromVersion.keys.toList()..sort();

  /// Whether [version] can be upgraded to the current schema.
  bool canUpgradeFrom(int version) {
    if (version == RuleSchema.currentSchemaVersion) return true;
    if (version < RuleSchema.minimumSchemaVersion) return false;
    var current = version;
    while (current < RuleSchema.currentSchemaVersion) {
      final step = _byFromVersion[current];
      if (step == null) return false;
      current = step.toVersion;
    }
    return true;
  }

  /// Reads [document], upgrading it when it was authored under an older schema.
  ///
  /// Throws [RuleSchemaException] when the version is newer than this build,
  /// older than the minimum, or has no complete upgrade path.
  RuleDefinition upgrade(Object? document) {
    final map = _asMap(document);
    final versionField = map[_versionKey];
    if (!map.containsKey(_versionKey)) {
      throw const RuleSchemaException(
        code: RuleSchemaException.missingField,
        path: _versionKey,
        message: 'a rule document must declare its schemaVersion',
      );
    }
    if (versionField is! int) {
      throw RuleSchemaException(
        code: RuleSchemaException.wrongType,
        path: _versionKey,
        message:
            'schemaVersion must be an integer, got ${_kindOf(versionField)}',
      );
    }
    if (versionField > RuleSchema.currentSchemaVersion) {
      throw RuleSchemaException(
        code: RuleSchemaException.unsupportedSchemaVersion,
        path: _versionKey,
        message:
            'schemaVersion $versionField was written by a newer build; this '
            'build reads at most ${RuleSchema.currentSchemaVersion} and must '
            'not coerce it',
      );
    }
    if (versionField < RuleSchema.minimumSchemaVersion) {
      throw RuleSchemaException(
        code: RuleSchemaException.unsupportedSchemaVersion,
        path: _versionKey,
        message:
            'schemaVersion $versionField predates the oldest supported version '
            '${RuleSchema.minimumSchemaVersion}',
      );
    }

    var current = map;
    var version = versionField;
    final applied = <String>[];
    while (version < RuleSchema.currentSchemaVersion) {
      final step = _byFromVersion[version];
      if (step == null) {
        throw RuleSchemaException(
          code: RuleSchemaException.unsupportedSchemaVersion,
          path: _versionKey,
          message:
              'no migration step from schemaVersion $version; the rule cannot '
              'be upgraded to ${RuleSchema.currentSchemaVersion}',
        );
      }
      current = _asMap(step.apply(Map<String, Object?>.unmodifiable(current)));
      version = step.toVersion;
      applied.add(step.description);
    }

    final rewritten = <String, Object?>{
      for (final entry in current.entries) entry.key: entry.value,
      _versionKey: RuleSchema.currentSchemaVersion,
      _migrationKey: <Object?>[
        ..._existingSteps(current),
        ...applied,
      ],
    };
    return RuleSchema.decode(rewritten);
  }

  /// Reads a JSON list of rule documents, upgrading each.
  List<RuleDefinition> upgradeAll(Object? documents) {
    if (documents is! List) {
      throw RuleSchemaException(
        code: RuleSchemaException.wrongType,
        path: 'rules',
        message:
            'expected a list of rule documents, got '
            '${_kindOf(documents)}',
      );
    }
    final result = <RuleDefinition>[
      for (var index = 0; index < documents.length; index++)
        upgrade(documents[index]),
    ];
    final seen = <String>{};
    for (final rule in result) {
      if (!seen.add(rule.id)) {
        throw RuleSchemaException(
          code: RuleSchemaException.duplicateRuleId,
          path: 'rules',
          message: 'rule id "${rule.id}" appears more than once',
        );
      }
    }
    return List<RuleDefinition>.unmodifiable(result);
  }

  static Map<String, Object?> _asMap(Object? document) {
    if (document is Map<String, Object?>) return document;
    if (document is Map) {
      final result = <String, Object?>{};
      for (final entry in document.entries) {
        final key = entry.key;
        if (key is! String) {
          throw const RuleSchemaException(
            code: RuleSchemaException.notAnObject,
            path: 'rule',
            message: 'a rule document must have string keys',
          );
        }
        result[key] = entry.value;
      }
      return result;
    }
    throw RuleSchemaException(
      code: RuleSchemaException.notAnObject,
      path: 'rule',
      message: 'expected a rule document object, got ${_kindOf(document)}',
    );
  }

  static List<String> _existingSteps(Map<String, Object?> document) {
    final raw = document[_migrationKey];
    if (raw is! List) return const <String>[];
    return <String>[
      for (final step in raw)
        if (step is String) step,
    ];
  }

  static Map<int, RuleMigration> _index(List<RuleMigration> migrations) {
    final indexed = <int, RuleMigration>{};
    for (final migration in migrations) {
      if (migration.toVersion != migration.fromVersion + 1) {
        throw ArgumentError.value(
          migration,
          'migrations',
          'a step must advance exactly one schema version',
        );
      }
      if (indexed.containsKey(migration.fromVersion)) {
        throw ArgumentError.value(
          migration.fromVersion,
          'migrations',
          'two steps start from the same schema version',
        );
      }
      indexed[migration.fromVersion] = migration;
    }
    return Map<int, RuleMigration>.unmodifiable(indexed);
  }

  static String _kindOf(Object? value) => switch (value) {
    null => 'null',
    String() => 'a string',
    int() => 'an integer',
    num() => 'a number',
    bool() => 'a bool',
    List() => 'a list',
    Map() => 'an object',
    _ => 'an unsupported value',
  };

  static const String _versionKey = 'schemaVersion';
  static const String _migrationKey = 'migration';

  /// v0 -> v1: documents written before the unknown/error actions existed gain
  /// an explicit [ContinueAction] for both.
  ///
  /// [ContinueAction] is the only correct default: the rule said nothing about
  /// unresolved conditions, and inventing a hide would silently suppress content
  /// the author never asked to hide.
  static const RuleMigration _unknownActionDefaults = RuleMigration(
    fromVersion: 0,
    toVersion: 1,
    description: 'v0->v1: add explicit unknownAction/errorAction defaults',
    apply: _addUnresolvedActions,
  );

  static Map<String, Object?> _addUnresolvedActions(
    Map<String, Object?> document,
  ) {
    const continueAction = <String, Object?>{'type': 'continue'};
    return <String, Object?>{
      for (final entry in document.entries)
        if (entry.key != _versionKey) entry.key: entry.value,
      if (!document.containsKey('unknownAction'))
        'unknownAction': continueAction,
      if (!document.containsKey('errorAction')) 'errorAction': continueAction,
    };
  }
}
