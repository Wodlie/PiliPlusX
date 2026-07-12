import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/utils/lru_cache.dart';

void main() {
  group('LruCache', () {
    test('insert 501 entries evicts oldest, keeps 500', () {
      final cache = LruCache<String, String>();
      for (var i = 0; i <= 500; i++) {
        cache['$i'] = '$i';
      }
      expect(cache.length, 500);
      // oldest key "0" should be evicted
      expect(cache.containsKey('0'), false);
      // newest key "500" should be present
      expect(cache['500'], '500');
    });

    test('access order: reading a key moves it to most-recently-used', () {
      final cache = LruCache<String, String>(maxSize: 3);
      cache['a'] = 'a';
      cache['b'] = 'b';
      cache['c'] = 'c';

      // read "a" — moves it to most-recently-used
      expect(cache['a'], 'a');

      // insert "d" — should evict "b" (now the oldest)
      cache['d'] = 'd';

      expect(cache.length, 3);
      expect(cache.containsKey('a'), true); // a was accessed recently
      expect(cache.containsKey('b'), false); // b is the least recently used
      expect(cache.containsKey('c'), true);
      expect(cache.containsKey('d'), true);
    });

    test('remove key decreases length', () {
      final cache = LruCache<String, String>(maxSize: 5);
      cache['a'] = 'a';
      cache['b'] = 'b';
      cache['c'] = 'c';
      expect(cache.length, 3);

      cache.remove('b');
      expect(cache.length, 2);
      expect(cache.containsKey('a'), true);
      expect(cache.containsKey('b'), false);
      expect(cache.containsKey('c'), true);
    });

    test('clear resets length to 0', () {
      final cache = LruCache<String, String>(maxSize: 5);
      cache['a'] = 'a';
      cache['b'] = 'b';
      cache.clear();
      expect(cache.length, 0);
      expect(cache.containsKey('a'), false);
    });

    test('overwrite existing key moves it to most-recently-used', () {
      final cache = LruCache<String, String>(maxSize: 3);
      cache['a'] = 'a';
      cache['b'] = 'b';
      cache['c'] = 'c';

      // overwrite "a" — acts as access, moves to most-recently-used
      cache['a'] = 'a_updated';

      // insert "d" — should evict "b" (oldest), not "a"
      cache['d'] = 'd';

      expect(cache.length, 3);
      expect(cache.containsKey('a'), true);
      expect(cache.containsKey('b'), false);
      expect(cache.containsKey('c'), true);
      expect(cache.containsKey('d'), true);
      expect(cache['a'], 'a_updated');
    });

    test('maxSize=1 evicts immediately on second insert', () {
      final cache = LruCache<String, String>(maxSize: 1);
      cache['a'] = 'a';
      expect(cache.length, 1);
      expect(cache['a'], 'a');

      cache['b'] = 'b';
      expect(cache.length, 1);
      expect(cache.containsKey('a'), false);
      expect(cache['b'], 'b');
    });

    test('empty cache returns null on read', () {
      final cache = LruCache<String, String>(maxSize: 5);
      expect(cache['nonexistent'], null);
      expect(cache.length, 0);
    });

    test('single entry is retrievable', () {
      final cache = LruCache<String, String>(maxSize: 5);
      cache['key'] = 'value';
      expect(cache['key'], 'value');
      expect(cache.length, 1);
    });

    test('containsKey works correctly', () {
      final cache = LruCache<String, String>(maxSize: 5);
      expect(cache.containsKey('x'), false);
      cache['x'] = 'x';
      expect(cache.containsKey('x'), true);
      cache.remove('x');
      expect(cache.containsKey('x'), false);
    });

    test('remove non-existent key does nothing', () {
      final cache = LruCache<String, String>(maxSize: 5);
      cache['a'] = 'a';
      cache.remove('nonexistent');
      expect(cache.length, 1);
      expect(cache['a'], 'a');
    });

    test('value can be null (V? semantics)', () {
      final cache = LruCache<String, String?>(maxSize: 5);
      cache['key'] = null;
      // After inserting null, the key should exist
      expect(cache.containsKey('key'), true);
      expect(cache['key'], null);
    });

    test('int keys work', () {
      final cache = LruCache<int, String>(maxSize: 3);
      cache[1] = 'one';
      cache[2] = 'two';
      cache[3] = 'three';
      expect(cache[2], 'two');
      cache[4] = 'four';
      expect(cache.containsKey(1), false); // evicted
      expect(cache.containsKey(2), true);
    });
  });
}
