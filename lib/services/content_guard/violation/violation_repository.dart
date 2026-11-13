/// Persistence for the violation ledger, built on the existing storage layer.
///
/// Nothing here is new machinery: [JsonRepository] already encodes the
/// schema-version / updated-at envelope, treats a stale schema as a miss and
/// reports an unusable value as [Corrupt]. This file only adds the two things
/// that are specific to violations:
///
/// * **Key shape.** A comment id is platform data and may legitimately contain
///   the storage key separator, so ids are escaped through [StorageIdCodec]
///   before they become part of a key. Escaping is reversible, so
///   [ViolationRepository.commentIds] can hand back the ids it stored.
/// * **Account assertion.** [ViolationRepository.read] refuses a record whose
///   embedded account scope is not the repository's, which turns a copy/paste
///   of a key across scopes into a [Corrupt] instead of a cross-account leak.
///
/// Most ContentGuard storage, with one structural exception:
///
/// * **Corrections live in their own domain.** A revoked violation leaves a
///   [ViolationCorrection] tombstone ([ViolationCorrectionRepository]). It cannot
///   share the record domain: key ids are reversible encodings of comment ids,
///   so a comment id that happens to look like a tombstone key would be able to
///   overwrite a correction with an entry — silently lifting the correction. A
///   separate domain gives each shape its own id space while the account scope
///   stays part of every key, exactly as for records.
///
/// [InMemoryKeyValueStore] is the test/store double: same contract, no Hive, no
/// Flutter binding.
library;

import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/storage/content_guard_storage_keys.dart';
import 'package:PiliPlus/services/content_guard/storage/json_repository.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:PiliPlus/services/content_guard/violation/violation_record.dart';

/// Escapes an arbitrary id so it is safe as one [ContentGuardStorageKeys]
/// segment.
///
/// Only the separator itself and the escape character are encoded, so a plain
/// comment id stays readable in the box while a dotted one cannot forge a key
/// path.
abstract final class StorageIdCodec {
  static const int _escapeRune = 0x25; // '%'
  static const int _separatorRune =
      0x2E; // '.' — ContentGuardStorageKeys.separator

  /// Separator used by [encodePair]; equals the storage key separator, which the
  /// outer [encode] escapes.
  static const String separator = ContentGuardStorageKeys.separator;

  /// Encodes [raw]. Throws [ArgumentError] for a blank id: an empty segment
  /// would collapse two different entries onto one key.
  static String encode(String raw) {
    if (raw.isEmpty) {
      throw ArgumentError.value(raw, 'raw', 'must not be empty');
    }
    final buffer = StringBuffer();
    for (final rune in raw.runes) {
      if (rune == _escapeRune || rune == _separatorRune) {
        buffer.write('%');
        buffer.write(rune.toRadixString(16).toUpperCase().padLeft(2, '0'));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// Joins two escaped ids into one key segment that is still dot-free.
  ///
  /// The pair separator is itself escaped away, so `('a.b', 'c')` and
  /// `('a', 'b.c')` stay two different segments — the collision a naive
  /// `a + '.' + b` would produce.
  static String encodePair(String first, String second) =>
      encode('${encode(first)}$separator${encode(second)}');

  /// Reverses [encodePair]; returns null unless the segment holds exactly one
  /// separator, i.e. unless it really was produced by [encodePair].
  static (String, String)? decodePair(String encoded) {
    final joined = decode(encoded);
    final index = joined.indexOf(separator);
    if (index < 0 || joined.indexOf(separator, index + 1) >= 0) {
      return null;
    }
    return (
      decode(joined.substring(0, index)),
      decode(joined.substring(index + 1)),
    );
  }

  /// Reverses [encode]; returns the input unchanged when it holds no escapes.
  static String decode(String encoded) {
    if (!encoded.contains('%')) {
      return encoded;
    }
    final runes = encoded.runes.toList();
    final buffer = StringBuffer();
    for (var i = 0; i < runes.length; i++) {
      final rune = runes[i];
      if (rune != _escapeRune) {
        buffer.writeCharCode(rune);
        continue;
      }
      if (i + 2 >= runes.length) {
        return encoded;
      }
      final hex = String.fromCharCodes(<int>[runes[i + 1], runes[i + 2]]);
      final value = int.tryParse(hex, radix: 16);
      if (value == null) {
        return encoded;
      }
      buffer.writeCharCode(value);
      i += 2;
    }
    return buffer.toString();
  }
}

/// String-keyed store held in a map. Test double, and the shape every
/// ContentGuard repository is written against.
///
/// [put] applies its write synchronously before returning its future, so a
/// synchronous [get] immediately after `await store.put(...)` observes the
/// value without any scheduler cooperation.
final class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, Object?>? initial]) {
    if (initial != null) {
      _data.addAll(initial);
    }
  }

  final Map<String, Object?> _data = <String, Object?>{};

  /// Number of stored keys; useful in checks and debugging.
  int get length => _data.length;

  @override
  Object? get(String key) => _data[key];

  @override
  Future<void> put(String key, Object? value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Iterable<String> keys() => List<String>.of(_data.keys);

  @override
  bool containsKey(String key) => _data.containsKey(key);

  @override
  String toString() => 'InMemoryKeyValueStore(${_data.length} keys)';
}

/// Violation records, keyed by comment id, scoped to one account.
///
/// ## Which identity the keys use
///
/// [durableScopeId] — the account's **persistence** identity — not the
/// credential-generation request identity. A violation the user already saw, and
/// the correction they recorded against it, must survive a re-login, an access
/// key rotation or a device change of the same account; keying by the rotating
/// digest is what used to orphan them. The request identity stays in the
/// transient layers (pipeline, bridge, presenter store, decision cache, traces).
final class ViolationRepository {
  ViolationRepository(
    KeyValueStore store, {
    required AccountScope account,
    int schemaVersion = 1,
    int Function()? nowMs,
  }) : _repository = JsonRepository(
         store,
         domain: ContentGuardStorageKeys.violations,
         accountScopeId: account.durableId,
         schemaVersion: schemaVersion,
         nowMs: nowMs,
       ),
       durableScopeId = account.durableId;

  /// Storage domain this repository owns.
  static const String domain = ContentGuardStorageKeys.violations;

  final JsonRepository _repository;

  /// Durable account namespace every key of this repository lives under.
  final String durableScopeId;

  /// Alias of [durableScopeId], kept because this field has always named the
  /// namespace a stored record's [ViolationKey.accountScopeId] must carry.
  ///
  /// It is the **durable** identity now; use [durableScopeId] when the
  /// distinction matters.
  String get accountScopeId => durableScopeId;

  /// Storage id of [commentId] — the key segment, not the comment id.
  static String storageIdOf(String commentId) =>
      StorageIdCodec.encode(commentId);

  /// Reads the record of [commentId].
  RepositoryResult<ViolationRecord> read(String commentId) {
    final stored = _repository.read(storageIdOf(commentId));
    return switch (stored) {
      Ok<Map<String, Object?>>(:final value) => _decode(commentId, value),
      Miss<Map<String, Object?>>() => const Miss<ViolationRecord>(),
      Corrupt<Map<String, Object?>>(:final reason) => Corrupt<ViolationRecord>(
        reason,
      ),
    };
  }

  /// Writes [record] verbatim; the caller decides what a merge looks like.
  Future<void> write(ViolationRecord record) {
    if (record.key.accountScopeId != durableScopeId) {
      throw ArgumentError.value(
        record.key.accountScopeId,
        'record.key.accountScopeId',
        'does not match this repository scope',
      );
    }
    return _repository.write(storageIdOf(record.commentId), record.toJson());
  }

  /// Removes [commentId]; absent ids are a no-op.
  Future<void> delete(String commentId) =>
      _repository.delete(storageIdOf(commentId));

  /// Comment ids stored in this scope, sorted. Ids escaped by
  /// [StorageIdCodec] are decoded back.
  List<String> commentIds() {
    final ids = _repository.ids();
    final result = <String>[for (final id in ids) StorageIdCodec.decode(id)];
    result.sort();
    return result;
  }

  RepositoryResult<ViolationRecord> _decode(
    String commentId,
    Map<String, Object?> stored,
  ) {
    final record = ViolationRecord.fromJson(JsonRepository.payloadOf(stored));
    if (record == null) {
      return const Corrupt<ViolationRecord>('violation record is unreadable');
    }
    if (record.key.commentId != commentId) {
      return const Corrupt<ViolationRecord>(
        'stored comment id does not match its key',
      );
    }
    if (record.key.accountScopeId != durableScopeId) {
      return const Corrupt<ViolationRecord>(
        'stored record belongs to another account scope',
      );
    }
    return Ok<ViolationRecord>(record);
  }
}

/// Correction tombstones, keyed by comment id, scoped to one account.
///
/// Same storage layer, same account assertion, same defensive decoding as
/// [ViolationRepository]; only the domain differs (see the library doc). A
/// tombstone is written before the record it replaces is deleted, so a crash
/// between the two writes leaves "corrected but still listed" — never "deleted
/// and forgotten", which would let the next evaluate() recreate the accusation.
final class ViolationCorrectionRepository {
  ViolationCorrectionRepository(
    KeyValueStore store, {
    required AccountScope account,
    int schemaVersion = 1,
    int Function()? nowMs,
  }) : _repository = JsonRepository(
         store,
         domain: domain,
         accountScopeId: account.durableId,
         schemaVersion: schemaVersion,
         nowMs: nowMs,
       ),
       durableScopeId = account.durableId;

  /// Storage domain the tombstones of this layer own.
  ///
  /// Derived from [ContentGuardStorageKeys.violations] so the two domains sit
  /// next to each other in the box; the account scope is added by
  /// [ContentGuardStorageKeys.entry] like every other ContentGuard key.
  static const String domain =
      ContentGuardStorageKeys.violations + 'Corrections';

  final JsonRepository _repository;

  /// Durable account namespace every tombstone of this repository lives under.
  ///
  /// Same reasoning as [ViolationRepository]: a correction is a user decision, so
  /// it must survive a credential rotation of the account that made it.
  final String durableScopeId;

  /// Alias of [durableScopeId] — the namespace a stored
  /// [ViolationCorrection.key] carries.
  String get accountScopeId => durableScopeId;

  /// Storage id of [commentId].
  static String storageIdOf(String commentId) =>
      StorageIdCodec.encode(commentId);

  /// Reads the correction of [commentId], or a [Miss] when the comment was never
  /// corrected. A stored value that is not a usable tombstone is [Corrupt] —
  /// callers must decide what that means, never treat it as "not corrected".
  RepositoryResult<ViolationCorrection> read(String commentId) {
    final stored = _repository.read(storageIdOf(commentId));
    return switch (stored) {
      Ok<Map<String, Object?>>(:final value) => _decode(commentId, value),
      Miss<Map<String, Object?>>() => const Miss<ViolationCorrection>(),
      Corrupt<Map<String, Object?>>(:final reason) =>
        Corrupt<ViolationCorrection>(
          reason,
        ),
    };
  }

  /// Writes [correction] verbatim; the caller decides what a merge looks like.
  Future<void> write(ViolationCorrection correction) {
    if (correction.key.accountScopeId != durableScopeId) {
      throw ArgumentError.value(
        correction.key.accountScopeId,
        'correction.key.accountScopeId',
        'does not match this repository scope',
      );
    }
    return _repository.write(
      storageIdOf(correction.commentId),
      correction.toJson(),
    );
  }

  /// Removes the correction of [commentId]; absent ids are a no-op.
  Future<void> delete(String commentId) =>
      _repository.delete(storageIdOf(commentId));

  /// Comment ids with a stored correction in this scope, sorted.
  List<String> commentIds() {
    final result = <String>[
      for (final id in _repository.ids()) StorageIdCodec.decode(id),
    ];
    result.sort();
    return result;
  }

  /// Every decodable correction of this scope, ordered by comment id.
  ///
  /// A value that cannot be decoded is skipped here; [read] is the single-key
  /// path that lets the ledger refuse to treat it as "not corrected".
  List<ViolationCorrection> list() {
    final corrections = <ViolationCorrection>[];
    for (final commentId in commentIds()) {
      final correction = read(commentId).valueOrNull;
      if (correction != null) {
        corrections.add(correction);
      }
    }
    return List<ViolationCorrection>.unmodifiable(corrections);
  }

  RepositoryResult<ViolationCorrection> _decode(
    String commentId,
    Map<String, Object?> stored,
  ) {
    final payload = JsonRepository.payloadOf(stored);
    if (!isCorrectionPayload(payload)) {
      return const Corrupt<ViolationCorrection>(
        'stored value is a violation record, not a correction',
      );
    }
    final correction = ViolationCorrection.fromJson(payload);
    if (correction == null) {
      return const Corrupt<ViolationCorrection>('correction is unreadable');
    }
    if (correction.commentId != commentId) {
      return const Corrupt<ViolationCorrection>(
        'stored comment id does not match its key',
      );
    }
    if (correction.key.accountScopeId != durableScopeId) {
      return const Corrupt<ViolationCorrection>(
        'stored correction belongs to another account scope',
      );
    }
    return Ok<ViolationCorrection>(correction);
  }
}
