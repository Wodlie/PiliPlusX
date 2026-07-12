import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/utils/clip_tokenizer.dart';
import 'package:PiliPlus/utils/clip_tokenizer_config.dart';

void main() {
  late CLIPTokenizer tokenizer;

  setUp(() async {
    // Load the minimal test fixture (no config, so uses default values)
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
      expect(result.inputIds[0], tokenizer.bosId); // BOS
      expect(result.inputIds[1], tokenizer.eosId); // EOS
      // Remaining entries should be PAD
      for (int i = 2; i < 77; i++) {
        expect(result.inputIds[i], tokenizer.padId);
      }
    });

    test('single ASCII character', () {
      final result = tokenizer.tokenize('a');
      expect(result.length, 77);
      expect(result.inputIds[0], tokenizer.bosId);
      // "a" → byte-encoded "a" → BPE → "a</w>" → ID 95
      expect(result.inputIds[1], 95);
      expect(result.inputIds[2], tokenizer.eosId);
    });

    test('multi-character word uses BPE merging', () {
      // "cat" should merge via: c+a → "ca", ca+t</w> → "cat</w>" → ID 200
      final result = tokenizer.tokenize('cat');
      expect(result.length, 77);
      expect(result.inputIds[0], tokenizer.bosId);
      expect(result.inputIds[1], 200, reason: '"cat</w>" should have ID 200');
      expect(result.inputIds[2], tokenizer.eosId);
    });

    test('two words produce two BPE tokens', () {
      final result = tokenizer.tokenize('a b');
      expect(result.length, 77);
      expect(result.inputIds[0], tokenizer.bosId);
      expect(result.inputIds[1], 95); // "a</w>"
      expect(result.inputIds[2], 96); // "b</w>"
      expect(result.inputIds[3], tokenizer.eosId);
    });

    test('long text is truncated to contextLength (77)', () {
      // 80 tokens of "a " → 80 "a" matches → 80 BPE tokens
      // BOS + 80 + EOS = 82 → truncated to 77
      const longText =
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a';
      final result = tokenizer.tokenize(longText);
      expect(result.length, 77);
      expect(result.inputIds[0], tokenizer.bosId);
      // All BPE tokens in range
      for (int i = 1; i < 77; i++) {
        expect(result.inputIds[i], greaterThanOrEqualTo(0));
        expect(result.inputIds[i], lessThan(49408));
      }
    });

    test('all token IDs are in valid range [0, 49408)', () {
      final result = tokenizer.tokenize('cat dog hello a b');
      expect(result.length, 77);
      for (final id in result.inputIds) {
        expect(id, greaterThanOrEqualTo(0));
        expect(
          id,
          lessThan(49408),
          reason: 'Token ID $id is out of valid range',
        );
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
      expect(result.inputIds[0], tokenizer.bosId);
      // "hello" should still produce its known token
      expect(
        result.inputIds.contains(300),
        true,
        reason: '"hello</w>" (ID 300) should be present',
      );
    });

    test('uppercase input is lowercased before tokenization', () {
      final upper = tokenizer.tokenize('CAT');
      final lower = tokenizer.tokenize('cat');
      // Both should produce identical results (inputIds and attentionMask)
      expect(upper.inputIds, equals(lower.inputIds));
      expect(upper.attentionMask, equals(lower.attentionMask));
    });

    test('decode is approximate inverse of tokenize', () {
      final result = tokenizer.tokenize('hello world');
      expect(result.length, 77);
      // "hello" → 300, "world" → 301
      expect(result.inputIds[1], 300);
      expect(result.inputIds[2], 301);
      expect(result.inputIds[3], tokenizer.eosId);

      // Decode back
      final decoded = tokenizer.decode(result.inputIds);
      expect(decoded, contains('hello'));
      expect(decoded, contains('world'));
    });

    test('multiple of the same word is handled correctly', () {
      final result = tokenizer.tokenize('cat cat');
      expect(result.length, 77);
      expect(result.inputIds[1], 200);
      expect(result.inputIds[2], 200);
      expect(result.inputIds[3], tokenizer.eosId);
    });

    test('loadFromJson parses HuggingFace format correctly', () {
      // Read the fixture and parse via fromJson
      final fixture = File('test/fixtures/tokenizer.json').readAsStringSync();
      final fromJsonTokenizer = CLIPTokenizer.fromJson(fixture);

      final result = fromJsonTokenizer.tokenize('cat');
      expect(result.length, 77);
      expect(result.inputIds[1], 200);
    });

    test('contextLength parameter controls output length', () {
      final result = tokenizer.tokenize('cat', contextLength: 10);
      expect(result.length, 10);
      expect(result.inputIds[0], tokenizer.bosId);
      expect(result.inputIds[1], 200);
      expect(result.inputIds[2], tokenizer.eosId);
      // Rest is padding
      for (int i = 3; i < 10; i++) {
        expect(result.inputIds[i], tokenizer.padId);
      }
    });

    // ── New tests for config-driven API ──────────────────────────────

    test('no config uses default values (77/49406/49407/0)', () {
      // tokenizer loaded without config in setUp
      expect(tokenizer.contextLength, 77);
      expect(tokenizer.bosId, 49406);
      expect(tokenizer.eosId, 49407);
      expect(tokenizer.padId, 0);
    });

    test('custom model_max_length from config', () {
      final config = const ClipTokenizerConfig(contextLength: 128);
      final customTokenizer = CLIPTokenizer.fromJson(
        File('test/fixtures/tokenizer.json').readAsStringSync(),
        config: config,
      );
      final result = customTokenizer.tokenize('cat');
      expect(result.length, 128);
      expect(result.inputIds[0], customTokenizer.bosId);
      expect(result.inputIds[1], 200);
      expect(result.inputIds[2], customTokenizer.eosId);
    });

    test('custom BOS/EOS/PAD from config via ClipTokenizerConfig', () {
      final config = const ClipTokenizerConfig(
        bosToken: '<|startoftext|>',
        eosToken: '<|endoftext|>',
        padToken: '<|endoftext|>',
      );
      final customTokenizer = CLIPTokenizer.fromJson(
        File('test/fixtures/tokenizer.json').readAsStringSync(),
        config: config,
      );
      expect(customTokenizer.bosId, 49406);
      expect(customTokenizer.eosId, 49407);
      // padToken '<|endoftext|>' resolves to 49407 (same as EOS in CLIP)
      expect(customTokenizer.padId, 49407);
    });

    test('do_lower_case=false from config', () {
      final config = const ClipTokenizerConfig(doLowerCase: false);
      final customTokenizer = CLIPTokenizer.fromJson(
        File('test/fixtures/tokenizer.json').readAsStringSync(),
        config: config,
      );
      // With do_lower_case=false, uppercase 'CAT' is not lowercased
      final upper = customTokenizer.tokenize('CAT');
      final lower = customTokenizer.tokenize('cat');
      expect(upper.inputIds, isNot(equals(lower.inputIds)));
    });

    test('add_prefix_space from config', () {
      final config = const ClipTokenizerConfig(addPrefixSpace: true);
      final customTokenizer = CLIPTokenizer.fromJson(
        File('test/fixtures/tokenizer.json').readAsStringSync(),
        config: config,
      );
      // addPrefixSpace: true — tokenize still works correctly
      final result = customTokenizer.tokenize('cat');
      expect(result.length, 77);
      expect(result.inputIds[0], customTokenizer.bosId);
      expect(result.inputIds[1], 200);
      expect(result.inputIds[2], customTokenizer.eosId);
    });

    test('attentionMask values (1 for real tokens, 0 for padding)', () {
      final result = tokenizer.tokenize('cat');
      expect(result.attentionMask.length, 77);
      // Real tokens: BOS, "cat", EOS → three 1s
      expect(result.attentionMask[0], 1); // BOS
      expect(result.attentionMask[1], 1); // "cat"
      expect(result.attentionMask[2], 1); // EOS
      // Rest is padding → zeros
      for (int i = 3; i < 77; i++) {
        expect(result.attentionMask[i], 0);
      }
    });

    test('truncation preserves EOS', () {
      // Long text that would exceed 77 tokens
      const longText =
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a '
          'a a a a a a a a a a a a a a a a a a a a';
      final result = tokenizer.tokenize(longText);
      expect(result.length, 77);
      // Last position must be EOS after truncation
      expect(result.inputIds[76], tokenizer.eosId);
    });

    test('non-BPE tokenizer throws UnsupportedError', () {
      final nonBpeJson = jsonEncode({
        'model': {
          'type': 'WordPiece',
          'vocab': {'hello': 0},
          'merges': <String>[],
        },
      });
      expect(
        () => CLIPTokenizer.fromJson(nonBpeJson),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('added_tokens_decoder parsing via config', () {
      final config = ClipTokenizerConfig(
        bosToken: '<|startoftext|>',
        eosToken: '<|endoftext|>',
        padToken: '<|pad|>',
        addedTokens: {0: '<|pad|>'},
      );
      final customTokenizer = CLIPTokenizer.fromJson(
        File('test/fixtures/tokenizer.json').readAsStringSync(),
        config: config,
      );
      // padToken '<|pad|>' should resolve to ID 0 via addedTokens
      expect(customTokenizer.padId, 0);
    });

    test('merges as two-element array format', () {
      final arrayMergesJson = jsonEncode({
        'model': {
          'type': 'BPE',
          'vocab': {
            'a</w>': 0,
            'b</w>': 1,
            'ab</w>': 2,
            '<|startoftext|>': 49406,
            '<|endoftext|>': 49407,
          },
          'merges': [
            ['a', 'b</w>'],
          ],
        },
      });
      final customTokenizer = CLIPTokenizer.fromJson(arrayMergesJson);
      // "ab" should BPE-merge into "ab</w>" → ID 2
      final result = customTokenizer.tokenize('ab');
      expect(result.inputIds[1], 2);
    });
  });
}
