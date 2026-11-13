import 'dart:convert';

import 'package:PiliPlus/services/content_guard/storage/content_guard_storage_keys.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';

/// Outcome of a repository read.
///
/// [Miss] is the only "not there" answer; a value that exists but cannot be
/// used is [Corrupt], never a silent null.
sealed class RepositoryResult<T> {
  const RepositoryResult();

  /// Value of an [Ok], otherwise `null`.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    _ => null,
  };
}

/// The entry was read and is valid.
final class Ok<T> extends RepositoryResult<T> {
  const Ok(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Ok<T>, value);

  @override
  String toString() => 'Ok(value: $value)';
}

/// Nothing is stored for this id — or what is stored belongs to another
/// schema version and must not be resurrected.
final class Miss<T> extends RepositoryResult<T> {
  const Miss();

  @override
  String toString() => 'Miss()';
}

/// Something is stored, but it cannot be decoded into a usable object.
final class Corrupt<T> extends RepositoryResult<T> {
  const Corrupt(this.reason);

  final String reason;

  @override
  String toString() => 'Corrupt(reason: $reason)';
}

/// JSON-object repository over a [KeyValueStore], scoped to one
/// domain + account scope.
///
/// Every write embeds [_schemaVersionField] and [_updatedAtField]; [read]
/// treats a version mismatch as a [Miss] so stale data is never handed to
/// callers. Reads never throw: a bad value is reported as [Corrupt].
final class JsonRepository {
  JsonRepository(
    this._store, {
    required this.domain,
    required this.accountScopeId,
    required this.schemaVersion,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _systemNowMs;

  static const String schemaVersionField = '_schemaVersion';
  static const String updatedAtField = '_updatedAtMs';

  final KeyValueStore _store;
  final String domain;
  final String accountScopeId;
  final int schemaVersion;
  final int Function() _nowMs;

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Storage key of [id] inside this domain + scope.
  String keyOf(String id) =>
      ContentGuardStorageKeys.entry(domain, accountScopeId, id);

  /// Encodes [json] with the schema/update envelope and stores it.
  ///
  /// Envelope fields passed inside [json] are overwritten, never trusted.
  Future<void> write(String id, Map<String, Object?> json) async {
    final payload = <String, Object?>{
      for (final entry in json.entries)
        if (entry.key != schemaVersionField && entry.key != updatedAtField)
          entry.key: entry.value,
      schemaVersionField: schemaVersion,
      updatedAtField: _nowMs(),
    };
    await _store.put(keyOf(id), jsonEncode(payload));
  }

  /// Reads [id]. Schema mismatch and absent ids are [Miss]; anything that
  /// exists but cannot be decoded is [Corrupt].
  RepositoryResult<Map<String, Object?>> read(String id) {
    final key = keyOf(id);
    Object? raw;
    try {
      if (!_store.containsKey(key)) {
        return const Miss<Map<String, Object?>>();
      }
      raw = _store.get(key);
    } catch (error) {
      return Corrupt<Map<String, Object?>>('store read failed: $error');
    }
    if (raw is! String) {
      return Corrupt<Map<String, Object?>>(
        'stored value is ${_kindOf(raw)}, expected a JSON string',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      return Corrupt<Map<String, Object?>>('invalid JSON: ${error.message}');
    }
    if (decoded is! Map) {
      return Corrupt<Map<String, Object?>>(
        'decoded JSON is ${_kindOf(decoded)}, expected an object',
      );
    }
    final map = <String, Object?>{};
    for (final entry in decoded.entries) {
      final name = entry.key;
      if (name is! String) {
        return const Corrupt<Map<String, Object?>>(
          'decoded JSON has a non-string key',
        );
      }
      map[name] = entry.value;
    }
    final version = map[schemaVersionField];
    if (version is! int) {
      return const Corrupt<Map<String, Object?>>(
        'missing or non-integer $schemaVersionField',
      );
    }
    if (version != schemaVersion) {
      return const Miss<Map<String, Object?>>();
    }
    return Ok<Map<String, Object?>>(map);
  }

  /// Removes [id]; absent ids are a no-op.
  Future<void> delete(String id) => _store.delete(keyOf(id));

  /// Ids stored under this domain + account scope, sorted. Other scopes and
  /// other domains are invisible here.
  List<String> ids() {
    final result = <String>[];
    for (final key in _store.keys()) {
      final id = ContentGuardStorageKeys.idOf(domain, accountScopeId, key);
      if (id != null) {
        result.add(id);
      }
    }
    result.sort();
    return result;
  }

  /// Decoded payload with the envelope fields removed.
  static Map<String, Object?> payloadOf(Map<String, Object?> stored) =>
      <String, Object?>{
        for (final entry in stored.entries)
          if (entry.key != schemaVersionField && entry.key != updatedAtField)
            entry.key: entry.value,
      };

  static int? updatedAtMsOf(Map<String, Object?> stored) {
    final value = stored[updatedAtField];
    return value is int ? value : null;
  }

  static int? schemaVersionOf(Map<String, Object?> stored) {
    final value = stored[schemaVersionField];
    return value is int ? value : null;
  }

  static String _kindOf(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is String) {
      return 'a string';
    }
    if (value is num) {
      return 'a number';
    }
    if (value is bool) {
      return 'a bool';
    }
    if (value is List) {
      return 'a list';
    }
    if (value is Map) {
      return 'a map';
    }
    return 'an unsupported value';
  }
}
