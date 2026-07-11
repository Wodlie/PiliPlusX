import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/utils/clip_tokenizer.dart';

void main() {
  late CLIPTokenizer tokenizer;

  setUp(() async {
    // Load the minimal test fixture
    tokenizer = await CLIPTokenizer.loadFromPath('test/fixtures');
  });

  // ── Token IDs from the fixture ─────────────────────────────────────
  // BOS=49406, EOS=49407
  // "a</w>"=95, "b</w>"=96, "c</w>"=97, "cat</w>"=200
  // "dog</w>"=201, "hello</w>"=300

  group('CLIPTokenizer', () {
    test('empty string returns BOS+EOS with padding', () {
      final result = tokenizer.tokenize('');
      expect(result.length, 77);
      expect(result[0], CLIPTokenizer.bosId); // BOS
      expect(result[1], CLIPTokenizer.eosId); // EOS
      // Remaining entries should be PAD
      for (int i = 2; i < 77; i++) {
        expect(result[i], CLIPTokenizer.padId);
      }
    });

    test('single ASCII character', () {
      final result = tokenizer.tokenize('a');
      expect(result.length, 77);
      expect(result[0], CLIPTokenizer.bosId);
      // "a" → byte-encoded "a" → BPE → "a</w>" → ID 95
      expect(result[1], 95);
      expect(result[2], CLIPTokenizer.eosId);
    });

    test('multi-character word uses BPE merging', () {
      // "cat" should merge via: c+a → "ca", ca+t</w> → "cat</w>" → ID 200
      final result = tokenizer.tokenize('cat');
      expect(result.length, 77);
      expect(result[0], CLIPTokenizer.bosId);
      expect(result[1], 200, reason: '"cat</w>" should have ID 200');
      expect(result[2], CLIPTokenizer.eosId);
    });

    test('two words produce two BPE tokens', () {
      final result = tokenizer.tokenize('a b');
      expect(result.length, 77);
      expect(result[0], CLIPTokenizer.bosId);
      expect(result[1], 95); // "a</w>"
      expect(result[2], 96); // "b</w>"
      expect(result[3], CLIPTokenizer.eosId);
    });

    test('long text is truncated to contextLength (77)', () {
      // 80 tokens of "a " → 80 "a" matches → 80 BPE tokens
      // BOS + 80 + EOS = 82 → truncated to 77
      const longText = 'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a';
      final result = tokenizer.tokenize(longText);
      expect(result.length, 77);
      expect(result[0], CLIPTokenizer.bosId);
      // All BPE tokens in range
      for (int i = 1; i < 77; i++) {
        expect(result[i], greaterThanOrEqualTo(0));
        expect(result[i], lessThan(49408));
      }
    });

    test('all token IDs are in valid range [0, 49408)', () {
      final result = tokenizer.tokenize('cat dog hello a b');
      expect(result.length, 77);
      for (final id in result) {
        expect(id, greaterThanOrEqualTo(0));
        expect(id, lessThan(49408),
            reason: 'Token ID $id is out of valid range');
      }
    });

    test('special characters (unicode, emoji) do not crash', () {
      // These should not throw — unknown tokens are simply skipped
      expect(
        () => tokenizer.tokenize('hello café résumé 你好 😀'),
        returnsNormally,
      );
      final result = tokenizer.tokenize('hello café résumé 你好 😀');
      expect(result.length, 77);
      expect(result[0], CLIPTokenizer.bosId);
      // "hello" should still produce its known token
      expect(result.contains(300), true,
          reason: '"hello</w>" (ID 300) should be present');
    });

    test('uppercase input is lowercased before tokenization', () {
      final upper = tokenizer.tokenize('CAT');
      final lower = tokenizer.tokenize('cat');
      // Both should produce identical results
      expect(upper, equals(lower));
    });

    test('decode is approximate inverse of tokenize', () {
      final tokens = tokenizer.tokenize('hello world');
      expect(tokens.length, 77);
      // "hello" → 300, "world" → 301
      expect(tokens[1], 300);
      expect(tokens[2], 301);
      expect(tokens[3], CLIPTokenizer.eosId);

      // Decode back
      final decoded = tokenizer.decode(tokens);
      expect(decoded, contains('hello'));
      expect(decoded, contains('world'));
    });

    test('multiple of the same word is handled correctly', () {
      final result = tokenizer.tokenize('cat cat');
      expect(result.length, 77);
      expect(result[1], 200);
      expect(result[2], 200);
      expect(result[3], CLIPTokenizer.eosId);
    });

    test('loadFromJson parses HuggingFace format correctly', () {
      // Read the fixture and parse via fromJson
      final fixture = File('test/fixtures/tokenizer.json').readAsStringSync();
      final fromJsonTokenizer = CLIPTokenizer.fromJson(fixture);

      final result = fromJsonTokenizer.tokenize('cat');
      expect(result.length, 77);
      expect(result[1], 200);
    });

    test('contextLength parameter controls output length', () {
      final result = tokenizer.tokenize('cat', contextLength: 10);
      expect(result.length, 10);
      expect(result[0], CLIPTokenizer.bosId);
      expect(result[1], 200);
      expect(result[2], CLIPTokenizer.eosId);
      // Rest is padding
      for (int i = 3; i < 10; i++) {
        expect(result[i], CLIPTokenizer.padId);
      }
    });
  });
}
