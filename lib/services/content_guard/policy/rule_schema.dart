/// Strict JSON codec for [RuleDefinition] documents.
///
/// "Strict" is the whole point of this file: rule JSON is authored outside the
/// build (a shipped preset, a user file, a future sync payload), so a decoder
/// that filled in defaults would let a typo change what a rule means without
/// anything failing. Every unknown key, unknown node type, unknown action type,
/// unknown field name and ill-typed literal is a [RuleSchemaException] carrying
/// a stable code and a JSON path.
///
/// Decoding accepts exactly `RuleSchema.currentSchemaVersion». Older documents go
/// through `rule_migration.dart» first; newer ones are rejected — a rule written
/// for a later schema cannot be guessed at by this build (plan-core section 2.4).
library;

import 'dart:convert';

import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/policy/rule_ast.dart';

/// A rule document that cannot be decoded, with a machine-readable reason.
///
/// [code] is stable and never localised, so the rule-testing UI can group
/// failures without parsing [message]; [path] points at the offending JSON
/// member (for example `when.children[1].operatorId») so an author can fix the
/// document instead of bisecting it.
final class RuleSchemaException implements Exception {
  const RuleSchemaException({
    required this.code,
    required this.message,
    this.path,
  });

  /// The payload is not JSON at all.
  static const String invalidJson = 'rule.invalid_json';

  /// A value that must be an object is not one.
  static const String notAnObject = 'rule.not_an_object';

  static const String missingField = 'rule.missing_field';

  /// A key this layer does not define. Rejected rather than ignored, so a
  /// mis-spelled priority member cannot quietly leave a rule at priority 0.
  static const String unexpectedField = 'rule.unexpected_field';

  static const String wrongType = 'rule.wrong_type';

  /// A string that must carry meaning is empty or whitespace.
  static const String blankValue = 'rule.blank_value';

  static const String unknownNodeType = 'rule.unknown_node_type';

  static const String unknownActionType = 'rule.unknown_action_type';

  static const String unknownField = 'rule.unknown_field';

  static const String unknownCompareOperator = 'rule.unknown_compare_operator';

  /// Known comparison, but not defined for this field's value kind.
  static const String unsupportedCompareOperator =
      'rule.unsupported_compare_operator';

  static const String invalidValue = 'rule.invalid_value';

  /// An operator `config` block names a credential.
  ///
  /// Rule documents are authored outside the build and round-trip through
  /// export, so a config member reserved for credential material is refused at
  /// both ends: it can neither be imported nor written back out.
  static const String credentialConfig = 'rule.credential_config';

  /// An all/any node with no children would be a constant condition.
  static const String emptyChildren = 'rule.empty_children';

  static const String duplicateRuleId = 'rule.duplicate_rule_id';

  static const String unsupportedSchemaVersion =
      'rule.unsupported_schema_version';

  final String code;

  final String message;

  /// JSON path of the offending member; absent when the failure is the document
  /// as a whole.
  final String? path;

  @override
  String toString() =>
      'RuleSchemaException($code at ${path ?? "<document>"}): $message';
}

/// Decoder/encoder for the rule document format.
///
/// Encoding is canonical: members are emitted in a fixed order, optional members
/// are always written with their effective value, and set-valued members are
/// sorted by wire name. `encode(decode(doc))» therefore equals `doc» for a
/// canonical document, which is what makes a diff of two stored rule sets
/// meaningful.
abstract final class RuleSchema {
  /// Version this build authors, reads and evaluates.
  static const int currentSchemaVersion = 1;

  /// Oldest version `rule_migration.dart» can still upgrade.
  ///
  /// v0 documents predate the mandatory unknown/error actions; the shipped chain
  /// upgrades them. Anything older than this is rejected instead of guessed at.
  static const int minimumSchemaVersion = 0;

  /// Decodes one rule document.
  static RuleDefinition decode(Object? document) =>
      _decodeRule(document, 'rule');

  /// Decodes a list of rule documents, rejecting a repeated [RuleDefinition.id].
  ///
  /// Ids key the trace and the decision cache, so two rules answering to one id
  /// would make a decision unattributable — a duplicate is a document error.
  static List<RuleDefinition> decodeList(Object? document) {
    final list = _list(document, 'rules');
    final result = <RuleDefinition>[];
    final seen = <String>{};
    for (var index = 0; index < list.length; index++) {
      final rule = _decodeRule(list[index], 'rules[$index]');
      if (!seen.add(rule.id)) {
        throw RuleSchemaException(
          code: RuleSchemaException.duplicateRuleId,
          path: 'rules[$index].id',
          message: 'rule id "${rule.id}" appears more than once',
        );
      }
      result.add(rule);
    }
    return List<RuleDefinition>.unmodifiable(result);
  }

  /// Decodes one rule document from its JSON text.
  static RuleDefinition decodeJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw RuleSchemaException(
        code: RuleSchemaException.invalidJson,
        message: 'not JSON: ${error.message}',
      );
    }
    return decode(decoded);
  }

  /// Canonical JSON object for [rule].
  static Map<String, Object?> encode(RuleDefinition rule) => <String, Object?>{
    _K.schemaVersion: rule.schemaVersion,
    if (rule.migration.isNotEmpty)
      _K.migration: List<Object?>.from(rule.migration),
    _K.id: rule.id,
    _K.enabled: rule.enabled,
    _K.priority: rule.priority,
    _K.group: rule.group,
    _K.attributeViolation: rule.attributeViolation,
    _K.when: _encodeNode(rule.when),
    _K.then: _encodeAction(rule.then),
    _K.unknownAction: _encodeAction(rule.unknownAction),
    _K.errorAction: _encodeAction(rule.errorAction),
  };

  /// Canonical JSON objects for [rules], in the given order.
  static List<Map<String, Object?>> encodeList(List<RuleDefinition> rules) => [
    for (final rule in rules) encode(rule),
  ];

  /// Canonical JSON text for [rule].
  static String encodeJson(RuleDefinition rule) => jsonEncode(encode(rule));

  // ---------------------------------------------------------------- decoding

  static RuleDefinition _decodeRule(Object? raw, String documentPath) {
    final map = _map(raw, documentPath);
    _checkKeys(
      map,
      documentPath,
      required: _K.ruleRequired,
      optional: _K.ruleOptional,
    );

    final versionPath = '$documentPath.${_K.schemaVersion}';
    final version = _int(map[_K.schemaVersion], versionPath);
    if (version != currentSchemaVersion) {
      throw RuleSchemaException(
        code: RuleSchemaException.unsupportedSchemaVersion,
        path: versionPath,
        message:
            'schema version $version is not the supported version '
            '$currentSchemaVersion; decode through RuleMigrator instead',
      );
    }

    return RuleDefinition(
      schemaVersion: version,
      migration: switch (map[_K.migration]) {
        null => const <String>[],
        final Object value => List<String>.unmodifiable(
          _stringList(value, '$documentPath.${_K.migration}'),
        ),
      },
      id: _nonBlankString(map[_K.id], '$documentPath.${_K.id}'),
      enabled: switch (map[_K.enabled]) {
        null => true,
        final Object value => _bool(value, '$documentPath.${_K.enabled}'),
      },
      priority: switch (map[_K.priority]) {
        null => 0,
        final Object value => _int(value, '$documentPath.${_K.priority}'),
      },
      group: switch (map[_K.group]) {
        null => RuleDefinition.defaultGroup,
        final Object value => _nonBlankString(
          value,
          '$documentPath.${_K.group}',
        ),
      },
      attributeViolation: switch (map[_K.attributeViolation]) {
        null => false,
        final Object value => _bool(
          value,
          '$documentPath.${_K.attributeViolation}',
        ),
      },
      when: _decodeNode(map[_K.when], '$documentPath.${_K.when}'),
      then: _decodeAction(map[_K.then], '$documentPath.${_K.then}'),
      unknownAction: _decodeAction(
        map[_K.unknownAction],
        '$documentPath.${_K.unknownAction}',
      ),
      errorAction: _decodeAction(
        map[_K.errorAction],
        '$documentPath.${_K.errorAction}',
      ),
    );
  }

  static RuleNode _decodeNode(Object? raw, String nodePath) {
    final map = _map(raw, nodePath);
    final typePath = '$nodePath.${_K.type}';
    final type = _string(map[_K.type], typePath);
    switch (type) {
      case RuleNodeTypes.all:
      case RuleNodeTypes.any:
        _checkKeys(map, nodePath, required: _K.logicalNodeRequired);
        final childrenPath = '$nodePath.${_K.children}';
        final children = _list(map[_K.children], childrenPath);
        if (children.isEmpty) {
          throw RuleSchemaException(
            code: RuleSchemaException.emptyChildren,
            path: childrenPath,
            message: 'a "$type" node needs at least one child',
          );
        }
        final nodes = <RuleNode>[
          for (var index = 0; index < children.length; index++)
            _decodeNode(children[index], '$childrenPath[$index]'),
        ];
        final immutable = List<RuleNode>.unmodifiable(nodes);
        return type == RuleNodeTypes.all
            ? AllNode(children: immutable)
            : AnyNode(children: immutable);
      case RuleNodeTypes.not:
        _checkKeys(map, nodePath, required: _K.notNodeRequired);
        return NotNode(
          child: _decodeNode(map[_K.child], '$nodePath.${_K.child}'),
        );
      case RuleNodeTypes.operator:
        _checkKeys(
          map,
          nodePath,
          required: _K.operatorNodeRequired,
          optional: _K.operatorNodeOptional,
        );
        return OperatorNode(
          operatorId: _nonBlankString(
            map[_K.operatorId],
            '$nodePath.${_K.operatorId}',
          ),
          inputs: switch (map[_K.inputs]) {
            null => const <ContentInput>{},
            final Object value => Set<ContentInput>.unmodifiable(
              _inputList(value, '$nodePath.${_K.inputs}'),
            ),
          },
          config: switch (map[_K.config]) {
            null => const <String, Object?>{},
            final Object value => _operatorConfig(
              value,
              '$nodePath.${_K.config}',
            ),
          },
        );
      case RuleNodeTypes.compare:
        return _decodeCompare(map, nodePath);
      default:
        throw RuleSchemaException(
          code: RuleSchemaException.unknownNodeType,
          path: typePath,
          message: 'unknown condition node type "$type"',
        );
    }
  }

  static CompareNode _decodeCompare(Map<String, Object?> map, String nodePath) {
    _checkKeys(
      map,
      nodePath,
      required: _K.compareNodeRequired,
      optional: _K.compareNodeOptional,
    );
    final fieldPath = '$nodePath.${_K.field}';
    final fieldName = _string(map[_K.field], fieldPath);
    final field = _byWireName(RuleField.values, fieldName);
    if (field == null) {
      throw RuleSchemaException(
        code: RuleSchemaException.unknownField,
        path: fieldPath,
        message: 'unknown comparable field "$fieldName"',
      );
    }
    final operatorPath = '$nodePath.${_K.op}';
    final operatorName = _string(map[_K.op], operatorPath);
    final comparison = _byWireName(CompareOperator.values, operatorName);
    if (comparison == null) {
      throw RuleSchemaException(
        code: RuleSchemaException.unknownCompareOperator,
        path: operatorPath,
        message: 'unknown comparison "$operatorName"',
      );
    }
    if (!_applicableOperators(field.valueKind).contains(comparison)) {
      throw RuleSchemaException(
        code: RuleSchemaException.unsupportedCompareOperator,
        path: operatorPath,
        message:
            '"$operatorName" is not defined for ${field.wireName} '
            '(${field.valueKind.name})',
      );
    }

    final operatorIdPath = '$nodePath.${_K.operatorId}';
    final String? operatorId;
    if (field.operatorDerived) {
      operatorId = _nonBlankString(map[_K.operatorId], operatorIdPath);
    } else if (map.containsKey(_K.operatorId)) {
      throw RuleSchemaException(
        code: RuleSchemaException.unexpectedField,
        path: operatorIdPath,
        message:
            'operatorId is only valid on an operator-derived field, not '
            '${field.wireName}',
      );
    } else {
      operatorId = null;
    }

    return CompareNode(
      field: field,
      operator: comparison,
      value: _compareValue(
        map[_K.value],
        field,
        comparison,
        '$nodePath.${_K.value}',
      ),
      operatorId: operatorId,
    );
  }

  static Object? _compareValue(
    Object? raw,
    RuleField field,
    CompareOperator comparison,
    String valuePath,
  ) {
    final kind = field.valueKind;
    if (comparison.isListOperator) {
      // The operand of a list operator is always a flat list of the field's own
      // value kind, including for the two list-valued fields: `tags IN [...]`
      // names the tags to look for, so a nested `[['ads']]` is a document error
      // rather than a second, silently different meaning.
      final list = _list(raw, valuePath);
      final elementKind = _listElementKind(kind);
      return List<Object?>.unmodifiable([
        for (var index = 0; index < list.length; index++)
          _scalar(list[index], elementKind, '$valuePath[$index]'),
      ]);
    }
    if (raw == null) {
      if (!_isNullable(kind) ||
          (comparison != CompareOperator.equals &&
              comparison != CompareOperator.notEquals)) {
        throw RuleSchemaException(
          code: RuleSchemaException.invalidValue,
          path: valuePath,
          message:
              'null is only a valid operand for equals/notEquals on a '
              'nullable field, not ${comparison.wireName} on '
              '${field.wireName}',
        );
      }
      return null;
    }
    return _scalar(raw, kind, valuePath);
  }

  /// Kind of one element of a list-operator operand.
  ///
  /// For every scalar field this is the field's own kind. The two list-valued
  /// fields ([RuleValueKind.stringList]) are the reason this exists: their
  /// *field* kind is a list, but a membership operand names elements of that
  /// list, so the operand's elements are strings. Reading the field kind here
  /// would demand a list of lists, which is exactly the incoherence this
  /// indirection removes.
  static RuleValueKind _listElementKind(RuleValueKind kind) =>
      kind == RuleValueKind.stringList ? RuleValueKind.string : kind;

  static Object _scalar(Object? raw, RuleValueKind kind, String valuePath) {
    switch (kind) {
      case RuleValueKind.string:
        return _string(raw, valuePath);
      case RuleValueKind.stringList:
        return _stringList(raw, valuePath);
      case RuleValueKind.integer:
        if (raw is int) {
          return raw;
        }
        throw RuleSchemaException(
          code: RuleSchemaException.wrongType,
          path: valuePath,
          message: 'expected an integer literal, got ${_kindOf(raw)}',
        );
      case RuleValueKind.decimal:
        if (raw is num) {
          return raw;
        }
        throw RuleSchemaException(
          code: RuleSchemaException.wrongType,
          path: valuePath,
          message: 'expected a number literal, got ${_kindOf(raw)}',
        );
      case RuleValueKind.boolean:
        return _bool(raw, valuePath);
    }
  }

  static RuleAction _decodeAction(Object? raw, String actionPath) {
    final map = _map(raw, actionPath);
    final typePath = '$actionPath.${_K.type}';
    final type = _string(map[_K.type], typePath);
    switch (type) {
      case RuleActionTypes.allow:
        _checkKeys(map, actionPath, required: _K.bareActionRequired);
        return const AllowAction();
      case RuleActionTypes.continueRule:
        _checkKeys(map, actionPath, required: _K.bareActionRequired);
        return const ContinueAction();
      case RuleActionTypes.hide:
        _checkKeys(map, actionPath, required: _K.reasonActionRequired);
        return HideAction(
          reasonCode: _nonBlankString(
            map[_K.reasonCode],
            '$actionPath.${_K.reasonCode}',
          ),
        );
      case RuleActionTypes.collapse:
        _checkKeys(map, actionPath, required: _K.reasonActionRequired);
        return CollapseAction(
          reasonCode: _nonBlankString(
            map[_K.reasonCode],
            '$actionPath.${_K.reasonCode}',
          ),
        );
      case RuleActionTypes.maskMedia:
        _checkKeys(map, actionPath, required: _K.maskMediaActionRequired);
        return MaskMediaAction(
          mediaTypes: Set<MediaType>.unmodifiable(
            _mediaTypeList(
              map[_K.mediaTypes],
              '$actionPath.${_K.mediaTypes}',
            ),
          ),
        );
      case RuleActionTypes.skip:
        _checkKeys(map, actionPath, required: _K.skipActionRequired);
        return SkipAction(
          ruleGroup: _nonBlankString(
            map[_K.ruleGroup],
            '$actionPath.${_K.ruleGroup}',
          ),
        );
      case RuleActionTypes.setTag:
        _checkKeys(map, actionPath, required: _K.setTagActionRequired);
        return SetTagAction(
          tag: _nonBlankString(map[_K.tag], '$actionPath.${_K.tag}'),
        );
      case RuleActionTypes.setScore:
        _checkKeys(map, actionPath, required: _K.setScoreActionRequired);
        return SetScoreAction(score: _score(map[_K.score], actionPath));
      case RuleActionTypes.evaluate:
        _checkKeys(map, actionPath, required: _K.evaluateActionRequired);
        return EvaluateAction(
          operatorId: _nonBlankString(
            map[_K.operatorId],
            '$actionPath.${_K.operatorId}',
          ),
        );
      default:
        throw RuleSchemaException(
          code: RuleSchemaException.unknownActionType,
          path: typePath,
          message: 'unknown action type "$type"',
        );
    }
  }

  // ---------------------------------------------------------------- encoding

  static Map<String, Object?> _encodeNode(RuleNode node) => switch (node) {
    AllNode(:final children) => <String, Object?>{
      _K.type: RuleNodeTypes.all,
      _K.children: [for (final child in children) _encodeNode(child)],
    },
    AnyNode(:final children) => <String, Object?>{
      _K.type: RuleNodeTypes.any,
      _K.children: [for (final child in children) _encodeNode(child)],
    },
    NotNode(:final child) => <String, Object?>{
      _K.type: RuleNodeTypes.not,
      _K.child: _encodeNode(child),
    },
    OperatorNode(:final operatorId, :final inputs, :final config) =>
      <String, Object?>{
        _K.type: RuleNodeTypes.operator,
        _K.operatorId: operatorId,
        _K.inputs: _sortedNames(inputs.map((input) => input.name)),
        // Re-checked on the way out: a node built in Dart (or decoded by an
        // older build) must not be able to export a credential either.
        _K.config: _exportedConfig(config, '${_K.config}'),
      },
    CompareNode(
      :final field,
      :final operator,
      :final value,
      :final operatorId,
    ) =>
      <String, Object?>{
        _K.type: RuleNodeTypes.compare,
        _K.field: field.wireName,
        _K.op: operator.wireName,
        if (operatorId != null) _K.operatorId: operatorId,
        _K.value: value,
      },
  };

  static Map<String, Object?> _encodeAction(RuleAction action) =>
      switch (action) {
        AllowAction() => <String, Object?>{_K.type: RuleActionTypes.allow},
        ContinueAction() => <String, Object?>{
          _K.type: RuleActionTypes.continueRule,
        },
        HideAction(:final reasonCode) => <String, Object?>{
          _K.type: RuleActionTypes.hide,
          _K.reasonCode: reasonCode,
        },
        CollapseAction(:final reasonCode) => <String, Object?>{
          _K.type: RuleActionTypes.collapse,
          _K.reasonCode: reasonCode,
        },
        MaskMediaAction(:final mediaTypes) => <String, Object?>{
          _K.type: RuleActionTypes.maskMedia,
          _K.mediaTypes: _sortedNames(mediaTypes.map((type) => type.name)),
        },
        SkipAction(:final ruleGroup) => <String, Object?>{
          _K.type: RuleActionTypes.skip,
          _K.ruleGroup: ruleGroup,
        },
        SetTagAction(:final tag) => <String, Object?>{
          _K.type: RuleActionTypes.setTag,
          _K.tag: tag,
        },
        SetScoreAction(:final score) => <String, Object?>{
          _K.type: RuleActionTypes.setScore,
          _K.score: score,
        },
        EvaluateAction(:final operatorId) => <String, Object?>{
          _K.type: RuleActionTypes.evaluate,
          _K.operatorId: operatorId,
        },
      };

  static List<String> _sortedNames(Iterable<String> names) =>
      names.toList()..sort();

  // -------------------------------------------------------------- validation

  static Set<CompareOperator> _applicableOperators(RuleValueKind kind) =>
      switch (kind) {
        RuleValueKind.string => const <CompareOperator>{
          CompareOperator.equals,
          CompareOperator.notEquals,
          CompareOperator.contains,
          CompareOperator.notContains,
          CompareOperator.startsWith,
          CompareOperator.endsWith,
          CompareOperator.inList,
          CompareOperator.notInList,
        },
        RuleValueKind.stringList => const <CompareOperator>{
          CompareOperator.equals,
          CompareOperator.notEquals,
          CompareOperator.contains,
          CompareOperator.notContains,
          CompareOperator.inList,
          CompareOperator.notInList,
        },
        RuleValueKind.integer ||
        RuleValueKind.decimal => const <CompareOperator>{
          CompareOperator.equals,
          CompareOperator.notEquals,
          CompareOperator.greaterThan,
          CompareOperator.greaterOrEqual,
          CompareOperator.lessThan,
          CompareOperator.lessOrEqual,
          CompareOperator.inList,
          CompareOperator.notInList,
        },
        RuleValueKind.boolean => const <CompareOperator>{
          CompareOperator.equals,
          CompareOperator.notEquals,
        },
      };

  static bool _isNullable(RuleValueKind kind) =>
      kind == RuleValueKind.string || kind == RuleValueKind.decimal;

  static void _checkKeys(
    Map<String, Object?> map,
    String parentPath, {
    required Set<String> required,
    Set<String> optional = const <String>{},
  }) {
    for (final key in required) {
      if (!map.containsKey(key)) {
        throw RuleSchemaException(
          code: RuleSchemaException.missingField,
          path: '$parentPath.$key',
          message: 'required member "$key" is missing',
        );
      }
    }
    for (final key in map.keys) {
      if (required.contains(key) || optional.contains(key)) continue;
      throw RuleSchemaException(
        code: RuleSchemaException.unexpectedField,
        path: '$parentPath.$key',
        message: 'unknown member "$key" for this document shape',
      );
    }
  }

  static Map<String, Object?> _map(Object? raw, String valuePath) {
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) {
      final result = <String, Object?>{};
      for (final entry in raw.entries) {
        final key = entry.key;
        if (key is! String) {
          throw RuleSchemaException(
            code: RuleSchemaException.notAnObject,
            path: valuePath,
            message: 'object has a non-string key',
          );
        }
        result[key] = entry.value;
      }
      return result;
    }
    throw RuleSchemaException(
      code: RuleSchemaException.notAnObject,
      path: valuePath,
      message: 'expected an object, got ${_kindOf(raw)}',
    );
  }

  static List<Object?> _list(Object? raw, String valuePath) {
    if (raw is List<Object?>) return raw;
    if (raw is List) return List<Object?>.from(raw);
    throw RuleSchemaException(
      code: RuleSchemaException.wrongType,
      path: valuePath,
      message: 'expected a list, got ${_kindOf(raw)}',
    );
  }

  static String _string(Object? raw, String valuePath) {
    if (raw is String) return raw;
    throw RuleSchemaException(
      code: RuleSchemaException.wrongType,
      path: valuePath,
      message: 'expected a string, got ${_kindOf(raw)}',
    );
  }

  static String _nonBlankString(Object? raw, String valuePath) {
    final value = _string(raw, valuePath);
    if (value.trim().isEmpty) {
      throw RuleSchemaException(
        code: RuleSchemaException.blankValue,
        path: valuePath,
        message: 'must not be empty',
      );
    }
    return value;
  }

  static bool _bool(Object? raw, String valuePath) {
    if (raw is bool) return raw;
    throw RuleSchemaException(
      code: RuleSchemaException.wrongType,
      path: valuePath,
      message: 'expected a bool, got ${_kindOf(raw)}',
    );
  }

  static int _int(Object? raw, String valuePath) {
    if (raw is int) return raw;
    throw RuleSchemaException(
      code: RuleSchemaException.wrongType,
      path: valuePath,
      message: 'expected an integer, got ${_kindOf(raw)}',
    );
  }

  static List<String> _stringList(Object? raw, String valuePath) {
    final list = _list(raw, valuePath);
    return [
      for (var index = 0; index < list.length; index++)
        _string(list[index], '$valuePath[$index]'),
    ];
  }

  static List<ContentInput> _inputList(Object? raw, String valuePath) {
    final names = _stringList(raw, valuePath);
    return [
      for (var index = 0; index < names.length; index++)
        _byWireName(ContentInput.values, names[index]) ??
            (throw RuleSchemaException(
              code: RuleSchemaException.invalidValue,
              path: '$valuePath[$index]',
              message: 'unknown content input "${names[index]}"',
            )),
    ];
  }

  static List<MediaType> _mediaTypeList(Object? raw, String valuePath) {
    final names = _stringList(raw, valuePath);
    return [
      for (var index = 0; index < names.length; index++)
        _byWireName(MediaType.values, names[index]) ??
            (throw RuleSchemaException(
              code: RuleSchemaException.invalidValue,
              path: '$valuePath[$index]',
              message: 'unknown media type "${names[index]}"',
            )),
    ];
  }

  static Map<String, Object?> _jsonObject(Object? raw, String valuePath) {
    final map = _map(raw, valuePath);
    for (final entry in map.entries) {
      if (!_isJsonValue(entry.value)) {
        throw RuleSchemaException(
          code: RuleSchemaException.invalidValue,
          path: '$valuePath.${entry.key}',
          message:
              'config values must be JSON values, got '
              '${_kindOf(entry.value)}',
        );
      }
    }
    return map;
  }

  /// Words reserved for credential material.
  ///
  /// A member name is split into words first (see [_configWords]), so
  /// `apiKey`, `api_key`, `X-Api-Key` and `APIKEY` all yield the words
  /// `api` + `key` and all match the `api key` entry; `privateKey`,
  /// `signing_key` and `hidden-secret` match the corresponding entries.
  /// Matching whole words
  /// rather than substrings is what keeps this reservation off ordinary
  /// settings: `tokenizer`, `secretary` and `maxCookiesPerRun` are not
  /// credential members, so they are accepted.
  ///
  /// A member name is rejected when a reserved sequence appears anywhere in its
  /// word sequence, so `accessToken`, `x_api_key` and `headers` all fail while
  /// `tokenizer` and `headerless` do not. Header *containers* are reserved
  /// wholesale: no operator in this build consumes a header map, and a
  /// per-member check would let `headers: {"X-Custom-Auth": "..."}` through.
  static const List<List<String>> _reservedConfigWords = <List<String>>[
    <String>['api', 'key'],
    <String>['access', 'key'],
    <String>['private', 'key'],
    <String>['secret', 'key'],
    <String>['signing', 'key'],
    <String>['session', 'key'],
    // The same reservations in their run-together spellings, so an all-caps
    // `APIKEY` (one word after splitting) is caught like `apiKey` is.
    <String>['apikey'],
    <String>['accesskey'],
    <String>['privatekey'],
    <String>['secretkey'],
    <String>['signingkey'],
    <String>['sessionkey'],
    <String>['authheader'],
    <String>['password'],
    <String>['passwd'],
    <String>['passphrase'],
    <String>['secret'],
    <String>['token'],
    <String>['cookie'],
    <String>['authorization'],
    <String>['auth', 'header'],
    <String>['credential'],
    <String>['credentials'],
    <String>['bearer'],
    <String>['session', 'id'],
    // Names a secret *reference* uses. This build has no reference channel, so
    // a reference is refused exactly like the secret it would point at.
    <String>['secret', 'ref'],
    <String>['token', 'env'],
    <String>['secretref'],
    <String>['tokenenv'],
    <String>['sessionid'],
    // Transport-header containers. No operator in this build consumes one, so
    // reserving the container itself closes the gap a per-name check leaves:
    // `headers: {"X-Custom-Auth": "..."}` would otherwise import cleanly.
    <String>['header'],
    <String>['headers'],
    <String>['headermap'],
  ];

  /// Decodes a rule `config` block, rejecting credential-shaped member names.
  ///
  /// The rejection is on *names*, never on values, and the walk is exhaustive
  /// over maps and lists at any mixed depth: a nested header map
  /// (`{"headers": {"Cookie": "..."}}`) and a credential buried in a list of
  /// lists (`{"steps": [[{"apiKey": "..."}]]}`) are rejected exactly like a
  /// flat `cookie` member. Nothing about the offending value reaches the
  /// exception — only its JSON path — so a rejected import cannot echo a secret
  /// into a log or a UI dialog.
  static Map<String, Object?> _operatorConfig(Object? raw, String valuePath) {
    final config = _jsonObject(raw, valuePath);
    _rejectCredentialMembers(config, valuePath);
    return Map<String, Object?>.unmodifiable(config);
  }

  /// Encodes a rule `config` block, refusing to publish a credential.
  ///
  /// Decoding already rejects these, so this can only fire for a node built in
  /// Dart; it exists because export is the step that would write a secret to a
  /// file or a sync payload, and that has to be impossible rather than unlikely.
  static Map<String, Object?> _exportedConfig(
    Map<String, Object?> config,
    String valuePath,
  ) {
    if (config.isEmpty) return const <String, Object?>{};
    final copy = Map<String, Object?>.from(config);
    _rejectCredentialMembers(copy, valuePath);
    return copy;
  }

  /// Walks every value of a config block, rejecting reserved member names.
  ///
  /// The walk is uniform over the two JSON container shapes and descends through
  /// them at any mixed depth, so every one of these is rejected:
  ///
  ///     {apiKey: ...}                          map
  ///     {headers: {Cookie: ...}}               map in map
  ///     {endpoints: [{apiKey: ...}]}           map in list
  ///     {steps: [[{apiKey: ...}]]}             map in list in list
  ///     {a: [{b: [[[{c: [[{token: ...}]]}]]}]} arbitrary depth
  ///
  /// Handling only one List layer would leave the second shape's neighbour — a
  /// list nested directly in a list — unchecked, which is exactly how a
  /// credential used to survive both import and export.
  static void _rejectReservedConfigValues(Object? value, String valuePath) {
    // Iterative on purpose: the walk is unbounded in depth, and a rule document
    // is untrusted input, so a deeply nested config must be *inspected* rather
    // than turned into a stack overflow. An explicit work list also makes the
    // traversal order independent of the call stack, which keeps the reported
    // path deterministic for the same document.
    final pending = <(Object?, String)>[(value, valuePath)];
    while (pending.isNotEmpty) {
      final (current, path) = pending.removeLast();
      if (current is List) {
        for (var index = current.length - 1; index >= 0; index--) {
          pending.add((current[index], '$path[$index]'));
        }
        continue;
      }
      if (current is! Map) continue;
      final map = _map(current, path);
      final entries = map.entries.toList(growable: false);
      // Pushed last-in-first-out, so the walk visits members in document order
      // and the first reported violation is the first one an author would see.
      for (var index = entries.length - 1; index >= 0; index--) {
        final entry = entries[index];
        final memberPath = '$path.${entry.key}';
        if (_isReservedConfigName(entry.key)) {
          throw RuleSchemaException(
            code: RuleSchemaException.credentialConfig,
            path: memberPath,
            message:
                'operator config member "${entry.key}" is reserved for '
                'credential material; rule documents carry thresholds and '
                'selectors only',
          );
        }
        pending.add((entry.value, memberPath));
      }
    }
  }

  static void _rejectCredentialMembers(
    Map<String, Object?> map,
    String valuePath,
  ) => _rejectReservedConfigValues(map, valuePath);

  /// Whether a member name is a reserved credential name.
  ///
  /// A name matches when its word sequence starts with a reserved sequence, so
  /// both `token` and `accessToken` are rejected while `tokenizer` is not.
  static bool _isReservedConfigName(String name) {
    final words = _configWords(name);
    if (words.isEmpty) return false;
    for (final reserved in _reservedConfigWords) {
      if (reserved.length > words.length) continue;
      for (var start = 0; start + reserved.length <= words.length; start++) {
        var matched = true;
        for (var index = 0; index < reserved.length; index++) {
          if (words[start + index] != reserved[index]) {
            matched = false;
            break;
          }
        }
        if (matched) return true;
      }
    }
    return false;
  }

  /// Splits a member name into lower-case words.
  ///
  /// `X-Api-Key` -> `[x, api, key]`; `private_key` -> `[private, key]`;
  /// `maxInputLength` -> `[max, input, length]`. Separators are `-`, `_`, `.`
  /// and space. A lower-to-upper transition is a boundary, and so is the last
  /// capital of a run that is followed by a lower-case letter, which is what
  /// turns `APIKey` into `[api, key]` without splitting every capital letter.
  static List<String> _configWords(String name) {
    final words = <String>[];
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isEmpty) return;
      words.add(buffer.toString());
      buffer.clear();
    }

    bool isLower(int rune) => rune >= 0x61 && rune <= 0x7A;
    bool isUpper(int rune) => rune >= 0x41 && rune <= 0x5A;

    final runes = name.runes.toList(growable: false);
    for (var index = 0; index < runes.length; index++) {
      final rune = runes[index];
      final isSeparator =
          rune == 0x2D || rune == 0x5F || rune == 0x20 || rune == 0x2E;
      if (isSeparator) {
        flush();
        continue;
      }
      if (isUpper(rune) && !buffer.isEmpty) {
        final nextIsLower =
            index + 1 < runes.length && isLower(runes[index + 1]);
        if (isLower(runes[index - 1]) || nextIsLower) flush();
      }
      buffer.writeCharCode(isUpper(rune) ? rune + 0x20 : rune);
    }
    flush();
    return words;
  }

  /// Validates that [value] is built only from JSON types.
  ///
  /// Iterative, for the same reason as [_rejectReservedConfigValues]: a rule
  /// document is untrusted input and may nest arbitrarily deep, and a recursive
  /// predicate would answer that with a stack overflow instead of a verdict.
  static bool _isJsonValue(Object? value) {
    final pending = <Object?>[value];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (current == null ||
          current is String ||
          current is num ||
          current is bool) {
        continue;
      }
      if (current is List) {
        pending.addAll(current);
        continue;
      }
      if (current is Map) {
        for (final entry in current.entries) {
          if (entry.key is! String) return false;
          pending.add(entry.value);
        }
        continue;
      }
      return false;
    }
    return true;
  }

  static double _score(Object? raw, String valuePath) {
    if (raw is num) {
      final value = raw.toDouble();
      if (value.isFinite) return value;
    }
    throw RuleSchemaException(
      code: RuleSchemaException.invalidValue,
      path: valuePath,
      message: 'score must be a finite number, got ${_kindOf(raw)}',
    );
  }

  /// Resolves an enum from its wire name.
  ///
  /// [RuleField] and [CompareOperator] carry an explicit frozen wire name; the
  /// rest use their Dart name, which is why renaming one of those enum values is
  /// a wire-format change.
  static T? _byWireName<T extends Enum>(List<T> values, String wireName) {
    for (final value in values) {
      final String name = switch (value) {
        final RuleField field => field.wireName,
        final CompareOperator comparison => comparison.wireName,
        _ => value.name,
      };
      if (name == wireName) return value;
    }
    return null;
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
}

/// JSON member names of the rule document format.
abstract final class _K {
  static const String schemaVersion = 'schemaVersion';
  static const String migration = 'migration';
  static const String id = 'id';
  static const String enabled = 'enabled';
  static const String priority = 'priority';
  static const String group = 'group';
  static const String attributeViolation = 'attributeViolation';
  static const String when = 'when';
  static const String then = 'then';
  static const String unknownAction = 'unknownAction';
  static const String errorAction = 'errorAction';

  static const String type = 'type';
  static const String children = 'children';
  static const String child = 'child';
  static const String operatorId = 'operatorId';
  static const String inputs = 'inputs';
  static const String config = 'config';
  static const String field = 'field';
  static const String op = 'op';
  static const String value = 'value';
  static const String reasonCode = 'reasonCode';
  static const String mediaTypes = 'mediaTypes';
  static const String ruleGroup = 'ruleGroup';
  static const String tag = 'tag';
  static const String score = 'score';

  static const Set<String> ruleRequired = <String>{
    schemaVersion,
    id,
    when,
    then,
    unknownAction,
    errorAction,
  };

  static const Set<String> ruleOptional = <String>{
    migration,
    enabled,
    priority,
    group,
    attributeViolation,
  };

  static const Set<String> logicalNodeRequired = <String>{type, children};

  static const Set<String> notNodeRequired = <String>{type, child};

  static const Set<String> operatorNodeRequired = <String>{type, operatorId};

  static const Set<String> operatorNodeOptional = <String>{inputs, config};

  static const Set<String> compareNodeRequired = <String>{
    type,
    field,
    op,
    value,
  };

  static const Set<String> compareNodeOptional = <String>{operatorId};

  static const Set<String> bareActionRequired = <String>{type};

  static const Set<String> reasonActionRequired = <String>{type, reasonCode};

  static const Set<String> maskMediaActionRequired = <String>{type, mediaTypes};

  static const Set<String> skipActionRequired = <String>{type, ruleGroup};

  static const Set<String> setTagActionRequired = <String>{type, tag};

  static const Set<String> setScoreActionRequired = <String>{type, score};

  static const Set<String> evaluateActionRequired = <String>{type, operatorId};
}
