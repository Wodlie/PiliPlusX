import 'package:PiliPlus/services/content_guard/model/account_scope.dart';
import 'package:PiliPlus/services/content_guard/model/content_context.dart';
import 'package:PiliPlus/services/content_guard/model/content_types.dart';
import 'package:PiliPlus/services/content_guard/model/media_ref.dart';

/// The one unified input object every operator, rule and decision reads.
///
/// Extraction from a platform model happens in an adapter, never here: this is
/// a value carrier, so it must stay free of HTTP, storage, UI and business
/// side effects (plan-core §1, §2.1).
///
/// The const constructor cannot defensively copy [tags] and [media]; callers
/// must pass immutable lists (`const []` or `List.unmodifiable`).
final class GuardContent {
  const GuardContent({
    required this.contentId,
    required this.contentType,
    required this.surface,
    required this.occurrenceKey,
    required this.authorUid,
    required this.parentId,
    required this.text,
    required this.title,
    required this.tags,
    required this.media,
    required this.account,
    required this.context,
    required this.contentVersion,
  });

  /// Stable platform id (rpid, aid, dynamic id, ...). Identity for de-dupe.
  final String contentId;

  final ContentType contentType;

  final ContentSurface surface;

  /// Which occurrence of [contentId] inside the current list this object is.
  final String occurrenceKey;

  /// Platform author UID. Never derived from model output or OCR output.
  final String? authorUid;

  /// Parent content id for nested content, supplied by the caller.
  final String? parentId;

  final String? text;

  final String? title;

  final List<String> tags;

  final List<MediaRef> media;

  final AccountScope account;

  final ContentContext context;

  /// Opaque version of the content payload (text plus media fingerprints).
  ///
  /// Async results are written back only when `contentId`, [contentVersion]
  /// and the list generation still match; completion order is never used as
  /// list order (plan-core §3 Step 2, §9).
  final String contentVersion;

  /// Identity of this exact revision, for write-back guards and cache keys.
  String get versionKey => '$contentId@$contentVersion';

  /// Whether any [media] is attached.
  bool get hasMedia => media.isNotEmpty;

  /// Whether this content can satisfy [input].
  ///
  /// Operators declare [ContentInput] requirements and the registry only
  /// dispatches those the content can actually feed. `description` is declared
  /// in [ContentInput] but the approved model has no description field, so it
  /// is reported as *not* provided rather than silently backed by an unrelated
  /// field.
  bool provides(ContentInput input) => switch (input) {
    ContentInput.text => _isMeaningful(text),
    ContentInput.title => _isMeaningful(title),
    ContentInput.description => false,
    ContentInput.tags => tags.isNotEmpty,
    ContentInput.authorUid => _isMeaningful(authorUid),
    ContentInput.metadata => true,
    ContentInput.media => media.isNotEmpty,
  };

  static bool _isMeaningful(String? value) => value != null && value.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GuardContent &&
          contentId == other.contentId &&
          contentType == other.contentType &&
          surface == other.surface &&
          occurrenceKey == other.occurrenceKey &&
          authorUid == other.authorUid &&
          parentId == other.parentId &&
          text == other.text &&
          title == other.title &&
          account == other.account &&
          context == other.context &&
          contentVersion == other.contentVersion &&
          _listEquals(tags, other.tags) &&
          _listEquals(media, other.media);

  @override
  int get hashCode => Object.hash(
    contentId,
    contentType,
    surface,
    occurrenceKey,
    authorUid,
    parentId,
    text,
    title,
    account,
    context,
    contentVersion,
    Object.hashAll(tags),
    Object.hashAll(media),
  );

  /// Omits [text] and [title]: they are user content and must not reach logs by
  /// an incidental interpolation.
  @override
  String toString() =>
      'GuardContent(${contentType.name}:$contentId, surface: ${surface.name}, '
      'version: $contentVersion, text: ${_isMeaningful(text) ? 'present' : 'absent'}, '
      'media: ${media.length})';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
