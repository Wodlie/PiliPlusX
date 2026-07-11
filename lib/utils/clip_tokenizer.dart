import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart CLIP ByteLevel BPE tokenizer.
///
/// Matches the tokenization algorithm from OpenAI CLIP's simple_tokenizer.py:
///   https://github.com/openai/CLIP/blob/main/clip/simple_tokenizer.py
///
/// Loads tokenizer files from the filesystem (not Flutter assets).
/// Supports two formats:
///   1. `tokenizer.json` (HuggingFace tokenizers format) — single file
///   2. `vocab.json` + `merges.txt` (OpenAI CLIP format) — two files
class CLIPTokenizer {
  // ── Special token IDs ──────────────────────────────────────────────
  static const int bosId = 49406;
  static const int eosId = 49407;
  static const int padId = 0;

  // ── Vocab and BPE state ────────────────────────────────────────────
  final Map<String, int> _vocab;
  final Map<int, String> _decoder;
  final Map<String, int> _bpeRanks;
  final Map<String, String> _cache = <String, String>{
    '<|startoftext|>': '<|startoftext|>',
    '<|endoftext|>': '<|endoftext|>',
  };

  // ── Byte ↔ Unicode mapping (CLIP-specific) ────────────────────────
  static final Map<int, int> _byteToUnicode = _buildByteToUnicode();
  static final Map<int, int> _unicodeToByte =
      _byteToUnicode.map((k, v) => MapEntry(v, k));

  // ── Pre-tokenizer regex ───────────────────────────────────────────
  static final RegExp _pattern = RegExp(
    r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|\w+|[^\s\w]+",
    unicode: true,
    caseSensitive: false,
  );

  // ── Constructor ────────────────────────────────────────────────────
  CLIPTokenizer._(this._vocab, this._bpeRanks)
      : _decoder = _vocab.map((k, v) => MapEntry(v, k));

  // ── Factory: load from directory ───────────────────────────────────
  /// Load tokenizer files from [tokenizerDir]. Auto-detects format:
  ///
  /// 1. `tokenizer.json` (HuggingFace tokenizers format) — single file
  /// 2. `vocab.json` + `merges.txt` (OpenAI CLIP format) — two files
  static Future<CLIPTokenizer> loadFromPath(String tokenizerDir) async {
    final dir = Directory(tokenizerDir);
    final tokenizerFile = File('${dir.path}/tokenizer.json');
    final vocabFile = File('${dir.path}/vocab.json');
    final mergesFile = File('${dir.path}/merges.txt');

    if (await tokenizerFile.exists()) {
      return _loadFromHuggingFace(tokenizerFile);
    } else if (await vocabFile.exists() && await mergesFile.exists()) {
      return _loadFromOpenAI(vocabFile, mergesFile);
    }
    throw ArgumentError('No tokenizer files found in: $tokenizerDir');
  }

  /// Load from HuggingFace `tokenizer.json` format.
  static Future<CLIPTokenizer> _loadFromHuggingFace(File file) async {
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final model = json['model'] as Map<String, dynamic>;
    final vocabRaw = model['vocab'] as Map<String, dynamic>;
    final mergesRaw = model['merges'] as List<dynamic>;

    final vocab =
        vocabRaw.map((k, v) => MapEntry(k, (v as num).toInt()));
    final merges = mergesRaw.cast<String>().toList();

    return _fromMerges(vocab, merges);
  }

  /// Load from OpenAI CLIP `vocab.json` + `merges.txt` format.
  static Future<CLIPTokenizer> _loadFromOpenAI(
    File vocabFile,
    File mergesFile,
  ) async {
    final vocabContent = await vocabFile.readAsString();
    final vocabRaw = jsonDecode(vocabContent) as Map<String, dynamic>;
    final vocab = vocabRaw.map((k, v) => MapEntry(k, (v as num).toInt()));

    final mergesContent = await mergesFile.readAsString();
    final mergesLines = mergesContent.split('\n');
    final merges = <String>[];
    for (int i = 1; i < mergesLines.length; i++) {
      final line = mergesLines[i].trim();
      if (line.isNotEmpty) {
        merges.add(line);
      }
    }

    return _fromMerges(vocab, merges);
  }

  /// Build a [CLIPTokenizer] from parsed vocab and merges.
  static CLIPTokenizer _fromMerges(
    Map<String, int> vocab,
    List<String> merges,
  ) {
    final bpeRanks = <String, int>{};
    for (int i = 0; i < merges.length; i++) {
      bpeRanks[merges[i]] = i;
    }
    return CLIPTokenizer._(vocab, bpeRanks);
  }

  /// Create a [CLIPTokenizer] from a HuggingFace `tokenizer.json` string.
  ///
  /// Useful when the JSON content is already in memory (e.g. fetched from
  /// network, read from a file that's already open, or injected in tests).
  ///
  /// The [jsonContent] must be a valid tokenizer.json with a `model` field
  /// containing `vocab` (Map<String,int>) and `merges` (List<String>).
  static CLIPTokenizer fromJson(String jsonContent) {
    final json = jsonDecode(jsonContent) as Map<String, dynamic>;
    final model = json['model'] as Map<String, dynamic>;
    final vocabRaw = model['vocab'] as Map<String, dynamic>;
    final mergesRaw = model['merges'] as List<dynamic>;

    final vocab =
        vocabRaw.map((k, v) => MapEntry(k, (v as num).toInt()));
    final merges = mergesRaw.cast<String>().toList();

    return _fromMerges(vocab, merges);
  }

  // ── Public API ─────────────────────────────────────────────────────
  /// Tokenize [text] to CLIP token IDs.
  ///
  /// Algorithm (matches OpenAI CLIP simple_tokenizer.py):
  ///   1. NFC normalize → lower case → strip
  ///   2. Replace all whitespace runs with single space
  ///   3. CLIP regex split
  ///   4. Byte-level BPE encoding per split token
  ///   5. Prepend BOS (49406), append EOS (49407)
  ///   6. Pad/truncate to [contextLength] (default 77)
  ///
  /// Returns a [List<int>] of exactly [contextLength] elements.
  List<int> tokenize(String text, {int contextLength = 77}) {
    // 1. NFC normalize (via UTF-8 roundtrip) → lowercase → strip
    final normalized = utf8.decode(text.codeUnits, allowMalformed: true);
    var clean = normalized.toLowerCase().trim();

    // 2. Collapse whitespace
    clean = clean.replaceAll(_whitespacePattern, ' ');

    // 3. Regex split
    final rawTokens = _pattern.allMatches(clean).map((m) => m.group(0)!).toList();

    // 4. Byte-level BPE encode each token
    final bpeTokenIds = <int>[];
    for (final token in rawTokens) {
      // Byte-level encoding: UTF-8 bytes → unicode chars per CLIP spec
      final utf8Bytes = utf8.encode(token);
      final byteEncoded = String.fromCharCodes(
        utf8Bytes.map((b) => _byteToUnicode[b]!),
      );

      // BPE
      final bpeResult = _bpe(byteEncoded);
      for (final subToken in bpeResult.split(' ')) {
        final id = _vocab[subToken];
        if (id != null) {
          bpeTokenIds.add(id);
        }
        // Unknown tokens → skip (the vocab should have all BPE outputs)
      }
    }

    // 5. Prepend BOS, append EOS
    final result = <int>[bosId, ...bpeTokenIds, eosId];

    // 6. Pad or truncate
    if (result.length > contextLength) {
      return result.sublist(0, contextLength);
    }
    return [
      ...result,
      ...List.filled(contextLength - result.length, padId),
    ];
  }

  /// Decode token IDs back to text (approximate).
  ///
  /// This is an approximate decoder; inverse of [tokenize].
  String decode(List<int> tokens) {
    final text = tokens
        .map((id) => _decoder[id] ?? '')
        .join('')
        .replaceAll('</w>', ' ');
    // Reverse the byte-to-unicode mapping
    final codeUnits = <int>[];
    for (final char in text.runes) {
      final byte = _unicodeToByte[char];
      if (byte != null) {
        codeUnits.add(byte);
      }
    }
    return utf8.decode(codeUnits, allowMalformed: true).trim();
  }

  // ── Private: BPE ───────────────────────────────────────────────────
  String _bpe(String token) {
    final cached = _cache[token];
    if (cached != null) return cached;

    // Build initial word: each char gets its own entry; last char gets </w>
    final chars = token.split('');
    // Replicating Python: `tuple(token[:-1]) + (token[-1] + '</w>',)`
    final word = <String>[
      ...chars.sublist(0, chars.length - 1),
      '${chars.last}</w>',
    ];

    var pairs = _getPairs(word);
    if (pairs.isEmpty) {
      final result = '$token</w>';
      _cache[token] = result;
      return result;
    }

    while (true) {
      // Find the pair with the lowest rank (highest priority)
      var bestPair = <String>['', ''];
      var bestRank = 1 << 60;
      for (final pair in pairs) {
        final key = '${pair[0]} ${pair[1]}';
        final rank = _bpeRanks[key];
        if (rank != null && rank < bestRank) {
          bestRank = rank;
          bestPair = pair;
        }
      }

      // No rank found for the best pair → stop
      if (bestRank == 1 << 60) break;

      final first = bestPair[0];
      final second = bestPair[1];
      final newWord = <String>[];
      int i = 0;

      while (i < word.length) {
        final j = word.indexOf(first, i);
        if (j == -1) {
          newWord.addAll(word.sublist(i));
          break;
        }
        newWord.addAll(word.sublist(i, j));
        i = j;
        if (word[i] == first &&
            i < word.length - 1 &&
            word[i + 1] == second) {
          newWord.add(first + second);
          i += 2;
        } else {
          newWord.add(word[i]);
          i++;
        }
      }

      word
        ..clear()
        ..addAll(newWord);

      if (word.length == 1) break;
      pairs = _getPairs(word);
    }

    final result = word.join(' ');
    _cache[token] = result;
    return result;
  }

  /// Return the set of adjacent symbol pairs in [word].
  Set<List<String>> _getPairs(List<String> word) {
    final pairs = <List<String>>{};
    for (int i = 0; i < word.length - 1; i++) {
      pairs.add([word[i], word[i + 1]]);
    }
    return pairs;
  }

  // ── Helpers ────────────────────────────────────────────────────────
  static final RegExp _whitespacePattern = RegExp(r'\s+');

  /// Build the CLIP byte-to-unicode mapping.
  ///
  /// Returns a map from byte value (0-255) to unicode codepoint.
  /// Matches OpenAI CLIP's `bytes_to_unicode()`:
  ///   - bytes 33–126 → chr(b)
  ///   - bytes 161–172 → chr(b)
  ///   - bytes 174–255 → chr(b)
  ///   - remaining bytes → chr(256 + n) for n = 0, 1, 2, ...
  static Map<int, int> _buildByteToUnicode() {
    // Printable ASCII: '!' (33) to '~' (126)
    final initialBytes = <int>{
      for (int i = 33; i <= 126; i++) i,
      // Latin-1 supplement: '¡' (161) to '¬' (172)
      for (int i = 161; i <= 172; i++) i,
      // Latin-1 supplement: '®' (174) to 'ÿ' (255)
      for (int i = 174; i <= 255; i++) i,
    };

    final bs = <int>[];
    final cs = <int>[];

    // Add initial entries in order
    for (final b in [
      for (int i = 33; i <= 126; i++) i,
      for (int i = 161; i <= 172; i++) i,
      for (int i = 174; i <= 255; i++) i,
    ]) {
      bs.add(b);
      cs.add(b);
    }

    int n = 0;
    for (int b = 0; b < 256; b++) {
      if (!initialBytes.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }

    final result = <int, int>{};
    for (int i = 0; i < bs.length; i++) {
      result[bs[i]] = cs[i];
    }
    return result;
  }
}
