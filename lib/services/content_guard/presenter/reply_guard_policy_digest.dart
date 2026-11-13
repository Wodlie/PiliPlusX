/// Digest of the facts a static reply verdict depends on, minus the body.
///
/// [replyGuardContentVersionOf] already covers the message, the author and the
/// media. A static verdict also depends on the author's level, the @ shape, the
/// goods flag, the local blacklist and the whole filter configuration in force,
/// so a revision that ignored those would let a verdict survive a change to the
/// very inputs it judged.
///
/// ## What "the whole configuration" means here
///
/// The contract is the one the legacy filter already implements
/// (`ReplyGrpc.checkBlockReason` and `needRemoveAtGrpc`): the keyword regex
/// **pattern and flags**, the goods toggle, the minimum level, all five @-filter
/// sub-rules **with their thresholds**, and the local blacklist. Anything the
/// filter reads and this digest omits is a silent staleness bug — the user
/// changes a threshold, the row keeps its old verdict, and a suggestion card is
/// anchored on a judgement that no longer holds.
///
/// Both halves of that contract live here so they cannot drift:
///
/// * [ReplyGuardPolicyFacts.revision] — the **configuration**, once per list;
/// * [replyGuardPolicyDigestOf] — the **per-reply inputs**, once per row.
///
/// ## Why nothing raw is stored
///
/// The version reaches persisted decision keys and evidence fields. Only
/// SHA-256 digests leave either function, and the JSON they hash is never
/// retained, so no message, URL, regex, @-name, emote key or credential can be
/// recovered from a stored record while any change to one still moves the
/// digest.
///
/// ## Why JSON and not delimiters
///
/// Same reason as the payload version: a separator can occur inside a pattern
/// or a name. Encoding as JSON makes `('a|b', '')` and `('a', 'b')` distinct
/// by construction instead of by luck.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Every configuration fact one static reply verdict depends on.
///
/// Deliberately a value object with **no** dependency on `Pref`, `GlobalData`
/// or `ReplyGrpc`: those pull `package:get` and therefore `dart:ui`, which
/// would make this file unverifiable by a plain-Dart probe. The page layer
/// builds the live instance (see `replyGuardLivePolicyFacts`) and hands it to
/// both the controller and the row widget, which is what guarantees the two
/// sides derive the same revision.
final class ReplyGuardPolicyFacts {
  ReplyGuardPolicyFacts({
    this.keywordPattern = '',
    this.keywordCaseSensitive = false,
    this.goodsFilter = false,
    this.minLevel = 0,
    this.atFilter = false,
    this.atPureAt = false,
    this.atBodyLength = false,
    this.atBodyLengthThreshold = 0,
    this.atCount = false,
    this.atCountThreshold = 0,
    this.atLikeExempt = false,
    this.atLikeExemptThreshold = 0,
    Set<int> blacklistMids = const <int>{},
  }) : _blacklistMids = Set<int>.unmodifiable(blacklistMids);

  /// The keyword regex as the user typed it, flags included.
  ///
  /// Read through [keywordFilter], which is the exact condition
  /// `ReplyGrpc.enableFilter` uses: a pattern that is empty means the filter is
  /// off, and an empty pattern therefore cannot change a verdict.
  final String keywordPattern;

  /// The `caseSensitive` flag of the compiled keyword regex.
  ///
  /// Part of the revision because two patterns that differ only here match
  /// different comments; the legacy filter compiles with `caseSensitive: false`
  /// today, but the revision must follow the flag rather than assume it.
  final bool keywordCaseSensitive;

  final bool goodsFilter;
  final int minLevel;

  final bool atFilter;
  final bool atPureAt;
  final bool atBodyLength;
  final int atBodyLengthThreshold;
  final bool atCount;
  final int atCountThreshold;
  final bool atLikeExempt;
  final int atLikeExemptThreshold;

  final Set<int> _blacklistMids;

  /// Whether the keyword filter is enabled at all, mirroring
  /// `ReplyGrpc.enableFilter`.
  bool get keywordFilter => keywordPattern.isNotEmpty;

  /// Locally blacklisted mids this revision was built from. Read-only.
  ///
  /// Deliberately NOT part of [revision]. The blacklist changes a verdict only
  /// through one row's own membership, which
  /// [replyGuardPolicyDigestOf.authorBlacklisted] carries, so folding the whole
  /// set into the shared revision would invalidate every other author's verdict
  /// whenever the user blocks one person — a full re-evaluation of the list for
  /// a change that cannot affect it.
  Set<int> get blacklistMids => _blacklistMids;

  /// Whether [mid] is on the local blacklist as of this revision.
  bool isBlacklisted(int mid) => mid > 0 && _blacklistMids.contains(mid);

  String? _revision;

  /// Opaque revision of this configuration.
  ///
  /// Memoised per instance: the page layer builds one instance per list build
  /// and hands it to every row, so the digest cost is per build, not per row.
  String get revision => _revision ??=
      'f2.' + sha256.convert(utf8.encode(_encodedConfiguration)).toString();

  /// Configuration shape, as the digest input. Never persisted.
  String get _encodedConfiguration => jsonEncode(<String, Object?>{
    'keyword': <String, Object?>{
      'pattern': keywordPattern,
      'caseSensitive': keywordCaseSensitive,
    },
    'goods': goodsFilter,
    'minLevel': minLevel,
    'at': <String, Object?>{
      'enabled': atFilter,
      'pureAt': atPureAt,
      'bodyLength': atBodyLength,
      'bodyLengthThreshold': atBodyLengthThreshold,
      'count': atCount,
      'countThreshold': atCountThreshold,
      'likeExempt': atLikeExempt,
      'likeExemptThreshold': atLikeExemptThreshold,
    },
  });

  @override
  String toString() => 'ReplyGuardPolicyFacts($revision)';
}

/// One-way digest of the per-reply facts the static filters read.
///
/// Every field is something `checkBlockReason` or `needRemoveAtGrpc`
/// actually consumes:
///
/// * [level] — the minimum-level rule;
/// * [likeCount] — the @-filter's like exemption, and nothing else;
/// * [rootId] — whether this is a reply, which changes how @ mentions are
///   counted (the `回复 @user:` prefix is excluded for replies only);
/// * [atNameCount] / [atNamesDigest] — the structured @ map, whose **keys** and
///   size both feed the count and the pure-@ body test;
/// * [emoteDigest] / [topicDigest] / [urlDigest] — the token sets
///   `normalizeReplyBody` strips before the body-length and pure-@ tests;
/// * [hasGoods] — the goods predicate;
/// * [authorBlacklisted] — local-blacklist membership for this author;
/// * [filterRevision] — [ReplyGuardPolicyFacts.revision].
///
/// Only the digest leaves this function. Every argument is used as hash input
/// and nothing more.
String replyGuardPolicyDigestOf({
  required int level,
  required int likeCount,
  required int rootId,
  required int atNameCount,
  required String atNamesDigest,
  required String emoteDigest,
  required String topicDigest,
  required String urlDigest,
  required bool hasGoods,
  required bool authorBlacklisted,
  required String filterRevision,
}) {
  final material = jsonEncode(<String, Object?>{
    'level': level,
    'like': likeCount,
    'root': rootId,
    'atNames': atNameCount,
    'atNamesDigest': atNamesDigest,
    'emotes': emoteDigest,
    'topics': topicDigest,
    'urls': urlDigest,
    'goods': hasGoods,
    'blacklisted': authorBlacklisted,
    'filters': filterRevision,
  });
  return sha256.convert(utf8.encode(material)).toString().substring(0, 32);
}

/// One-way digest of a set of token strings (emote keys, topic keys, URLs, @
/// names).
///
/// Sorted and JSON-encoded before hashing, so the same set always produces the
/// same digest and a different set never produces the same one. Returns a
/// fixed-width hex string, never the tokens themselves.
String replyGuardTokenDigestOf(Iterable<String> tokens) {
  final sorted = tokens.toList(growable: false)..sort();
  return sha256.convert(utf8.encode(jsonEncode(sorted))).toString();
}
