import 'dart:convert';

import 'package:PiliPlus/services/content_guard/storage/cache_eviction_policy.dart';
import 'package:PiliPlus/services/content_guard/storage/content_guard_storage_keys.dart';
import 'package:PiliPlus/services/content_guard/storage/json_repository.dart';
import 'package:PiliPlus/services/content_guard/storage/key_value_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Map-backed [KeyValueStore]. No Hive, no Flutter binding.
final class _FakeKeyValueStore implements KeyValueStore {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  Object? get(String key) => values[key];

  @override
  Future<void> put(String key, Object? value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Iterable<String> keys() => values.keys.toList(growable: false);

  @override
  bool containsKey(String key) => values.containsKey(key);
}

const String _scopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _scopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

JsonRepository _repo(
  KeyValueStore store, {
  String scope = _scopeA,
  int schemaVersion = 1,
  int Function()? nowMs,
}) => JsonRepository(
  store,
  domain: ContentGuardStorageKeys.decisions,
  accountScopeId: scope,
  schemaVersion: schemaVersion,
  nowMs: nowMs,
);

void main() {
  group('ContentGuardStorageKeys', () {
    test('builds namespaced keys', () {
      expect(
        ContentGuardStorageKeys.entry(
          ContentGuardStorageKeys.rules,
          _scopeA,
          'r1',
        ),
        'contentGuard.rules.$_scopeA.r1',
      );
      expect(
        ContentGuardStorageKeys.domain(
          ContentGuardStorageKeys.models,
          _scopeA,
        ),
        'contentGuard.models.$_scopeA',
      );
      expect(
        ContentGuardStorageKeys.prefix(
          ContentGuardStorageKeys.models,
          _scopeA,
        ),
        'contentGuard.models.$_scopeA.',
      );
      expect(
        ContentGuardStorageKeys.idOf(
          ContentGuardStorageKeys.rules,
          _scopeA,
          'contentGuard.rules.$_scopeA.r1',
        ),
        'r1',
      );
      expect(
        ContentGuardStorageKeys.idOf(
          ContentGuardStorageKeys.rules,
          _scopeA,
          'contentGuard.rules.$_scopeB.r1',
        ),
        isNull,
      );
    });

    test('rejects segments that break the key shape', () {
      expect(
        () => ContentGuardStorageKeys.entry('rules', _scopeA, ''),
        throwsArgumentError,
      );
      expect(
        () => ContentGuardStorageKeys.entry('rules.x', _scopeA, 'id'),
        throwsArgumentError,
      );
    });
  });

  group('account isolation', () {
    test('two scopes never collide', () async {
      final store = _FakeKeyValueStore();
      final repoA = _repo(store);
      final repoB = _repo(store, scope: _scopeB);

      await repoA.write('d1', <String, Object?>{
        'verdict': 'block',
        'owner': 'A',
      });
      await repoB.write('d1', <String, Object?>{
        'verdict': 'allow',
        'owner': 'B',
      });

      expect(store.values.length, 2);
      expect(repoA.read('d1').valueOrNull?['owner'], 'A');
      expect(repoB.read('d1').valueOrNull?['owner'], 'B');
    });

    test('ids() only lists entries of this domain and scope', () async {
      final store = _FakeKeyValueStore();
      final repoA = _repo(store);
      final repoB = _repo(store, scope: _scopeB);
      final otherDomain = JsonRepository(
        store,
        domain: ContentGuardStorageKeys.suggestions,
        accountScopeId: _scopeA,
        schemaVersion: 1,
      );

      await repoA.write('d1', <String, Object?>{'n': 1});
      await repoA.write('d2', <String, Object?>{'n': 2});
      await repoB.write('d3', <String, Object?>{'n': 3});
      await otherDomain.write('d4', <String, Object?>{'n': 4});
      store.values['unrelated.key'] = 'x';

      expect(repoA.ids(), <String>['d1', 'd2']);
      expect(repoB.ids(), <String>['d3']);
      expect(otherDomain.ids(), <String>['d4']);
    });
  });

  group('JsonRepository', () {
    test('round-trips JSON with the envelope', () async {
      final store = _FakeKeyValueStore();
      final repo = _repo(store, nowMs: () => 1700000000000);

      await repo.write('d1', <String, Object?>{
        'verdict': 'block',
        'score': 0.9,
        'tags': <String>['spam', 'ad'],
        'nested': <String, Object?>{'k': true},
      });

      final result = repo.read('d1');
      expect(result, isA<Ok<Map<String, Object?>>>());
      final value = result.valueOrNull!;
      expect(value['verdict'], 'block');
      expect(value['score'], 0.9);
      expect(value['tags'], <String>['spam', 'ad']);
      expect(value['nested'], <String, Object?>{'k': true});
      expect(value[JsonRepository.schemaVersionField], 1);
      expect(value[JsonRepository.updatedAtField], 1700000000000);
      expect(
        JsonRepository.payloadOf(value).containsKey('_updatedAtMs'),
        isFalse,
      );

      await repo.delete('d1');
      expect(repo.read('d1'), isA<Miss<Map<String, Object?>>>());
      expect(repo.ids(), isEmpty);
    });

    test('schema version bump makes read a miss', () async {
      final store = _FakeKeyValueStore();
      final v1 = _repo(store, schemaVersion: 1);
      await v1.write('d1', <String, Object?>{'verdict': 'block'});
      expect(v1.read('d1'), isA<Ok<Map<String, Object?>>>());

      final v2 = _repo(store, schemaVersion: 2);
      final bumped = v2.read('d1');
      expect(bumped, isA<Miss<Map<String, Object?>>>());
      expect(bumped.valueOrNull, isNull);

      // The stale value is still on disk; a miss must not read as clean data.
      await v2.write('d1', <String, Object?>{'verdict': 'allow'});
      expect(v2.read('d1').valueOrNull?['verdict'], 'allow');
      expect(v2.read('d1').valueOrNull?['_schemaVersion'], 2);
    });

    test('corrupt values are reported, never silently clean', () async {
      final store = _FakeKeyValueStore();
      final repo = _repo(store);
      final key = repo.keyOf('broken');

      store.values[key] = 'not json at all';
      expect(repo.read('broken'), isA<Corrupt<Map<String, Object?>>>());

      store.values[key] = jsonEncode(<String>['a', 'b']);
      expect(repo.read('broken'), isA<Corrupt<Map<String, Object?>>>());

      store.values[key] = jsonEncode(<String, Object?>{'verdict': 'block'});
      expect(repo.read('broken'), isA<Corrupt<Map<String, Object?>>>());

      store.values[key] = 42;
      expect(repo.read('broken'), isA<Corrupt<Map<String, Object?>>>());

      // A corrupt entry is still a miss for callers that only ask "usable?".
      expect(repo.read('broken').valueOrNull, isNull);
      expect(repo.ids(), <String>['broken']);
    });
  });

  group('CacheEvictionPolicy', () {
    test('TTL expiry follows the injected clock', () async {
      final store = _FakeKeyValueStore();
      var now = 1000000;
      final repo = _repo(store, nowMs: () => now);
      const policy = CacheEvictionPolicy(
        ttl: Duration(minutes: 5),
        capacity: 100,
      );

      await repo.write('d1', <String, Object?>{'verdict': 'block'});
      final meta = CacheEntryMeta.fresh(
        updatedAtMs: JsonRepository.updatedAtMsOf(
          repo.read('d1').valueOrNull!,
        )!,
        schemaVersion: 1,
      );

      expect(policy.isExpired(meta, now + 1), isFalse);
      expect(
        policy.isExpired(
          meta,
          now + const Duration(minutes: 5).inMilliseconds - 1,
        ),
        isFalse,
      );
      now += const Duration(minutes: 5).inMilliseconds;
      expect(policy.isExpired(meta, now), isTrue);
      expect(
        policy.selectEvictions(<String, CacheEntryMeta>{'d1': meta}, now),
        <String>['d1'],
      );
    });

    test('capacity evicts least-recently-used first', () {
      const policy = CacheEvictionPolicy(ttl: Duration(hours: 1), capacity: 2);
      final entries = <String, CacheEntryMeta>{
        'a': const CacheEntryMeta(
          updatedAtMs: 1,
          schemaVersion: 1,
          lastAccessMs: 40,
        ),
        'b': const CacheEntryMeta(
          updatedAtMs: 2,
          schemaVersion: 1,
          lastAccessMs: 10,
        ),
        'c': const CacheEntryMeta(
          updatedAtMs: 3,
          schemaVersion: 1,
          lastAccessMs: 30,
        ),
        'd': const CacheEntryMeta(
          updatedAtMs: 4,
          schemaVersion: 1,
          lastAccessMs: 20,
        ),
      };
      expect(
        policy.selectEvictions(entries, 100),
        <String>['b', 'd'],
      );
      expect(policy.selectEvictions(entries, 10000000), <String>[
        'a',
        'b',
        'c',
        'd',
      ]);
    });

    test('expired entries go before capacity victims', () {
      const policy = CacheEvictionPolicy(
        ttl: Duration(seconds: 10),
        capacity: 2,
      );
      final entries = <String, CacheEntryMeta>{
        'old': const CacheEntryMeta(
          updatedAtMs: 0,
          schemaVersion: 1,
          lastAccessMs: 5,
        ),
        'a': const CacheEntryMeta(
          updatedAtMs: 1000,
          schemaVersion: 1,
          lastAccessMs: 1,
        ),
        'b': const CacheEntryMeta(
          updatedAtMs: 1000,
          schemaVersion: 1,
          lastAccessMs: 2,
        ),
        'c': const CacheEntryMeta(
          updatedAtMs: 1000,
          schemaVersion: 1,
          lastAccessMs: 3,
        ),
      };
      // 'old' is the only entry past the 10s TTL at now=10000; the three
      // fresh ones are then trimmed to `capacity` least-recently-used, so 'a'
      // (lastAccess 1) goes too.
      expect(policy.selectEvictions(entries, 10000), <String>['old', 'a']);
    });

    test('detects schema-version staleness', () {
      const policy = CacheEvictionPolicy(ttl: Duration(hours: 1), capacity: 10);
      const meta = CacheEntryMeta(
        updatedAtMs: 0,
        schemaVersion: 3,
        lastAccessMs: 0,
      );
      expect(policy.isVersionStale(meta, 3), isFalse);
      expect(policy.isVersionStale(meta, 4), isTrue);
      expect(
        policy.selectVersionStale(<String, CacheEntryMeta>{
          'stale': meta,
          'fresh': const CacheEntryMeta(
            updatedAtMs: 0,
            schemaVersion: 4,
            lastAccessMs: 0,
          ),
        }, 4),
        <String>['stale'],
      );
    });
  });
}
