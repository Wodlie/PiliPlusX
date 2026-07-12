import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// Configuration parsed from a HuggingFace `tokenizer_config.json`.
///
/// Provides the special token strings and model-level settings for a CLIP
/// tokenizer. The tokenizer itself uses this config to resolve token IDs.
///
/// All fields are immutable (final).
class ClipTokenizerConfig {
  // ── Special token strings ───────────────────────────────────────────
  /// The raw `bos_token` value (e.g. `<|startoftext|>`).
  final String? bosToken;

  /// The raw `eos_token` value (e.g. `<|endoftext|>`).
  final String? eosToken;

  /// The raw `pad_token` value (e.g. `!` or `<|endoftext|>`).
  final String? padToken;

  /// The raw `unk_token` value (e.g. `<|endoftext|>`).
  final String? unkToken;

  // ── Model hyper-parameters ──────────────────────────────────────────
  /// Maximum sequence length (`model_max_length`). Defaults to 77.
  final int contextLength;

  /// Whether to lowercase input (`do_lower_case`). Defaults to true.
  final bool doLowerCase;

  /// Whether to prefix input with a space (`add_prefix_space`). Defaults to false.
  final bool addPrefixSpace;

  /// Which side to truncate on (`truncation_side`). `"left"` or `"right"`.
  final String? truncationSide;

  /// Which side to pad on (`padding_side`). `"left"` or `"right"`.
  final String? paddingSide;

  /// Additional tokens decoded from `added_tokens_decoder`.
  ///
  /// Keys are token IDs (parsed from string keys in JSON), values are the
  /// corresponding token content strings.
  final Map<int, String> addedTokens;

  // ── Constructor ─────────────────────────────────────────────────────
  const ClipTokenizerConfig({
    this.bosToken,
    this.eosToken,
    this.padToken,
    this.unkToken,
    this.contextLength = 77,
    this.doLowerCase = true,
    this.addPrefixSpace = false,
    this.truncationSide,
    this.paddingSide,
    this.addedTokens = const <int, String>{},
  });

  // ── Factory: from defaults ──────────────────────────────────────────
  /// Returns a [ClipTokenizerConfig] with OpenAI CLIP defaults.
  ///
  /// These match the hardcoded constants in [CLIPTokenizer] (bosId=49406,
  /// eosId=49407, padId=0, contextLength=77).
  factory ClipTokenizerConfig.fromDefaults() {
    return const ClipTokenizerConfig(
      bosToken: '<|startoftext|>',
      eosToken: '<|endoftext|>',
      padToken: '<|endoftext|>',
      unkToken: '<|endoftext|>',
      contextLength: 77,
      doLowerCase: true,
      addPrefixSpace: false,
      truncationSide: 'right',
      paddingSide: 'right',
    );
  }

  // ── Factory: load from JSON file ────────────────────────────────────
  /// Loads and parses `tokenizer_config.json` from [configDir].
  ///
  /// Returns `null` if the file does not exist or if the JSON is malformed.
  /// Errors are logged via [debugPrint] and silently swallowed.
  static Future<ClipTokenizerConfig?> loadFromPath(String configDir) async {
    try {
      final file = File('${configDir}/tokenizer_config.json');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _fromJson(json);
    } catch (e) {
      debugPrint('[ClipTokenizerConfig] Failed to load config: $e');
      return null;
    }
  }

  // ── Internal: parse from decoded JSON ───────────────────────────────
  static ClipTokenizerConfig _fromJson(Map<String, dynamic> json) {
    return ClipTokenizerConfig(
      bosToken: _parseSpecialToken(json['bos_token']),
      eosToken: _parseSpecialToken(json['eos_token']),
      padToken: _parseSpecialToken(json['pad_token']),
      unkToken: _parseSpecialToken(json['unk_token']),
      contextLength: json['model_max_length'] as int? ?? 77,
      doLowerCase: json['do_lower_case'] as bool? ?? true,
      addPrefixSpace: json['add_prefix_space'] as bool? ?? false,
      truncationSide: json['truncation_side'] as String?,
      paddingSide: json['padding_side'] as String?,
      addedTokens: _parseAddedTokens(json['added_tokens_decoder']),
    );
  }

  /// Parse a special token value that can be either a plain string
  /// (`"<|startoftext|>"`) or an object (`{"content": "<|startoftext|>"}`).
  static String? _parseSpecialToken(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map<String, dynamic>) {
      return value['content'] as String?;
    }
    return null;
  }

  /// Parse `added_tokens_decoder` from JSON.
  ///
  /// Input format: `{"49406": {"content": "<|startoftext|>"}}`
  /// Output: `{49406: "<|startoftext|>"}`
  static Map<int, String> _parseAddedTokens(dynamic decoder) {
    if (decoder == null || decoder is! Map<String, dynamic>) {
      return const <int, String>{};
    }
    final result = <int, String>{};
    for (final entry in decoder.entries) {
      final id = int.tryParse(entry.key);
      if (id == null) continue;
      if (entry.value is String) {
        result[id] = entry.value as String;
      } else if (entry.value is Map<String, dynamic>) {
        final content = (entry.value as Map<String, dynamic>)['content'];
        if (content is String) {
          result[id] = content;
        }
      }
    }
    return result;
  }

  @override
  String toString() {
    return 'ClipTokenizerConfig('
        'bosToken: $bosToken, '
        'eosToken: $eosToken, '
        'padToken: $padToken, '
        'unkToken: $unkToken, '
        'contextLength: $contextLength, '
        'doLowerCase: $doLowerCase, '
        'addPrefixSpace: $addPrefixSpace, '
        'truncationSide: $truncationSide, '
        'paddingSide: $paddingSide, '
        'addedTokens: $addedTokens'
        ')';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClipTokenizerConfig &&
          runtimeType == other.runtimeType &&
          bosToken == other.bosToken &&
          eosToken == other.eosToken &&
          padToken == other.padToken &&
          unkToken == other.unkToken &&
          contextLength == other.contextLength &&
          doLowerCase == other.doLowerCase &&
          addPrefixSpace == other.addPrefixSpace &&
          truncationSide == other.truncationSide &&
          paddingSide == other.paddingSide &&
          MapEquality<int, String>().equals(
            addedTokens,
            other.addedTokens,
          );

  @override
  int get hashCode => Object.hash(
    runtimeType,
    bosToken,
    eosToken,
    padToken,
    unkToken,
    contextLength,
    doLowerCase,
    addPrefixSpace,
    truncationSide,
    paddingSide,
    MapEquality<int, String>().hash(addedTokens),
  );
}

/// Represents a tokenized text sequence ready for model inference.
///
/// Mirrors the output of a HuggingFace tokenizer's `__call__` method:
/// - [inputIds]: token IDs (1-D)
/// - [attentionMask]: 1 for real tokens, 0 for padding
class TokenizedText {
  /// Token IDs for model input.
  final List<int> inputIds;

  /// Attention mask: 1 for real tokens, 0 for padding.
  final List<int> attentionMask;

  const TokenizedText({
    required this.inputIds,
    required this.attentionMask,
  });

  /// The sequence length (number of tokens).
  int get length => inputIds.length;

  @override
  String toString() {
    return 'TokenizedText('
        'length: $length, '
        'inputIds: $inputIds, '
        'attentionMask: $attentionMask'
        ')';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TokenizedText &&
          runtimeType == other.runtimeType &&
          ListEquality<int>().equals(inputIds, other.inputIds) &&
          ListEquality<int>().equals(attentionMask, other.attentionMask);

  @override
  int get hashCode => Object.hash(
    runtimeType,
    ListEquality<int>().hash(inputIds),
    ListEquality<int>().hash(attentionMask),
  );
}
